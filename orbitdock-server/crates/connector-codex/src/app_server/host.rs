use std::collections::HashMap;
use std::sync::atomic::AtomicI64;
use std::sync::Arc;

use codex_app_server_client::{
  InProcessAppServerClient, InProcessClientStartArgs, InProcessServerEvent,
  DEFAULT_IN_PROCESS_CHANNEL_CAPACITY,
};
use codex_app_server_protocol::{ConfigWarningNotification, JSONRPCErrorError};
use codex_arg0::Arg0DispatchPaths;
use codex_core::config_loader::{CloudRequirementsLoader, LoaderOverrides};
use codex_feedback::CodexFeedback;
use codex_protocol::protocol::SessionSource;
use orbitdock_connector_core::{ConnectorError, ConnectorOutput};
use tokio::sync::{broadcast, mpsc, Mutex};
use tracing::{debug, warn};

use super::notification_mapping::map_notification;
use super::request_mapping::map_server_request;
use super::router::{notification_thread_id, request_thread_id, send_outputs};
use super::{AppServerControl, AppServerEventState, AppServerSessionRoute, CodexAppServer};
use crate::{CodexConfigOverrides, CodexConnector, CodexRuntimeOverrides};

pub(super) async fn start_app_server(
  cwd: &str,
  config_overrides: &CodexConfigOverrides,
  runtime_overrides: &CodexRuntimeOverrides,
) -> Result<CodexAppServer, ConnectorError> {
  let config = CodexConnector::build_config_with_runtime_defaults(
    cwd,
    None,
    None,
    None,
    None,
    config_overrides,
    runtime_overrides,
    false,
  )
  .await?;

  let config_warnings = config
    .startup_warnings
    .iter()
    .map(|warning| ConfigWarningNotification {
      summary: warning.clone(),
      details: None,
      path: None,
      range: None,
    })
    .collect();
  let codex_self_exe = CodexConnector::embedded_codex_self_exe()?;
  let mut client = InProcessAppServerClient::start(InProcessClientStartArgs {
    arg0_paths: Arg0DispatchPaths {
      codex_self_exe: Some(codex_self_exe),
      codex_linux_sandbox_exe: None,
      main_execve_wrapper_exe: None,
    },
    config: Arc::new(config),
    cli_overrides: Vec::new(),
    loader_overrides: LoaderOverrides::default(),
    cloud_requirements: CloudRequirementsLoader::default(),
    feedback: CodexFeedback::new(),
    log_db: None,
    environment_manager: Arc::new(CodexConnector::embedded_environment_manager()?),
    config_warnings,
    session_source: SessionSource::Mcp,
    enable_codex_api_key_env: true,
    client_name: "orbitdock".to_string(),
    client_version: env!("CARGO_PKG_VERSION").to_string(),
    experimental_api: true,
    opt_out_notification_methods: Vec::new(),
    channel_capacity: DEFAULT_IN_PROCESS_CHANNEL_CAPACITY,
  })
  .await
  .map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to start Codex app-server: {error}"))
  })?;

  let request_handle = client.request_handle();
  let routes = Arc::new(Mutex::new(HashMap::new()));
  let routes_for_loop = Arc::clone(&routes);
  let (global_tx, _) = broadcast::channel(128);
  let global_tx_for_loop = global_tx.clone();
  let (control_tx, mut control_rx) = mpsc::channel(256);
  tokio::spawn(async move {
    loop {
      tokio::select! {
        control = control_rx.recv() => {
          let Some(control) = control else {
            return;
          };
          let result = match control {
            AppServerControl::Resolve { request_id, result } => {
              client.resolve_server_request(request_id, result).await
            }
          };
          if let Err(error) = result {
            warn!(%error, "Failed to respond to Codex app-server server request");
          }
        }
        event = client.next_event() => {
          let Some(event) = event else {
            return;
          };
          handle_app_server_event(event, &routes_for_loop, &global_tx_for_loop, &client).await;
        }
      }
    }
  });

  Ok(CodexAppServer {
    request_handle,
    request_ids: AtomicI64::new(1),
    routes,
    global_tx,
    control_tx,
  })
}

impl AppServerSessionRoute {
  pub(crate) fn new(
    output_tx: mpsc::Sender<ConnectorOutput>,
    active_turn_id: Arc<Mutex<Option<String>>>,
    pending_requests: Arc<Mutex<HashMap<String, codex_app_server_protocol::RequestId>>>,
  ) -> Self {
    let (forward_tx, mut forward_rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
      while let Some(output) = forward_rx.recv().await {
        if output_tx.send(output).await.is_err() {
          tracing::debug!("Typed codex app-server output channel closed");
          return;
        }
      }
    });

    Self {
      forward_tx,
      active_turn_id,
      pending_requests,
      state: Arc::new(AppServerEventState {
        delta_buffers: Arc::new(Mutex::new(HashMap::new())),
        streaming_message: Arc::new(Mutex::new(None)),
      }),
    }
  }
}

async fn handle_app_server_event(
  event: InProcessServerEvent,
  routes: &Arc<Mutex<HashMap<String, AppServerSessionRoute>>>,
  global_tx: &broadcast::Sender<codex_app_server_protocol::ServerNotification>,
  client: &InProcessAppServerClient,
) {
  match event {
    InProcessServerEvent::Lagged { skipped } => {
      warn!(
        skipped,
        "Codex app-server event drain lagged while running shared OrbitDock host"
      );
    }
    InProcessServerEvent::ServerNotification(notification) => {
      let Some(thread_id) = notification_thread_id(&notification) else {
        let _ = global_tx.send(notification.clone());
        debug!(notification = ?notification, "Ignoring global Codex app-server notification");
        return;
      };
      let route = routes.lock().await.get(&thread_id).cloned();
      let Some(route) = route else {
        debug!(%thread_id, notification = ?notification, "No OrbitDock route for Codex app-server notification");
        return;
      };
      let outputs = map_notification(notification, &route).await;
      send_outputs(&route, outputs).await;
    }
    InProcessServerEvent::ServerRequest(request) => {
      let request_id = request.id().clone();
      let Some(thread_id) = request_thread_id(&request) else {
        warn!(request = ?request, "Rejecting Codex app-server request without thread id");
        let _ = client
          .reject_server_request(
            request_id,
            JSONRPCErrorError {
              code: -32000,
              message: "OrbitDock cannot route an app-server request without thread id".to_string(),
              data: None,
            },
          )
          .await;
        return;
      };
      let route = routes.lock().await.get(&thread_id).cloned();
      let Some(route) = route else {
        warn!(%thread_id, request = ?request, "Rejecting Codex app-server request with no OrbitDock route");
        let _ = client
          .reject_server_request(
            request_id,
            JSONRPCErrorError {
              code: -32000,
              message: "OrbitDock session is not subscribed to this app-server thread".to_string(),
              data: None,
            },
          )
          .await;
        return;
      };
      let outputs = map_server_request(request, &route).await;
      send_outputs(&route, outputs).await;
    }
  }
}
