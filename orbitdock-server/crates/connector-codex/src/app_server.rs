use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, OnceLock};

use codex_app_server_client::{
  InProcessAppServerClient, InProcessAppServerRequestHandle, InProcessClientStartArgs,
  InProcessServerEvent, DEFAULT_IN_PROCESS_CHANNEL_CAPACITY,
};
use codex_app_server_protocol::{
  CancelLoginAccountParams, CancelLoginAccountResponse, ClientRequest, CollaborationModeListParams,
  CollaborationModeListResponse, CommandExecutionApprovalDecision,
  CommandExecutionRequestApprovalResponse, ConfigBatchWriteParams, ConfigReadParams,
  ConfigReadResponse, ConfigValueWriteParams, ConfigWarningNotification, ConfigWriteResponse,
  DynamicToolCallOutputContentItem, DynamicToolCallResponse, FileChangeApprovalDecision,
  FileChangeRequestApprovalResponse, FileUpdateChange, GetAccountParams,
  GetAccountRateLimitsResponse, GetAccountResponse, JSONRPCErrorError, ListMcpServerStatusParams,
  ListMcpServerStatusResponse, LoginAccountParams, LoginAccountResponse, LogoutAccountResponse,
  McpServerElicitationRequest, McpServerRefreshResponse, McpServerStartupState,
  McpServerStatusDetail, ModelListParams, ModelListResponse, PatchApplyStatus, PatchChangeKind,
  PermissionsRequestApprovalResponse, PluginInstallParams, PluginInstallResponse, PluginListParams,
  PluginListResponse, PluginUninstallParams, PluginUninstallResponse, RequestId,
  ServerNotification, ServerRequest, SkillsListParams, SkillsListResponse,
  ThreadCompactStartParams, ThreadCompactStartResponse, ThreadForkParams, ThreadForkResponse,
  ThreadItem, ThreadRollbackParams, ThreadRollbackResponse, ThreadSetNameParams,
  ThreadSetNameResponse, ThreadStartParams, ThreadStartResponse, ToolRequestUserInputAnswer,
  ToolRequestUserInputResponse, TurnInterruptParams, TurnInterruptResponse, TurnStartParams,
  TurnStartResponse, TurnStatus, TurnSteerParams, TurnSteerResponse, UserInput,
};
use codex_arg0::Arg0DispatchPaths;
use codex_core::config_loader::{CloudRequirementsLoader, LoaderOverrides};
use codex_feedback::CodexFeedback;
use codex_protocol::protocol::SessionSource;
use codex_utils_absolute_path::AbsolutePathBuf;
use orbitdock_connector_core::{
  ApprovalType, ConnectorError, ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent,
  ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::{
  classify_tool_name, ConversationRow, HookRow, MessageRowContent, NoticeRow, NoticeRowKind,
  NoticeRowSeverity, ToolRow,
};
use orbitdock_protocol::domain_events::{
  AgentType, GuardianAssessmentPayload, HookOutputEntry, HookPayload, ToolFamily, ToolKind,
  ToolStatus,
};
use orbitdock_protocol::{
  Provider, SubagentInfo, SubagentStatus, TokenUsage, TokenUsageSnapshotKind,
};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, Mutex};
use tracing::{debug, warn};

use crate::row_mapping::{row_created_output, row_updated_output, state_output, tool_row_entry};
use crate::runtime::{
  apply_delta_thinking, finalized_thinking_row_entry, row_entry, StreamingMessage,
  STREAM_THROTTLE_MS,
};
use crate::timeline::is_thread_start_skills_trimmed_warning;
use crate::workers::iso_now;
use crate::{CodexConfigOverrides, CodexConnector, CodexRuntimeOverrides};

static APP_SERVER: OnceLock<Mutex<Option<Arc<CodexAppServer>>>> = OnceLock::new();

pub struct CodexAppServer {
  request_handle: InProcessAppServerRequestHandle,
  request_ids: AtomicI64,
  routes: Arc<Mutex<HashMap<String, AppServerSessionRoute>>>,
  global_tx: broadcast::Sender<ServerNotification>,
  control_tx: mpsc::Sender<AppServerControl>,
}

#[derive(Clone)]
pub(crate) struct AppServerSessionRoute {
  output_tx: mpsc::Sender<ConnectorOutput>,
  active_turn_id: Arc<Mutex<Option<String>>>,
  pending_requests: Arc<Mutex<HashMap<String, RequestId>>>,
  state: Arc<AppServerEventState>,
}

pub(crate) struct AppServerEventState {
  delta_buffers: Arc<Mutex<HashMap<String, String>>>,
  streaming_message: Arc<Mutex<Option<StreamingMessage>>>,
}

enum AppServerControl {
  Resolve {
    request_id: RequestId,
    result: serde_json::Value,
  },
}

pub async fn shared_app_server_for_cwd(cwd: &str) -> Result<Arc<CodexAppServer>, ConnectorError> {
  shared_app_server(
    cwd,
    &CodexConfigOverrides::default(),
    &CodexRuntimeOverrides::default(),
  )
  .await
}

pub(crate) async fn shared_app_server(
  cwd: &str,
  config_overrides: &CodexConfigOverrides,
  runtime_overrides: &CodexRuntimeOverrides,
) -> Result<Arc<CodexAppServer>, ConnectorError> {
  let cell = APP_SERVER.get_or_init(|| Mutex::new(None));
  let mut guard = cell.lock().await;

  if let Some(app_server) = guard.as_ref() {
    return Ok(Arc::clone(app_server));
  }

  let app_server = Arc::new(start_app_server(cwd, config_overrides, runtime_overrides).await?);
  *guard = Some(Arc::clone(&app_server));
  Ok(app_server)
}

impl CodexAppServer {
  fn next_request_id(&self) -> RequestId {
    RequestId::Integer(self.request_ids.fetch_add(1, Ordering::Relaxed))
  }

  pub async fn config_read(
    &self,
    params: ConfigReadParams,
  ) -> Result<ConfigReadResponse, ConnectorError> {
    self
      .request(ClientRequest::ConfigRead {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn config_value_write(
    &self,
    params: ConfigValueWriteParams,
  ) -> Result<ConfigWriteResponse, ConnectorError> {
    self
      .request(ClientRequest::ConfigValueWrite {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn config_batch_write(
    &self,
    params: ConfigBatchWriteParams,
  ) -> Result<ConfigWriteResponse, ConnectorError> {
    self
      .request(ClientRequest::ConfigBatchWrite {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn account_read(
    &self,
    refresh_token: bool,
  ) -> Result<GetAccountResponse, ConnectorError> {
    self
      .request(ClientRequest::GetAccount {
        request_id: self.next_request_id(),
        params: GetAccountParams { refresh_token },
      })
      .await
  }

  pub async fn account_login_start(
    &self,
    params: LoginAccountParams,
  ) -> Result<LoginAccountResponse, ConnectorError> {
    self
      .request(ClientRequest::LoginAccount {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn account_login_cancel(
    &self,
    login_id: String,
  ) -> Result<CancelLoginAccountResponse, ConnectorError> {
    self
      .request(ClientRequest::CancelLoginAccount {
        request_id: self.next_request_id(),
        params: CancelLoginAccountParams { login_id },
      })
      .await
  }

  pub async fn account_logout(&self) -> Result<LogoutAccountResponse, ConnectorError> {
    self
      .request(ClientRequest::LogoutAccount {
        request_id: self.next_request_id(),
        params: None,
      })
      .await
  }

  pub async fn account_rate_limits(&self) -> Result<GetAccountRateLimitsResponse, ConnectorError> {
    self
      .request(ClientRequest::GetAccountRateLimits {
        request_id: self.next_request_id(),
        params: None,
      })
      .await
  }

  pub fn subscribe_global_notifications(&self) -> broadcast::Receiver<ServerNotification> {
    self.global_tx.subscribe()
  }

  pub async fn plugin_list(
    &self,
    cwds: Vec<AbsolutePathBuf>,
  ) -> Result<PluginListResponse, ConnectorError> {
    self
      .request(ClientRequest::PluginList {
        request_id: self.next_request_id(),
        params: PluginListParams {
          cwds: (!cwds.is_empty()).then_some(cwds),
        },
      })
      .await
  }

  pub async fn plugin_install(
    &self,
    params: PluginInstallParams,
  ) -> Result<PluginInstallResponse, ConnectorError> {
    self
      .request(ClientRequest::PluginInstall {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn plugin_uninstall(
    &self,
    params: PluginUninstallParams,
  ) -> Result<PluginUninstallResponse, ConnectorError> {
    self
      .request(ClientRequest::PluginUninstall {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn thread_start(
    &self,
    params: ThreadStartParams,
  ) -> Result<ThreadStartResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadStart {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn thread_resume(
    &self,
    params: codex_app_server_protocol::ThreadResumeParams,
  ) -> Result<codex_app_server_protocol::ThreadResumeResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadResume {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn thread_fork(
    &self,
    params: ThreadForkParams,
  ) -> Result<ThreadForkResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadFork {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn turn_start(
    &self,
    params: TurnStartParams,
  ) -> Result<TurnStartResponse, ConnectorError> {
    self
      .request(ClientRequest::TurnStart {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn turn_steer(
    &self,
    params: TurnSteerParams,
  ) -> Result<TurnSteerResponse, ConnectorError> {
    self
      .request(ClientRequest::TurnSteer {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn turn_interrupt(
    &self,
    params: TurnInterruptParams,
  ) -> Result<TurnInterruptResponse, ConnectorError> {
    self
      .request(ClientRequest::TurnInterrupt {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn skills_list(
    &self,
    params: SkillsListParams,
  ) -> Result<SkillsListResponse, ConnectorError> {
    self
      .request(ClientRequest::SkillsList {
        request_id: self.next_request_id(),
        params,
      })
      .await
  }

  pub async fn collaboration_mode_list(
    &self,
  ) -> Result<CollaborationModeListResponse, ConnectorError> {
    self
      .request(ClientRequest::CollaborationModeList {
        request_id: self.next_request_id(),
        params: CollaborationModeListParams::default(),
      })
      .await
  }

  pub async fn model_list(
    &self,
    include_hidden: bool,
  ) -> Result<ModelListResponse, ConnectorError> {
    let mut data = Vec::new();
    let mut cursor = None;
    loop {
      let response: ModelListResponse = self
        .request(ClientRequest::ModelList {
          request_id: self.next_request_id(),
          params: ModelListParams {
            cursor,
            limit: Some(100),
            include_hidden: Some(include_hidden),
          },
        })
        .await?;
      data.extend(response.data);
      cursor = response.next_cursor;
      if cursor.is_none() {
        return Ok(ModelListResponse {
          data,
          next_cursor: None,
        });
      }
    }
  }

  pub async fn mcp_server_status_list(
    &self,
  ) -> Result<ListMcpServerStatusResponse, ConnectorError> {
    self
      .request(ClientRequest::McpServerStatusList {
        request_id: self.next_request_id(),
        params: ListMcpServerStatusParams {
          cursor: None,
          limit: None,
          detail: Some(McpServerStatusDetail::Full),
        },
      })
      .await
  }

  pub async fn mcp_server_refresh(&self) -> Result<McpServerRefreshResponse, ConnectorError> {
    self
      .request(ClientRequest::McpServerRefresh {
        request_id: self.next_request_id(),
        params: None,
      })
      .await
  }

  pub async fn thread_set_name(
    &self,
    thread_id: String,
    name: String,
  ) -> Result<ThreadSetNameResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadSetName {
        request_id: self.next_request_id(),
        params: ThreadSetNameParams { thread_id, name },
      })
      .await
  }

  pub async fn thread_compact_start(
    &self,
    thread_id: String,
  ) -> Result<ThreadCompactStartResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadCompactStart {
        request_id: self.next_request_id(),
        params: ThreadCompactStartParams { thread_id },
      })
      .await
  }

  pub async fn thread_rollback(
    &self,
    thread_id: String,
    num_turns: u32,
  ) -> Result<ThreadRollbackResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadRollback {
        request_id: self.next_request_id(),
        params: ThreadRollbackParams {
          thread_id,
          num_turns,
        },
      })
      .await
  }

  pub(crate) async fn register_session(&self, thread_id: String, route: AppServerSessionRoute) {
    self.routes.lock().await.insert(thread_id, route);
  }

  pub(crate) async fn unregister_session(&self, thread_id: &str) {
    self.routes.lock().await.remove(thread_id);
  }

  pub(crate) async fn resolve_server_request<T>(
    &self,
    request_id: RequestId,
    response: T,
  ) -> Result<(), ConnectorError>
  where
    T: Serialize,
  {
    let result = serde_json::to_value(response).map_err(|error| {
      ConnectorError::ProviderError(format!("Failed to encode app-server response: {error}"))
    })?;
    self
      .control_tx
      .send(AppServerControl::Resolve { request_id, result })
      .await
      .map_err(|_| ConnectorError::ProviderError("Codex app-server host stopped".to_string()))
  }

  async fn request<T>(&self, request: ClientRequest) -> Result<T, ConnectorError>
  where
    T: DeserializeOwned,
  {
    self
      .request_handle
      .request_typed(request)
      .await
      .map_err(|error| ConnectorError::ProviderError(format!("Codex app-server error: {error}")))
  }
}

async fn start_app_server(
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
    pending_requests: Arc<Mutex<HashMap<String, RequestId>>>,
  ) -> Self {
    Self {
      output_tx,
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
  global_tx: &broadcast::Sender<ServerNotification>,
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
      send_outputs(&route.output_tx, outputs).await;
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
      send_outputs(&route.output_tx, outputs).await;
    }
  }
}

fn notification_thread_id(notification: &ServerNotification) -> Option<String> {
  Some(match notification {
    ServerNotification::ThreadStarted(event) => event.thread.id.clone(),
    ServerNotification::ThreadStatusChanged(event) => event.thread_id.clone(),
    ServerNotification::ThreadArchived(event) => event.thread_id.clone(),
    ServerNotification::ThreadUnarchived(event) => event.thread_id.clone(),
    ServerNotification::ThreadClosed(event) => event.thread_id.clone(),
    ServerNotification::ThreadNameUpdated(event) => event.thread_id.clone(),
    ServerNotification::ThreadTokenUsageUpdated(event) => event.thread_id.clone(),
    ServerNotification::TurnStarted(event) => event.thread_id.clone(),
    ServerNotification::HookStarted(event) => event.thread_id.clone(),
    ServerNotification::TurnCompleted(event) => event.thread_id.clone(),
    ServerNotification::HookCompleted(event) => event.thread_id.clone(),
    ServerNotification::TurnDiffUpdated(event) => event.thread_id.clone(),
    ServerNotification::TurnPlanUpdated(event) => event.thread_id.clone(),
    ServerNotification::ItemStarted(event) => event.thread_id.clone(),
    ServerNotification::ItemGuardianApprovalReviewStarted(event) => event.thread_id.clone(),
    ServerNotification::ItemGuardianApprovalReviewCompleted(event) => event.thread_id.clone(),
    ServerNotification::ItemCompleted(event) => event.thread_id.clone(),
    ServerNotification::AgentMessageDelta(event) => event.thread_id.clone(),
    ServerNotification::PlanDelta(event) => event.thread_id.clone(),
    ServerNotification::ReasoningSummaryTextDelta(event) => event.thread_id.clone(),
    ServerNotification::ReasoningSummaryPartAdded(event) => event.thread_id.clone(),
    ServerNotification::ReasoningTextDelta(event) => event.thread_id.clone(),
    ServerNotification::CommandExecutionOutputDelta(event) => event.thread_id.clone(),
    ServerNotification::TerminalInteraction(event) => event.thread_id.clone(),
    ServerNotification::FileChangeOutputDelta(event) => event.thread_id.clone(),
    ServerNotification::ServerRequestResolved(event) => event.thread_id.clone(),
    ServerNotification::McpToolCallProgress(event) => event.thread_id.clone(),
    ServerNotification::Error(event) => event.thread_id.clone(),
    ServerNotification::ContextCompacted(event) => event.thread_id.clone(),
    ServerNotification::ModelRerouted(event) => event.thread_id.clone(),
    ServerNotification::Warning(event) => return event.thread_id.clone(),
    _ => return None,
  })
}

fn request_thread_id(request: &ServerRequest) -> Option<String> {
  Some(match request {
    ServerRequest::CommandExecutionRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::FileChangeRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::ToolRequestUserInput { params, .. } => params.thread_id.clone(),
    ServerRequest::McpServerElicitationRequest { params, .. } => params.thread_id.clone(),
    ServerRequest::PermissionsRequestApproval { params, .. } => params.thread_id.clone(),
    ServerRequest::DynamicToolCall { params, .. } => params.thread_id.clone(),
    _ => return None,
  })
}

async fn send_outputs(output_tx: &mpsc::Sender<ConnectorOutput>, outputs: Vec<ConnectorOutput>) {
  for output in outputs {
    if output_tx.send(output).await.is_err() {
      debug!("Typed codex app-server output channel closed");
      return;
    }
  }
}

async fn map_notification(
  notification: ServerNotification,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  match notification {
    ServerNotification::TurnStarted(event) => {
      *route.active_turn_id.lock().await = Some(event.turn.id.clone());
      vec![state_output(ConnectorStateEvent::TurnStarted)]
    }
    ServerNotification::HookStarted(event) => map_hook_started(event),
    ServerNotification::TurnCompleted(event) => {
      *route.active_turn_id.lock().await = None;
      match event.turn.status {
        TurnStatus::Completed => vec![state_output(ConnectorStateEvent::TurnCompleted)],
        TurnStatus::Interrupted => vec![state_output(ConnectorStateEvent::TurnAborted {
          reason: "interrupted".to_string(),
        })],
        TurnStatus::Failed => vec![state_output(ConnectorStateEvent::TurnAborted {
          reason: event
            .turn
            .error
            .map(|error| error.message)
            .unwrap_or_else(|| "failed".to_string()),
        })],
        TurnStatus::InProgress => Vec::new(),
      }
    }
    ServerNotification::HookCompleted(event) => map_hook_completed(event),
    ServerNotification::ThreadStatusChanged(_) => Vec::new(),
    ServerNotification::ThreadClosed(_) => vec![state_output(ConnectorStateEvent::SessionEnded {
      reason: "closed".to_string(),
    })],
    ServerNotification::ThreadNameUpdated(event) => event
      .thread_name
      .map(|name| vec![state_output(ConnectorStateEvent::ThreadNameUpdated(name))])
      .unwrap_or_default(),
    ServerNotification::ThreadTokenUsageUpdated(event) => map_token_usage(event.token_usage),
    ServerNotification::TurnDiffUpdated(event) => {
      vec![state_output(ConnectorStateEvent::DiffUpdated(event.diff))]
    }
    ServerNotification::TurnPlanUpdated(event) => {
      let mut text = String::new();
      if let Some(explanation) = event.explanation.filter(|value| !value.trim().is_empty()) {
        text.push_str(&explanation);
        text.push_str("\n\n");
      }
      for step in event.plan {
        text.push_str("- [");
        text.push_str(match step.status {
          codex_app_server_protocol::TurnPlanStepStatus::Completed => "x",
          _ => " ",
        });
        text.push_str("] ");
        text.push_str(&step.step);
        text.push('\n');
      }
      (!text.trim().is_empty())
        .then(|| vec![state_output(ConnectorStateEvent::PlanUpdated(text))])
        .unwrap_or_default()
    }
    ServerNotification::AgentMessageDelta(event) => {
      map_agent_message_delta(event.item_id, event.delta, route).await
    }
    ServerNotification::PlanDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!("plan-{}", event.item_id),
        event.delta,
      )
      .await
    }
    ServerNotification::ReasoningSummaryTextDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!(
          "reasoning-summary-{}-{}",
          event.item_id, event.summary_index
        ),
        event.delta,
      )
      .await
    }
    ServerNotification::ReasoningTextDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!("reasoning-raw-{}-{}", event.item_id, event.content_index),
        event.delta,
      )
      .await
    }
    ServerNotification::ItemStarted(event) => map_item(event.item, true, route).await,
    ServerNotification::ItemGuardianApprovalReviewStarted(event) => {
      let row_id = format!("guardian-{}", event.review_id);
      tool_row_outputs(
        row_id,
        guardian_review_tool_row(
          event.review_id,
          event.turn_id,
          event.target_item_id,
          event.review,
          event.action,
          true,
        ),
        true,
      )
    }
    ServerNotification::ItemGuardianApprovalReviewCompleted(event) => {
      let row_id = format!("guardian-{}", event.review_id);
      tool_row_outputs(
        row_id,
        guardian_review_tool_row(
          event.review_id,
          event.turn_id,
          event.target_item_id,
          event.review,
          event.action,
          false,
        ),
        false,
      )
    }
    ServerNotification::ItemCompleted(event) => map_item(event.item, false, route).await,
    ServerNotification::ReasoningSummaryPartAdded(_) => Vec::new(),
    ServerNotification::CommandExecutionOutputDelta(event) => {
      let mut buffers = route.state.delta_buffers.lock().await;
      buffers
        .entry(output_buffer_key("command", &event.item_id))
        .or_default()
        .push_str(&event.delta);
      vec![ConnectorOutput::Transport(
        ConnectorTransportEffect::ToolPtyOutput {
          tool_id: event.item_id,
          bytes: event.delta.into_bytes(),
        },
      )]
    }
    ServerNotification::TerminalInteraction(event) => map_terminal_interaction(event),
    ServerNotification::FileChangeOutputDelta(event) => {
      let mut buffers = route.state.delta_buffers.lock().await;
      buffers
        .entry(output_buffer_key("file-change", &event.item_id))
        .or_default()
        .push_str(&event.delta);
      Vec::new()
    }
    ServerNotification::ServerRequestResolved(event) => {
      let key = request_key(&event.request_id);
      route.pending_requests.lock().await.remove(&key);
      vec![state_output(ConnectorStateEvent::ApprovalCancelled {
        request_id: key,
      })]
    }
    ServerNotification::SkillsChanged(_) => {
      vec![state_output(ConnectorStateEvent::SkillsUpdateAvailable)]
    }
    ServerNotification::McpServerStatusUpdated(event) => {
      vec![state_output(ConnectorStateEvent::McpStartupUpdate {
        server: event.name,
        status: match event.status {
          McpServerStartupState::Starting => orbitdock_protocol::McpStartupStatus::Starting,
          McpServerStartupState::Ready => orbitdock_protocol::McpStartupStatus::Ready,
          McpServerStartupState::Failed => orbitdock_protocol::McpStartupStatus::Failed {
            error: event
              .error
              .unwrap_or_else(|| "MCP server failed".to_string()),
          },
          McpServerStartupState::Cancelled => orbitdock_protocol::McpStartupStatus::Cancelled,
        },
      })]
    }
    ServerNotification::Error(event) => {
      let mut outputs = vec![state_output(ConnectorStateEvent::Error(
        event.error.message.clone(),
      ))];
      if !event.will_retry {
        outputs.push(state_output(ConnectorStateEvent::TurnAborted {
          reason: event.error.message,
        }));
      }
      outputs
    }
    ServerNotification::ContextCompacted(_) => {
      vec![state_output(ConnectorStateEvent::ContextCompacted)]
    }
    ServerNotification::ModelRerouted(event) => {
      let content = format!(
        "Model rerouted from {} to {} ({:?})",
        event.from_model, event.to_model, event.reason
      );
      vec![row_created_output(row_entry(ConversationRow::System(
        MessageRowContent {
          id: format!("model-reroute-{}", event.turn_id),
          content,
          turn_id: Some(event.turn_id),
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ServerNotification::Warning(event) => map_warning(event.message),
    other => {
      debug!(notification = ?other, "Unhandled Codex app-server notification");
      Vec::new()
    }
  }
}

async fn map_server_request(
  request: ServerRequest,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  let request_id = request.id().clone();
  let key = request_key(&request_id);
  route
    .pending_requests
    .lock()
    .await
    .insert(key.clone(), request_id);

  match request {
    ServerRequest::CommandExecutionRequestApproval { params, .. } => {
      vec![state_output(ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Exec,
        tool_name: None,
        tool_input: None,
        command: params.command,
        file_path: params.cwd.map(|path| path.display().to_string()),
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
        requested_permissions: None,
        proposed_amendment: params
          .proposed_execpolicy_amendment
          .map(|amendment| amendment.command),
        permission_suggestions: serde_json::to_value(json!({
          "source": "codex_app_server_command_approval",
          "available_decisions": params.available_decisions,
          "additional_permissions": params.additional_permissions,
          "proposed_network_policy_amendments": params.proposed_network_policy_amendments,
        }))
        .ok(),
        elicitation_mode: None,
        elicitation_schema: None,
        elicitation_url: None,
        elicitation_message: None,
        mcp_server_name: None,
        network_host: params
          .network_approval_context
          .as_ref()
          .map(|context| context.host.clone()),
        network_protocol: params
          .network_approval_context
          .map(|context| format!("{:?}", context.protocol).to_ascii_lowercase()),
      })]
    }
    ServerRequest::FileChangeRequestApproval { params, .. } => {
      vec![state_output(ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Patch,
        tool_name: None,
        tool_input: None,
        command: None,
        file_path: params.grant_root.map(|path| path.display().to_string()),
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
        requested_permissions: None,
        proposed_amendment: None,
        permission_suggestions: None,
        elicitation_mode: None,
        elicitation_schema: None,
        elicitation_url: None,
        elicitation_message: None,
        mcp_server_name: None,
        network_host: None,
        network_protocol: None,
      })]
    }
    ServerRequest::ToolRequestUserInput { params, .. } => {
      let question_text = params
        .questions
        .first()
        .map(|question| question.question.clone());
      vec![state_output(ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Question,
        tool_name: Some("request_user_input".to_string()),
        tool_input: serde_json::to_string(&params.questions).ok(),
        command: None,
        file_path: None,
        diff: None,
        question: question_text,
        permission_reason: None,
        requested_permissions: None,
        proposed_amendment: None,
        permission_suggestions: None,
        elicitation_mode: None,
        elicitation_schema: None,
        elicitation_url: None,
        elicitation_message: None,
        mcp_server_name: None,
        network_host: None,
        network_protocol: None,
      })]
    }
    ServerRequest::McpServerElicitationRequest { params, .. } => {
      let (mode, schema, url, message) = match &params.request {
        McpServerElicitationRequest::Form {
          message,
          requested_schema,
          ..
        } => (
          Some("form".to_string()),
          serde_json::to_value(requested_schema).ok(),
          None,
          Some(message.clone()),
        ),
        McpServerElicitationRequest::Url { message, url, .. } => (
          Some("url".to_string()),
          None,
          Some(url.clone()),
          Some(message.clone()),
        ),
      };
      vec![state_output(ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Question,
        tool_name: Some("mcp_approval".to_string()),
        tool_input: serde_json::to_string(&params.request).ok(),
        command: None,
        file_path: None,
        diff: None,
        question: message.clone(),
        permission_reason: None,
        requested_permissions: None,
        proposed_amendment: None,
        permission_suggestions: None,
        elicitation_mode: mode,
        elicitation_schema: schema,
        elicitation_url: url,
        elicitation_message: message,
        mcp_server_name: Some(params.server_name),
        network_host: None,
        network_protocol: None,
      })]
    }
    ServerRequest::PermissionsRequestApproval { params, .. } => {
      vec![state_output(ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Permissions,
        tool_name: Some("request_permissions".to_string()),
        tool_input: serde_json::to_string(&params.permissions).ok(),
        command: None,
        file_path: None,
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
        requested_permissions: serde_json::to_value(&params.permissions).ok(),
        proposed_amendment: None,
        permission_suggestions: None,
        elicitation_mode: None,
        elicitation_schema: None,
        elicitation_url: None,
        elicitation_message: None,
        mcp_server_name: None,
        network_host: None,
        network_protocol: None,
      })]
    }
    ServerRequest::DynamicToolCall { params, .. } => {
      vec![ConnectorOutput::Runtime(
        ConnectorRuntimeDirective::DynamicToolCallRequested {
          call_id: key,
          tool_name: params.tool,
          arguments: params.arguments,
        },
      )]
    }
    other => {
      warn!(request = ?other, "Unhandled Codex app-server request");
      Vec::new()
    }
  }
}

async fn map_agent_message_delta(
  item_id: String,
  delta: String,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  let mut streaming = route.state.streaming_message.lock().await;
  match streaming.as_mut() {
    None => {
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: item_id.clone(),
        content: delta.clone(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      *streaming = Some(StreamingMessage {
        message_id: item_id,
        content: delta,
        last_broadcast: std::time::Instant::now(),
      });
      vec![row_created_output(entry)]
    }
    Some(streaming_msg) => {
      streaming_msg.content.push_str(&delta);
      let now = std::time::Instant::now();
      if now.duration_since(streaming_msg.last_broadcast).as_millis() >= STREAM_THROTTLE_MS {
        streaming_msg.last_broadcast = now;
        let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
          id: streaming_msg.message_id.clone(),
          content: streaming_msg.content.clone(),
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: true,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        }));
        vec![row_updated_output(streaming_msg.message_id.clone(), entry)]
      } else {
        Vec::new()
      }
    }
  }
}

async fn map_item(
  item: ThreadItem,
  started: bool,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  match item {
    ThreadItem::UserMessage { id, content } if !started => {
      let text = content
        .into_iter()
        .filter_map(|input| match input {
          UserInput::Text { text, .. } => Some(text),
          _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
      vec![row_created_output(row_entry(ConversationRow::User(
        MessageRowContent {
          id,
          content: text,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ThreadItem::AgentMessage { id, text, .. } if !started => {
      route.state.streaming_message.lock().await.take();
      vec![row_updated_output(
        id.clone(),
        row_entry(ConversationRow::Assistant(MessageRowContent {
          id,
          content: text,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        })),
      )]
    }
    ThreadItem::Plan { id, text } => {
      let message_id = format!("plan-{id}");
      if started {
        apply_delta_thinking(&route.state.delta_buffers, message_id, text).await
      } else {
        route.state.delta_buffers.lock().await.remove(&message_id);
        let mut outputs = vec![row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text.clone()),
        )];
        if !text.trim().is_empty() {
          outputs.push(state_output(ConnectorStateEvent::PlanUpdated(text)));
        }
        outputs
      }
    }
    ThreadItem::Reasoning {
      id,
      summary,
      content,
    } if !started => {
      let mut outputs = Vec::new();
      for (idx, text) in summary.into_iter().enumerate() {
        let message_id = format!("reasoning-summary-{id}-{idx}");
        route.state.delta_buffers.lock().await.remove(&message_id);
        outputs.push(row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text),
        ));
      }
      for (idx, text) in content.into_iter().enumerate() {
        let message_id = format!("reasoning-raw-{id}-{idx}");
        route.state.delta_buffers.lock().await.remove(&message_id);
        outputs.push(row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text),
        ));
      }
      outputs
    }
    ThreadItem::CommandExecution {
      id,
      command,
      cwd,
      process_id,
      status,
      command_actions,
      aggregated_output,
      exit_code,
      duration_ms,
      ..
    } => {
      let buffered_output = if started {
        None
      } else {
        route
          .state
          .delta_buffers
          .lock()
          .await
          .remove(&output_buffer_key("command", &id))
      };
      let output = aggregated_output.or(buffered_output);
      let is_running = started
        || matches!(
          status,
          codex_app_server_protocol::CommandExecutionStatus::InProgress
        );
      let row = ToolRow {
        id: id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Shell,
        kind: ToolKind::Bash,
        status: command_execution_tool_status(status, is_running, exit_code),
        title: command.clone(),
        subtitle: Some(cwd.display().to_string()),
        summary: output.clone(),
        preview: None,
        started_at: started.then(iso_now),
        ended_at: (!is_running).then(iso_now),
        duration_ms: duration_millis(duration_ms),
        grouping_key: None,
        invocation: json!({
          "command": command,
          "cwd": cwd.display().to_string(),
          "command_actions": command_actions,
        }),
        result: output.map(|output| {
          json!({
            "output": output,
            "exit_code": exit_code,
          })
        }),
        render_hints: Default::default(),
        tool_display: None,
        shell_execution: None,
      };
      let mut outputs = tool_row_outputs(id.clone(), row, started);
      if started {
        outputs.push(ConnectorOutput::Transport(
          ConnectorTransportEffect::ToolPtyCreated {
            tool_id: id.clone(),
          },
        ));
      } else {
        outputs.push(ConnectorOutput::Transport(
          ConnectorTransportEffect::ToolPtyExited {
            tool_id: id,
            exit_code,
          },
        ));
      }
      let _ = process_id;
      outputs
    }
    ThreadItem::FileChange {
      id,
      changes,
      status,
    } => {
      let output = if started {
        None
      } else {
        route
          .state
          .delta_buffers
          .lock()
          .await
          .remove(&output_buffer_key("file-change", &id))
      };
      let row = file_change_tool_row(id.clone(), changes, status, started, output);
      tool_row_outputs(id, row, started)
    }
    ThreadItem::McpToolCall {
      id,
      server,
      tool,
      status,
      arguments,
      result,
      error,
      duration_ms,
      ..
    } => {
      let is_running = started
        || matches!(
          status,
          codex_app_server_protocol::McpToolCallStatus::InProgress
        );
      let row = ToolRow {
        id: id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Mcp,
        kind: ToolKind::McpToolCall,
        status: if is_running {
          ToolStatus::Running
        } else if error.is_none() {
          ToolStatus::Completed
        } else {
          ToolStatus::Failed
        },
        title: tool.clone(),
        subtitle: Some(server.clone()),
        summary: error.as_ref().map(|error| error.message.clone()),
        preview: None,
        started_at: started.then(iso_now),
        ended_at: (!is_running).then(iso_now),
        duration_ms: duration_millis(duration_ms),
        grouping_key: None,
        invocation: json!({
          "server": server,
          "tool": tool,
          "arguments": arguments,
        }),
        result: serde_json::to_value(result).ok(),
        render_hints: Default::default(),
        tool_display: None,
        shell_execution: None,
      };
      tool_row_outputs(id, row, started)
    }
    ThreadItem::DynamicToolCall {
      id,
      tool,
      arguments,
      status,
      content_items,
      success,
      duration_ms,
    } => map_dynamic_tool(
      id,
      tool,
      arguments,
      content_items,
      success.unwrap_or(!matches!(
        status,
        codex_app_server_protocol::DynamicToolCallStatus::Failed
      )),
      duration_ms,
      started,
    ),
    ThreadItem::CollabAgentToolCall {
      id,
      tool,
      status,
      sender_thread_id,
      receiver_thread_ids,
      prompt,
      model,
      reasoning_effort,
      agents_states,
    } => map_collab_agent_tool(
      id,
      tool,
      status,
      sender_thread_id,
      receiver_thread_ids,
      prompt,
      model,
      reasoning_effort.map(|value| format!("{value:?}")),
      agents_states,
      started,
    ),
    ThreadItem::WebSearch { id, query, action } => map_generic_tool(
      id,
      "web_search".to_string(),
      json!({ "query": query, "action": action }),
      None,
      true,
      None,
      started,
    ),
    ThreadItem::ImageView { id, path } => map_tool_row(
      id,
      ToolFamily::Image,
      ToolKind::ViewImage,
      path.display().to_string(),
      None,
      json!({ "path": path.display().to_string() }),
      None,
      started,
      true,
      None,
    ),
    ThreadItem::ImageGeneration {
      id,
      status,
      revised_prompt,
      result,
      saved_path,
    } => map_tool_row(
      id,
      ToolFamily::Image,
      ToolKind::ImageGeneration,
      "Image generation".to_string(),
      revised_prompt,
      json!({ "status": status }),
      Some(json!({ "result": result, "saved_path": saved_path })),
      started,
      true,
      None,
    ),
    ThreadItem::EnteredReviewMode { id, review } if !started => {
      vec![row_created_output(row_entry(ConversationRow::Notice(
        NoticeRow {
          id,
          kind: NoticeRowKind::Generic,
          severity: NoticeRowSeverity::Info,
          title: "Review mode".to_string(),
          summary: Some(review.clone()),
          body: Some(review),
          render_hints: Default::default(),
        },
      )))]
    }
    ThreadItem::ExitedReviewMode { id, review } if !started => {
      vec![row_created_output(row_entry(ConversationRow::Assistant(
        MessageRowContent {
          id,
          content: review,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ThreadItem::ContextCompaction { id } => map_tool_row(
      id,
      ToolFamily::Context,
      ToolKind::CompactContext,
      if started {
        "Compacting context".to_string()
      } else {
        "Context compacted".to_string()
      },
      None,
      json!({}),
      (!started).then(|| json!({ "summary": "Context compacted" })),
      started,
      true,
      None,
    ),
    other => {
      debug!(item = ?other, started, "Unhandled Codex app-server item");
      Vec::new()
    }
  }
}

fn map_generic_tool(
  id: String,
  tool: String,
  arguments: serde_json::Value,
  result: Option<Vec<DynamicToolCallOutputContentItem>>,
  success: bool,
  duration_ms: Option<i64>,
  started: bool,
) -> Vec<ConnectorOutput> {
  let (family, kind) = classify_tool_name(&tool);
  map_tool_row(
    id,
    family,
    kind,
    tool,
    None,
    arguments,
    result.and_then(|value| serde_json::to_value(value).ok()),
    started,
    success,
    duration_millis(duration_ms),
  )
}

fn map_terminal_interaction(
  event: codex_app_server_protocol::TerminalInteractionNotification,
) -> Vec<ConnectorOutput> {
  if event.stdin.is_empty() {
    return Vec::new();
  }
  vec![ConnectorOutput::Transport(
    ConnectorTransportEffect::ToolPtyOutput {
      tool_id: event.item_id,
      bytes: event.stdin.into_bytes(),
    },
  )]
}

fn map_hook_started(
  event: codex_app_server_protocol::HookStartedNotification,
) -> Vec<ConnectorOutput> {
  if !hook_run_is_error(event.run.status) {
    return Vec::new();
  }
  vec![row_created_output(row_entry(ConversationRow::Hook(
    hook_row(event.run, "started"),
  )))]
}

fn map_hook_completed(
  event: codex_app_server_protocol::HookCompletedNotification,
) -> Vec<ConnectorOutput> {
  if !hook_run_is_error(event.run.status) {
    return Vec::new();
  }
  let row_id = format!("hook-{}", event.run.id);
  vec![row_updated_output(
    row_id,
    row_entry(ConversationRow::Hook(hook_row(event.run, "completed"))),
  )]
}

fn hook_row(run: codex_app_server_protocol::HookRunSummary, phase: &str) -> HookRow {
  let output = hook_output_text(&run);
  HookRow {
    id: format!("hook-{}", run.id),
    title: hook_title(&run),
    subtitle: Some(format!("{:?}", run.event_name)),
    summary: output.clone(),
    payload: HookPayload {
      hook_name: Some(format!("{:?}", run.handler_type)),
      event_name: Some(format!("{:?}", run.event_name)),
      phase: Some(phase.to_string()),
      status: Some(format!("{:?}", run.status)),
      source_path: Some(run.source_path.display().to_string()),
      source: Some(format!("{:?}", run.source)),
      summary: output.clone(),
      output,
      duration_ms: duration_millis(run.duration_ms),
      entries: run
        .entries
        .into_iter()
        .map(|entry| HookOutputEntry {
          kind: Some(format!("{:?}", entry.kind)),
          label: None,
          value: Some(entry.text),
        })
        .collect(),
    },
    render_hints: Default::default(),
  }
}

fn hook_title(run: &codex_app_server_protocol::HookRunSummary) -> String {
  match run.status {
    codex_app_server_protocol::HookRunStatus::Running => {
      format!("Hook running: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Failed => {
      format!("Hook failed: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Blocked => {
      format!("Hook blocked: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Stopped => {
      format!("Hook stopped: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Completed => {
      format!("Hook completed: {:?}", run.event_name)
    }
  }
}

fn hook_run_is_error(status: codex_app_server_protocol::HookRunStatus) -> bool {
  matches!(
    status,
    codex_app_server_protocol::HookRunStatus::Failed
      | codex_app_server_protocol::HookRunStatus::Blocked
      | codex_app_server_protocol::HookRunStatus::Stopped
  )
}

fn hook_output_text(run: &codex_app_server_protocol::HookRunSummary) -> Option<String> {
  let mut entries = run
    .entries
    .iter()
    .map(|entry| entry.text.trim())
    .filter(|text| !text.is_empty())
    .map(ToOwned::to_owned)
    .collect::<Vec<_>>();
  if let Some(message) = run
    .status_message
    .as_deref()
    .map(str::trim)
    .filter(|value| !value.is_empty())
  {
    entries.insert(0, message.to_string());
  }
  (!entries.is_empty()).then(|| entries.join("\n"))
}

fn guardian_review_tool_row(
  review_id: String,
  turn_id: String,
  target_item_id: Option<String>,
  review: codex_app_server_protocol::GuardianApprovalReview,
  action: codex_app_server_protocol::GuardianApprovalReviewAction,
  started: bool,
) -> ToolRow {
  let status = guardian_review_status(review.status, started);
  let risk_level = review
    .risk_level
    .map(|value| format!("{value:?}").to_lowercase());
  let status_label = guardian_review_status_label(review.status).to_string();
  let payload = GuardianAssessmentPayload {
    action: serde_json::to_value(&action).ok(),
    risk_level: risk_level.clone(),
    risk_score: None,
    rationale: review.rationale.clone(),
    status_label: Some(status_label.clone()),
  };
  let output = serde_json::to_string(&payload).unwrap_or_else(|_| status_label.clone());

  ToolRow {
    id: format!("guardian-{review_id}"),
    provider: Provider::Codex,
    family: ToolFamily::Approval,
    kind: ToolKind::GuardianAssessment,
    status,
    title: "Auto-review".to_string(),
    subtitle: risk_level.as_ref().map(|level| format!("{level} risk")),
    summary: review
      .rationale
      .clone()
      .or_else(|| Some(status_label.clone())),
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (status != ToolStatus::Running).then(iso_now),
    duration_ms: None,
    grouping_key: Some(turn_id),
    invocation: json!({
      "action": action,
      "target_item_id": target_item_id,
    }),
    result: Some(json!({
      "output": output,
      "action": payload.action,
      "risk_level": payload.risk_level,
      "rationale": payload.rationale,
      "status_label": payload.status_label,
    })),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }
}

fn guardian_review_status(
  status: codex_app_server_protocol::GuardianApprovalReviewStatus,
  started: bool,
) -> ToolStatus {
  if started
    || matches!(
      status,
      codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress
    )
  {
    return ToolStatus::Running;
  }
  match status {
    codex_app_server_protocol::GuardianApprovalReviewStatus::Approved => ToolStatus::Completed,
    codex_app_server_protocol::GuardianApprovalReviewStatus::Denied
    | codex_app_server_protocol::GuardianApprovalReviewStatus::TimedOut => ToolStatus::Failed,
    codex_app_server_protocol::GuardianApprovalReviewStatus::Aborted => ToolStatus::Cancelled,
    codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress => ToolStatus::Running,
  }
}

fn guardian_review_status_label(
  status: codex_app_server_protocol::GuardianApprovalReviewStatus,
) -> &'static str {
  match status {
    codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress => "reviewing",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Approved => "approved",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Denied => "denied",
    codex_app_server_protocol::GuardianApprovalReviewStatus::TimedOut => "timed out",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Aborted => "aborted",
  }
}

fn map_warning(message: String) -> Vec<ConnectorOutput> {
  if is_suppressed_runtime_warning(&message) {
    warn!(
      message = %message,
      "suppressing Codex app-server runtime warning from timeline"
    );
    return Vec::new();
  }
  let (title, summary, severity) = runtime_warning_notice_copy(&message);
  vec![row_created_output(row_entry(ConversationRow::Notice(
    NoticeRow {
      id: runtime_warning_notice_id(&message),
      kind: NoticeRowKind::Generic,
      severity,
      title,
      summary,
      body: Some(message),
      render_hints: Default::default(),
    },
  )))]
}

fn runtime_warning_notice_id(message: &str) -> String {
  if is_thread_start_skills_trimmed_warning(message) {
    "warning-thread-start-skills-trimmed".to_string()
  } else {
    format!("warning-{}", stable_hash(message))
  }
}

fn runtime_warning_notice_copy(message: &str) -> (String, Option<String>, NoticeRowSeverity) {
  if is_thread_start_skills_trimmed_warning(message) {
    return (
      "Some skills are outside the model-visible list".to_string(),
      Some("Mention a skill by name or path if Codex needs it.".to_string()),
      NoticeRowSeverity::Info,
    );
  }
  (
    "Codex warning".to_string(),
    Some(message.to_string()),
    NoticeRowSeverity::Warning,
  )
}

fn is_suppressed_runtime_warning(message: &str) -> bool {
  is_thread_start_skills_trimmed_warning(message)
    || (message.starts_with("Model metadata for `")
      && message.contains("Defaulting to fallback metadata"))
    || (message.starts_with("Under-development features enabled:")
      && message.contains("codex_hooks"))
}

fn stable_hash(value: &str) -> u64 {
  let mut hash = 0xcbf29ce484222325u64;
  for byte in value.as_bytes() {
    hash ^= u64::from(*byte);
    hash = hash.wrapping_mul(0x100000001b3);
  }
  hash
}

fn map_collab_agent_tool(
  id: String,
  tool: codex_app_server_protocol::CollabAgentTool,
  status: codex_app_server_protocol::CollabAgentToolCallStatus,
  sender_thread_id: String,
  receiver_thread_ids: Vec<String>,
  prompt: Option<String>,
  model: Option<String>,
  reasoning_effort: Option<String>,
  agents_states: HashMap<String, codex_app_server_protocol::CollabAgentState>,
  started: bool,
) -> Vec<ConnectorOutput> {
  let (kind, title) = collab_agent_tool_identity(&tool);
  let running = started
    || matches!(
      status,
      codex_app_server_protocol::CollabAgentToolCallStatus::InProgress
    );
  let success = !matches!(
    status,
    codex_app_server_protocol::CollabAgentToolCallStatus::Failed
  );
  let worker_summary = collab_agent_worker_summary(&receiver_thread_ids);
  let worker_id = receiver_thread_ids.first().cloned();
  let worker_ids = receiver_thread_ids.clone();
  let summary = if running {
    None
  } else {
    Some(format!(
      "{} {}",
      title,
      if success { "completed" } else { "failed" }
    ))
  };
  let invocation = json!({
    "agent_type": collab_agent_tool_name(&tool),
    "worker_ids": worker_ids,
    "worker_id": worker_id,
    "sender_thread_id": sender_thread_id,
    "task_summary": prompt.clone(),
    "model": model.clone(),
    "reasoning_effort": reasoning_effort,
  });
  let result = (!running).then(|| {
    json!({
      "summary": summary,
      "worker_ids": invocation["worker_ids"].clone(),
      "agents_states": agents_states.clone(),
    })
  });
  let row = ToolRow {
    id: id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Agent,
    kind,
    status: if running {
      ToolStatus::Running
    } else if success {
      ToolStatus::Completed
    } else {
      ToolStatus::Failed
    },
    title: title.to_string(),
    subtitle: prompt.clone().or(worker_summary),
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (!running).then(iso_now),
    duration_ms: None,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };

  let mut outputs = tool_row_outputs(id, row, started);
  let subagents = collab_agent_subagents(
    &sender_thread_id,
    prompt.as_deref(),
    model.as_deref(),
    &agents_states,
  );
  if !subagents.is_empty() {
    outputs.push(state_output(ConnectorStateEvent::SubagentsUpdated {
      subagents,
    }));
  }
  outputs
}

fn collab_agent_tool_identity(
  tool: &codex_app_server_protocol::CollabAgentTool,
) -> (ToolKind, &'static str) {
  match tool {
    codex_app_server_protocol::CollabAgentTool::SpawnAgent => (ToolKind::SpawnAgent, "Agent"),
    codex_app_server_protocol::CollabAgentTool::SendInput => {
      (ToolKind::SendAgentInput, "Agent interaction")
    }
    codex_app_server_protocol::CollabAgentTool::ResumeAgent => {
      (ToolKind::ResumeAgent, "Resume agent")
    }
    codex_app_server_protocol::CollabAgentTool::Wait => (ToolKind::WaitAgent, "Waiting for agents"),
    codex_app_server_protocol::CollabAgentTool::CloseAgent => (ToolKind::CloseAgent, "Close agent"),
  }
}

fn collab_agent_tool_name(tool: &codex_app_server_protocol::CollabAgentTool) -> &'static str {
  match tool {
    codex_app_server_protocol::CollabAgentTool::SpawnAgent => "spawn_agent",
    codex_app_server_protocol::CollabAgentTool::SendInput => "send_input",
    codex_app_server_protocol::CollabAgentTool::ResumeAgent => "resume_agent",
    codex_app_server_protocol::CollabAgentTool::Wait => "wait",
    codex_app_server_protocol::CollabAgentTool::CloseAgent => "close_agent",
  }
}

fn collab_agent_worker_summary(receiver_thread_ids: &[String]) -> Option<String> {
  match receiver_thread_ids {
    [] => None,
    [worker_id] => Some(worker_id.clone()),
    many => Some(format!("{} agents", many.len())),
  }
}

fn collab_agent_subagents(
  sender_thread_id: &str,
  prompt: Option<&str>,
  model: Option<&str>,
  agents_states: &HashMap<String, codex_app_server_protocol::CollabAgentState>,
) -> Vec<SubagentInfo> {
  agents_states
    .iter()
    .map(|(agent_id, state)| {
      let now = iso_now();
      let status = map_collab_agent_status(state.status.clone());
      let is_terminal = matches!(
        status,
        SubagentStatus::Completed
          | SubagentStatus::Failed
          | SubagentStatus::Shutdown
          | SubagentStatus::NotFound
      );
      SubagentInfo {
        id: agent_id.clone(),
        agent_type: AgentType::GeneralPurpose,
        started_at: now.clone(),
        ended_at: is_terminal.then(|| now.clone()),
        provider: Some(Provider::Codex),
        label: Some(agent_id.clone()),
        status,
        task_summary: prompt
          .map(str::trim)
          .filter(|value| !value.is_empty())
          .map(ToOwned::to_owned),
        result_summary: (status == SubagentStatus::Completed)
          .then(|| state.message.clone())
          .flatten(),
        error_summary: (status == SubagentStatus::Failed).then(|| {
          state
            .message
            .clone()
            .unwrap_or_else(|| "Agent failed".to_string())
        }),
        parent_subagent_id: Some(sender_thread_id.to_string()),
        model: model.map(ToOwned::to_owned),
        last_activity_at: Some(now),
      }
    })
    .collect()
}

fn map_collab_agent_status(status: codex_app_server_protocol::CollabAgentStatus) -> SubagentStatus {
  match status {
    codex_app_server_protocol::CollabAgentStatus::PendingInit => SubagentStatus::Pending,
    codex_app_server_protocol::CollabAgentStatus::Running => SubagentStatus::Running,
    codex_app_server_protocol::CollabAgentStatus::Interrupted => SubagentStatus::Interrupted,
    codex_app_server_protocol::CollabAgentStatus::Completed => SubagentStatus::Completed,
    codex_app_server_protocol::CollabAgentStatus::Errored => SubagentStatus::Failed,
    codex_app_server_protocol::CollabAgentStatus::Shutdown => SubagentStatus::Shutdown,
    codex_app_server_protocol::CollabAgentStatus::NotFound => SubagentStatus::NotFound,
  }
}

fn map_dynamic_tool(
  id: String,
  tool: String,
  arguments: Value,
  content_items: Option<Vec<DynamicToolCallOutputContentItem>>,
  success: bool,
  duration_ms: Option<i64>,
  started: bool,
) -> Vec<ConnectorOutput> {
  if started {
    let (family, kind, title) = dynamic_tool_identity_from_name(&tool).unwrap_or((
      ToolFamily::Generic,
      ToolKind::DynamicToolCall,
      tool.as_str(),
    ));
    return map_tool_row(
      id,
      family,
      kind,
      title.to_string(),
      None,
      dynamic_tool_invocation(tool, arguments),
      None,
      started,
      success,
      duration_millis(duration_ms),
    );
  }

  let output = dynamic_tool_output_to_text(content_items.as_deref());
  let identity_from_name = dynamic_tool_identity_from_name(&tool);
  let resolved_identity = if tool == "plan_write" {
    identity_from_name
  } else {
    dynamic_tool_identity_from_output(output.as_ref()).or(identity_from_name)
  };
  let (family, kind, title) = resolved_identity.unwrap_or((
    ToolFamily::Generic,
    ToolKind::DynamicToolCall,
    tool.as_str(),
  ));
  let (summary, result) =
    dynamic_tool_result_payload(tool.as_str(), kind, &arguments, output.as_ref());

  map_tool_row(
    id,
    family,
    kind,
    title.to_string(),
    summary,
    dynamic_tool_invocation(tool, arguments),
    Some(result),
    started,
    success,
    duration_millis(duration_ms),
  )
}

fn dynamic_tool_invocation(tool_name: String, arguments: Value) -> Value {
  json!({
    "tool_name": tool_name,
    "raw_input": arguments,
  })
}

fn dynamic_tool_output_to_text(
  content_items: Option<&[DynamicToolCallOutputContentItem]>,
) -> Option<String> {
  let mut lines = Vec::new();
  for item in content_items.unwrap_or_default() {
    match item {
      DynamicToolCallOutputContentItem::InputText { text } if !text.is_empty() => {
        lines.push(text.clone());
      }
      DynamicToolCallOutputContentItem::InputImage { image_url } => {
        lines.push(format!("[image] {image_url}"));
      }
      DynamicToolCallOutputContentItem::InputText { .. } => {}
    }
  }
  (!lines.is_empty()).then(|| lines.join("\n"))
}

fn dynamic_tool_identity_from_name(
  tool_name: &str,
) -> Option<(ToolFamily, ToolKind, &'static str)> {
  match tool_name {
    "file_read" => Some((ToolFamily::FileRead, ToolKind::Read, "Read")),
    "file_write" => Some((ToolFamily::FileChange, ToolKind::Write, "Write")),
    "file_edit" => Some((ToolFamily::FileChange, ToolKind::Edit, "Edit")),
    "plan_write" => Some((ToolFamily::Plan, ToolKind::Write, "Plan")),
    _ => None,
  }
}

fn dynamic_tool_identity_from_output(
  output: Option<&String>,
) -> Option<(ToolFamily, ToolKind, &'static str)> {
  let object = dynamic_tool_raw_output_value(output)?;
  let object = object.as_object()?;
  if object.contains_key("bytes_written") {
    return Some((ToolFamily::FileChange, ToolKind::Write, "Write"));
  }
  if object.contains_key("replacements") {
    return Some((ToolFamily::FileChange, ToolKind::Edit, "Edit"));
  }
  if object.contains_key("content") && object.contains_key("truncated") {
    return Some((ToolFamily::FileRead, ToolKind::Read, "Read"));
  }
  None
}

fn dynamic_tool_raw_output_value(output: Option<&String>) -> Option<Value> {
  let output = output?;
  match serde_json::from_str::<Value>(output).ok() {
    Some(Value::String(inner)) => serde_json::from_str::<Value>(&inner)
      .ok()
      .or(Some(Value::String(inner))),
    Some(parsed) => Some(parsed),
    None => Some(Value::String(output.clone())),
  }
}

fn dynamic_tool_result_payload(
  tool_name: &str,
  kind: ToolKind,
  arguments: &Value,
  output: Option<&String>,
) -> (Option<String>, Value) {
  let raw_output = dynamic_tool_raw_output_value(output);
  let object = raw_output.as_ref().and_then(Value::as_object);
  let path = object
    .and_then(|map| map.get("path"))
    .and_then(Value::as_str)
    .map(ToOwned::to_owned);
  let replacements = object
    .and_then(|map| map.get("replacements"))
    .and_then(Value::as_u64);
  let bytes_written = object
    .and_then(|map| map.get("bytes_written"))
    .and_then(Value::as_u64);
  let read_content = object
    .and_then(|map| map.get("content"))
    .and_then(Value::as_str)
    .map(ToOwned::to_owned);
  let read_truncated = object
    .and_then(|map| map.get("truncated"))
    .and_then(Value::as_bool);

  let output_text = match kind {
    ToolKind::Read => read_content.clone(),
    ToolKind::Write => bytes_written
      .map(|count| {
        if tool_name == "plan_write" {
          path
            .as_deref()
            .map(|value| format!("Saved plan ({count} bytes) to {value}"))
            .unwrap_or_else(|| format!("Saved plan ({count} bytes)"))
        } else {
          path
            .as_deref()
            .map(|value| format!("Wrote {count} bytes to {value}"))
            .unwrap_or_else(|| format!("Wrote {count} bytes"))
        }
      })
      .or_else(|| output.cloned()),
    ToolKind::Edit => replacements
      .map(|count| {
        path
          .as_deref()
          .map(|value| format!("Applied {count} replacement(s) in {value}"))
          .unwrap_or_else(|| format!("Applied {count} replacement(s)"))
      })
      .or_else(|| output.cloned()),
    _ => output.cloned(),
  };

  let summary = match kind {
    ToolKind::Read => path
      .as_deref()
      .map(|value| format!("Read {value}"))
      .or_else(|| Some("Read file".to_string())),
    ToolKind::Write | ToolKind::Edit => output_text.clone().or_else(|| output.cloned()),
    _ => output.cloned(),
  };

  let mut result = serde_json::Map::new();
  result.insert("tool_name".to_string(), json!(tool_name));
  result.insert("raw_input".to_string(), arguments.clone());
  if let Some(raw_output) = raw_output {
    result.insert("raw_output".to_string(), raw_output);
  }
  if let Some(summary_text) = summary.as_ref() {
    result.insert("summary".to_string(), json!(summary_text));
  }
  if let Some(output_text) = output_text.as_ref() {
    result.insert("output".to_string(), json!(output_text));
  }
  if let Some(path) = path.as_ref() {
    result.insert("path".to_string(), json!(path));
  }
  if let Some(bytes_written) = bytes_written {
    result.insert("bytes_written".to_string(), json!(bytes_written));
  }
  if let Some(replacements) = replacements {
    result.insert("replacements".to_string(), json!(replacements));
  }
  if let Some(truncated) = read_truncated {
    result.insert("truncated".to_string(), json!(truncated));
  }

  (summary, Value::Object(result))
}

fn map_tool_row(
  id: String,
  family: ToolFamily,
  kind: ToolKind,
  title: String,
  summary: Option<String>,
  invocation: serde_json::Value,
  result: Option<serde_json::Value>,
  started: bool,
  success: bool,
  duration_ms: Option<u64>,
) -> Vec<ConnectorOutput> {
  let row = ToolRow {
    id: id.clone(),
    provider: Provider::Codex,
    family,
    kind,
    status: if started {
      ToolStatus::Running
    } else if success {
      ToolStatus::Completed
    } else {
      ToolStatus::Failed
    },
    title,
    subtitle: None,
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (!started).then(iso_now),
    duration_ms,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };
  tool_row_outputs(id, row, started)
}

fn tool_row_outputs(id: String, row: ToolRow, started: bool) -> Vec<ConnectorOutput> {
  if started {
    vec![row_created_output(tool_row_entry(row))]
  } else {
    vec![row_updated_output(id, tool_row_entry(row))]
  }
}

fn duration_millis(value: Option<i64>) -> Option<u64> {
  value.and_then(|value| u64::try_from(value).ok())
}

fn command_execution_tool_status(
  status: codex_app_server_protocol::CommandExecutionStatus,
  is_running: bool,
  exit_code: Option<i32>,
) -> ToolStatus {
  if is_running {
    return ToolStatus::Running;
  }

  match status {
    codex_app_server_protocol::CommandExecutionStatus::Completed => ToolStatus::Completed,
    codex_app_server_protocol::CommandExecutionStatus::Failed => ToolStatus::Failed,
    codex_app_server_protocol::CommandExecutionStatus::Declined => ToolStatus::Cancelled,
    codex_app_server_protocol::CommandExecutionStatus::InProgress => {
      if exit_code.unwrap_or(1) == 0 {
        ToolStatus::Completed
      } else {
        ToolStatus::Failed
      }
    }
  }
}

fn output_buffer_key(kind: &str, item_id: &str) -> String {
  format!("{kind}-output-{item_id}")
}

fn file_change_tool_row(
  id: String,
  changes: Vec<FileUpdateChange>,
  status: PatchApplyStatus,
  started: bool,
  output: Option<String>,
) -> ToolRow {
  let (files, diff, invocation) = file_change_invocation(&changes);
  let first_file = files
    .first()
    .cloned()
    .unwrap_or_else(|| "Apply patch".to_string());
  let tool_status = file_change_tool_status(status, started);
  let output = output.filter(|value| !value.trim().is_empty());
  let summary = match tool_status {
    ToolStatus::Running => None,
    ToolStatus::Completed => output.clone().or_else(|| Some("Patch applied".to_string())),
    ToolStatus::Cancelled => Some("Patch declined".to_string()),
    ToolStatus::Failed => output.clone().or_else(|| Some("Patch failed".to_string())),
    ToolStatus::Pending | ToolStatus::Blocked | ToolStatus::NeedsInput => None,
  };
  let result = if output.is_some() || !diff.is_empty() {
    Some(json!({
      "tool_name": "Edit",
      "summary": summary.clone(),
      "output": output.unwrap_or_default(),
      "diff": diff,
    }))
  } else {
    None
  };

  ToolRow {
    id,
    provider: Provider::Codex,
    family: ToolFamily::FileChange,
    kind: ToolKind::Edit,
    status: tool_status,
    title: first_file,
    subtitle: (!files.is_empty()).then(|| files.join(", ")),
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (tool_status != ToolStatus::Running).then(iso_now),
    duration_ms: None,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }
}

fn file_change_tool_status(status: PatchApplyStatus, started: bool) -> ToolStatus {
  if started || matches!(status, PatchApplyStatus::InProgress) {
    ToolStatus::Running
  } else {
    match status {
      PatchApplyStatus::Completed => ToolStatus::Completed,
      PatchApplyStatus::Failed => ToolStatus::Failed,
      PatchApplyStatus::Declined => ToolStatus::Cancelled,
      PatchApplyStatus::InProgress => ToolStatus::Running,
    }
  }
}

fn file_change_invocation(
  changes: &[FileUpdateChange],
) -> (Vec<String>, String, serde_json::Value) {
  let mut changes = changes.iter().collect::<Vec<_>>();
  changes.sort_by(|left, right| left.path.cmp(&right.path));

  let files = changes
    .iter()
    .map(|change| change.path.clone())
    .collect::<Vec<_>>();
  let diff = changes
    .iter()
    .map(|change| file_update_change_unified_diff(change))
    .collect::<Vec<_>>()
    .join("\n\n");
  let first_file = files.first().cloned().unwrap_or_default();

  (
    files,
    diff.clone(),
    json!({
      "path": first_file,
      "diff": diff,
      "changes": changes,
    }),
  )
}

fn file_update_change_unified_diff(change: &FileUpdateChange) -> String {
  if change.diff.starts_with("--- ") || change.diff.starts_with("diff --git ") {
    return change.diff.clone();
  }

  match &change.kind {
    PatchChangeKind::Add => {
      let content = prefixed_lines(&change.diff, '+');
      format!("--- /dev/null\n+++ {}\n{}", change.path, content)
    }
    PatchChangeKind::Delete => {
      let content = prefixed_lines(&change.diff, '-');
      format!("--- {}\n+++ /dev/null\n{}", change.path, content)
    }
    PatchChangeKind::Update { move_path } => {
      let new_path = move_path
        .as_ref()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| change.path.clone());
      format!("--- {}\n+++ {}\n{}", change.path, new_path, change.diff)
    }
  }
}

fn prefixed_lines(value: &str, prefix: char) -> String {
  value
    .lines()
    .map(|line| format!("{prefix}{line}"))
    .collect::<Vec<_>>()
    .join("\n")
}

fn map_token_usage(usage: codex_app_server_protocol::ThreadTokenUsage) -> Vec<ConnectorOutput> {
  let live = TokenUsage {
    input_tokens: usage.last.input_tokens.max(0) as u64,
    output_tokens: usage.last.output_tokens.max(0) as u64,
    cached_tokens: usage.last.cached_input_tokens.max(0) as u64,
    context_window: usage.model_context_window.unwrap_or_default().max(0) as u64,
  };
  let accounting = TokenUsage {
    input_tokens: usage.total.input_tokens.max(0) as u64,
    output_tokens: usage.total.output_tokens.max(0) as u64,
    cached_tokens: usage.total.cached_input_tokens.max(0) as u64,
    context_window: usage.model_context_window.unwrap_or_default().max(0) as u64,
  };

  vec![
    state_output(ConnectorStateEvent::TokensUpdated {
      usage: live,
      snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
    }),
    state_output(ConnectorStateEvent::TurnUsageUpdated {
      usage: accounting,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    }),
  ]
}

#[cfg(test)]
mod tests {
  use super::*;
  use codex_app_server_protocol::{
    CollabAgentState, CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus,
    CommandExecutionOutputDeltaNotification, CommandExecutionStatus,
    DynamicToolCallOutputContentItem, FileUpdateChange, GuardianApprovalReview,
    GuardianApprovalReviewAction, GuardianApprovalReviewStatus, GuardianCommandSource,
    GuardianRiskLevel, ItemCompletedNotification, PatchApplyStatus, PatchChangeKind,
    TerminalInteractionNotification, ThreadTokenUsage, TokenUsageBreakdown,
  };

  fn absolute_test_path(path: &str) -> AbsolutePathBuf {
    AbsolutePathBuf::from_absolute_path(path).expect("absolute test path")
  }

  fn usage_breakdown(
    total_tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
  ) -> TokenUsageBreakdown {
    TokenUsageBreakdown {
      total_tokens,
      input_tokens,
      cached_input_tokens,
      output_tokens,
      reasoning_output_tokens: 0,
    }
  }

  #[test]
  fn token_usage_uses_last_for_live_context_and_total_for_accounting() {
    let outputs = map_token_usage(ThreadTokenUsage {
      total: usage_breakdown(101_600_000, 101_600_000, 12_000, 50_000),
      last: usage_breakdown(64_000, 64_000, 8_000, 2_000),
      model_context_window: Some(258_400),
    });

    let live = outputs
      .first()
      .and_then(ConnectorOutput::as_state_event)
      .expect("live token output");
    let accounting = outputs
      .get(1)
      .and_then(ConnectorOutput::as_state_event)
      .expect("accounting token output");

    match live {
      ConnectorStateEvent::TokensUpdated {
        usage,
        snapshot_kind,
      } => {
        assert_eq!(*snapshot_kind, TokenUsageSnapshotKind::ContextTurn);
        assert_eq!(usage.input_tokens, 64_000);
        assert_eq!(usage.cached_tokens, 8_000);
        assert_eq!(usage.output_tokens, 2_000);
        assert_eq!(usage.context_window, 258_400);
      }
      other => panic!("expected live tokens_updated output, got {other:?}"),
    }

    match accounting {
      ConnectorStateEvent::TurnUsageUpdated {
        usage,
        snapshot_kind,
      } => {
        assert_eq!(*snapshot_kind, TokenUsageSnapshotKind::LifetimeTotals);
        assert_eq!(usage.input_tokens, 101_600_000);
        assert_eq!(usage.cached_tokens, 12_000);
        assert_eq!(usage.output_tokens, 50_000);
        assert_eq!(usage.context_window, 258_400);
      }
      other => panic!("expected turn_usage_updated output, got {other:?}"),
    }
  }

  #[test]
  fn startup_skills_trimmed_warning_stays_out_of_timeline() {
    let outputs = map_warning(
      "Some enabled skills were not included in the model-visible skills list for this session."
        .to_string(),
    );

    assert!(outputs.is_empty());
  }

  #[test]
  fn file_change_row_normalizes_app_server_add_content_for_diff_display() {
    let row = file_change_tool_row(
      "patch-1".to_string(),
      vec![FileUpdateChange {
        path: "runtime.js".to_string(),
        kind: PatchChangeKind::Add,
        diff: "let ready = true;\nexport { ready };".to_string(),
      }],
      PatchApplyStatus::Completed,
      false,
      Some("applied".to_string()),
    );

    assert_eq!(row.title, "runtime.js");
    assert_eq!(row.subtitle.as_deref(), Some("runtime.js"));

    let diff = row.invocation["diff"].as_str().expect("diff");
    assert!(diff.contains("--- /dev/null"));
    assert!(diff.contains("+++ runtime.js"));
    assert!(diff.contains("+let ready = true;"));

    let entry = tool_row_entry(row);
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    let display = tool.tool_display.expect("tool display");
    let preview = display.diff_preview.expect("diff preview");

    assert_eq!(preview.additions, 2);
    assert_eq!(preview.deletions, 0);
    assert_eq!(
      preview.preview_lines.first().map(String::as_str),
      Some("let ready = true;")
    );
  }

  #[test]
  fn dynamic_file_tool_rows_keep_native_file_display_shape() {
    let outputs = map_dynamic_tool(
      "dynamic-write-1".to_string(),
      "file_write".to_string(),
      json!({ "path": "/tmp/runtime.js" }),
      Some(vec![DynamicToolCallOutputContentItem::InputText {
        text: "{\"path\":\"/tmp/runtime.js\",\"bytes_written\":42}".to_string(),
      }]),
      true,
      Some(12),
      false,
    );

    let state = outputs
      .first()
      .and_then(ConnectorOutput::as_state_event)
      .expect("dynamic tool row update");
    let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = state else {
      panic!("expected row update");
    };
    let ConversationRow::Tool(tool) = &entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Write");
    assert_eq!(tool.result.as_ref().unwrap()["path"], "/tmp/runtime.js");
    assert_eq!(
      tool.result.as_ref().unwrap()["output"],
      "Wrote 42 bytes to /tmp/runtime.js"
    );

    let display = tool.tool_display.as_ref().expect("tool display");
    assert_eq!(display.tool_type, "write");
    assert_eq!(display.summary, "Wrote 42 bytes to /tmp/runtime.js");
  }

  #[test]
  fn declined_command_execution_maps_to_cancelled_tool_status() {
    assert_eq!(
      command_execution_tool_status(CommandExecutionStatus::Declined, false, None),
      ToolStatus::Cancelled
    );
  }

  #[tokio::test]
  async fn command_execution_creates_pty_without_process_id() {
    let outputs = map_item(
      ThreadItem::CommandExecution {
        id: "cmd-1".to_string(),
        command: "cargo test".to_string(),
        cwd: absolute_test_path("/tmp/orbitdock"),
        process_id: None,
        source: codex_app_server_protocol::CommandExecutionSource::Agent,
        status: CommandExecutionStatus::InProgress,
        command_actions: Vec::new(),
        aggregated_output: None,
        exit_code: None,
        duration_ms: None,
      },
      true,
      &test_route(),
    )
    .await;

    assert!(outputs.iter().any(|output| {
      matches!(
        output,
        ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyCreated { tool_id })
          if tool_id == "cmd-1"
      )
    }));
  }

  #[tokio::test]
  async fn command_execution_output_deltas_persist_into_completed_row() {
    let route = test_route();
    let _ = map_notification(
      ServerNotification::CommandExecutionOutputDelta(CommandExecutionOutputDeltaNotification {
        thread_id: "thread-1".to_string(),
        turn_id: "turn-1".to_string(),
        item_id: "cmd-1".to_string(),
        delta: "Compiling ring v0.17.14\n".to_string(),
      }),
      &route,
    )
    .await;
    let outputs = map_notification(
      ServerNotification::ItemCompleted(ItemCompletedNotification {
        thread_id: "thread-1".to_string(),
        turn_id: "turn-1".to_string(),
        item: ThreadItem::CommandExecution {
          id: "cmd-1".to_string(),
          command: "cargo test".to_string(),
          cwd: absolute_test_path("/tmp/orbitdock"),
          process_id: None,
          source: codex_app_server_protocol::CommandExecutionSource::Agent,
          status: CommandExecutionStatus::Completed,
          command_actions: Vec::new(),
          aggregated_output: None,
          exit_code: Some(0),
          duration_ms: Some(1000),
        },
      }),
      &route,
    )
    .await;

    let state = outputs
      .iter()
      .find_map(ConnectorOutput::as_state_event)
      .expect("row update");
    let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = state else {
      panic!("expected row update");
    };
    let ConversationRow::Tool(tool) = &entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.summary.as_deref(), Some("Compiling ring v0.17.14\n"));
    assert_eq!(
      tool.result.as_ref().unwrap()["output"],
      "Compiling ring v0.17.14\n"
    );
    assert_eq!(
      tool
        .tool_display
        .as_ref()
        .unwrap()
        .output_preview
        .as_deref(),
      Some("Compiling ring v0.17.14")
    );
    assert!(outputs.iter().any(|output| {
      matches!(
        output,
        ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyExited { tool_id, exit_code })
          if tool_id == "cmd-1" && *exit_code == Some(0)
      )
    }));
  }

  #[test]
  fn terminal_interaction_stdin_flows_to_pty_output() {
    let outputs = map_terminal_interaction(TerminalInteractionNotification {
      thread_id: "thread-1".to_string(),
      turn_id: "turn-1".to_string(),
      item_id: "cmd-1".to_string(),
      process_id: "process-1".to_string(),
      stdin: "y\n".to_string(),
    });

    let Some(ConnectorOutput::Transport(ConnectorTransportEffect::ToolPtyOutput {
      tool_id,
      bytes,
    })) = outputs.first()
    else {
      panic!("expected terminal interaction pty output");
    };
    assert_eq!(tool_id, "cmd-1");
    assert_eq!(bytes, b"y\n");

    assert!(map_terminal_interaction(TerminalInteractionNotification {
      thread_id: "thread-1".to_string(),
      turn_id: "turn-1".to_string(),
      item_id: "cmd-1".to_string(),
      process_id: "process-1".to_string(),
      stdin: String::new(),
    })
    .is_empty());
  }

  #[test]
  fn guardian_review_notifications_keep_auto_review_tool_shape() {
    let row = guardian_review_tool_row(
      "review-1".to_string(),
      "turn-1".to_string(),
      Some("cmd-1".to_string()),
      GuardianApprovalReview {
        status: GuardianApprovalReviewStatus::Approved,
        risk_level: Some(GuardianRiskLevel::High),
        user_authorization: None,
        rationale: Some("Safe after review".to_string()),
      },
      GuardianApprovalReviewAction::Command {
        source: GuardianCommandSource::Shell,
        command: "make test".to_string(),
        cwd: absolute_test_path("/tmp/orbitdock"),
      },
      false,
    );

    assert_eq!(row.id, "guardian-review-1");
    assert_eq!(row.family, ToolFamily::Approval);
    assert_eq!(row.kind, ToolKind::GuardianAssessment);
    assert_eq!(row.status, ToolStatus::Completed);
    assert_eq!(row.grouping_key.as_deref(), Some("turn-1"));
    assert_eq!(row.invocation["action"]["command"], "make test");

    let entry = tool_row_entry(row);
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected guardian tool row");
    };
    let display = tool.tool_display.expect("tool display");
    assert_eq!(display.tool_type, "guardianAssessment");
    assert_eq!(display.summary, "Safe after review");
    assert_eq!(display.subtitle.as_deref(), Some("high risk"));
  }

  #[test]
  fn collab_agent_item_keeps_agent_tool_and_subagent_state() {
    let outputs = map_collab_agent_tool(
      "collab-1".to_string(),
      CollabAgentTool::SpawnAgent,
      CollabAgentToolCallStatus::Completed,
      "parent-thread".to_string(),
      vec!["child-thread".to_string()],
      Some("Inspect the codebase".to_string()),
      Some("gpt-5.4-mini".to_string()),
      Some("medium".to_string()),
      HashMap::from([(
        "child-thread".to_string(),
        CollabAgentState {
          status: CollabAgentStatus::Completed,
          message: Some("Done".to_string()),
        },
      )]),
      false,
    );

    let row_event = outputs
      .first()
      .and_then(ConnectorOutput::as_state_event)
      .expect("row update");
    let ConnectorStateEvent::ConversationRowUpdated { entry, .. } = row_event else {
      panic!("expected collab row update");
    };
    let ConversationRow::Tool(tool) = &entry.row else {
      panic!("expected collab tool row");
    };
    assert_eq!(tool.family, ToolFamily::Agent);
    assert_eq!(tool.kind, ToolKind::SpawnAgent);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.invocation["worker_id"], "child-thread");

    let subagents_event = outputs
      .get(1)
      .and_then(ConnectorOutput::as_state_event)
      .expect("subagent update");
    let ConnectorStateEvent::SubagentsUpdated { subagents } = subagents_event else {
      panic!("expected subagents update");
    };
    assert_eq!(subagents.len(), 1);
    assert_eq!(subagents[0].id, "child-thread");
    assert_eq!(subagents[0].status, SubagentStatus::Completed);
    assert_eq!(
      subagents[0].task_summary.as_deref(),
      Some("Inspect the codebase")
    );
  }

  #[tokio::test]
  async fn review_mode_items_surface_review_text() {
    let notice = map_item(
      ThreadItem::EnteredReviewMode {
        id: "review-enter".to_string(),
        review: "Review requested".to_string(),
      },
      false,
      &test_route(),
    )
    .await;
    let output = notice
      .into_iter()
      .next()
      .and_then(|output| output.as_state_event().cloned())
      .expect("notice row");
    let ConnectorStateEvent::ConversationRowCreated(entry) = output else {
      panic!("expected created row");
    };
    let ConversationRow::Notice(row) = entry.row else {
      panic!("expected notice row");
    };
    assert_eq!(row.title, "Review mode");
    assert_eq!(row.summary.as_deref(), Some("Review requested"));

    let assistant = map_item(
      ThreadItem::ExitedReviewMode {
        id: "review-exit".to_string(),
        review: "## Code Review Feedback".to_string(),
      },
      false,
      &test_route(),
    )
    .await
    .into_iter()
    .next()
    .and_then(|output| output.as_state_event().cloned())
    .expect("assistant row");
    let ConnectorStateEvent::ConversationRowCreated(entry) = assistant else {
      panic!("expected created row");
    };
    let ConversationRow::Assistant(row) = entry.row else {
      panic!("expected assistant row");
    };
    assert_eq!(row.content, "## Code Review Feedback");
  }

  fn test_route() -> AppServerSessionRoute {
    let (output_tx, _) = mpsc::channel(1);
    AppServerSessionRoute {
      output_tx,
      active_turn_id: Arc::new(Mutex::new(None)),
      pending_requests: Arc::new(Mutex::new(HashMap::new())),
      state: Arc::new(AppServerEventState {
        delta_buffers: Arc::new(Mutex::new(HashMap::new())),
        streaming_message: Arc::new(Mutex::new(None)),
      }),
    }
  }
}

pub(crate) fn request_key(request_id: &RequestId) -> String {
  match request_id {
    RequestId::Integer(value) => value.to_string(),
    RequestId::String(value) => value.clone(),
  }
}

pub(crate) fn exec_approval_response(
  decision: crate::session::CodexExecApproval,
) -> CommandExecutionRequestApprovalResponse {
  CommandExecutionRequestApprovalResponse {
    decision: match decision {
      crate::session::CodexExecApproval::Approved => CommandExecutionApprovalDecision::Accept,
      crate::session::CodexExecApproval::ApprovedForSession => {
        CommandExecutionApprovalDecision::AcceptForSession
      }
      crate::session::CodexExecApproval::ApprovedAlways { proposed_amendment } => {
        proposed_amendment
          .map(
            |command| CommandExecutionApprovalDecision::AcceptWithExecpolicyAmendment {
              execpolicy_amendment: codex_app_server_protocol::ExecPolicyAmendment { command },
            },
          )
          .unwrap_or(CommandExecutionApprovalDecision::AcceptForSession)
      }
      crate::session::CodexExecApproval::NetworkPolicyAmendment {
        network_policy_amendment,
      } => CommandExecutionApprovalDecision::ApplyNetworkPolicyAmendment {
        network_policy_amendment: network_policy_amendment.into(),
      },
      crate::session::CodexExecApproval::Abort => CommandExecutionApprovalDecision::Cancel,
      crate::session::CodexExecApproval::Denied => CommandExecutionApprovalDecision::Decline,
    },
  }
}

pub(crate) fn patch_approval_response(
  decision: crate::session::CodexPatchApproval,
) -> FileChangeRequestApprovalResponse {
  FileChangeRequestApprovalResponse {
    decision: match decision {
      crate::session::CodexPatchApproval::Approved => FileChangeApprovalDecision::Accept,
      crate::session::CodexPatchApproval::ApprovedForSession => {
        FileChangeApprovalDecision::AcceptForSession
      }
      crate::session::CodexPatchApproval::Abort => FileChangeApprovalDecision::Cancel,
      crate::session::CodexPatchApproval::Denied => FileChangeApprovalDecision::Decline,
    },
  }
}

pub(crate) fn question_response(
  answers: HashMap<String, Vec<String>>,
) -> ToolRequestUserInputResponse {
  ToolRequestUserInputResponse {
    answers: answers
      .into_iter()
      .map(|(key, answers)| (key, ToolRequestUserInputAnswer { answers }))
      .collect(),
  }
}

pub(crate) fn permissions_response(
  permissions: serde_json::Value,
  scope: orbitdock_protocol::PermissionGrantScope,
) -> Result<PermissionsRequestApprovalResponse, ConnectorError> {
  let permissions = serde_json::from_value(permissions).map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to decode granted permissions payload: {error}"
    ))
  })?;
  Ok(PermissionsRequestApprovalResponse {
    permissions,
    scope: match scope {
      orbitdock_protocol::PermissionGrantScope::Turn => {
        codex_app_server_protocol::PermissionGrantScope::Turn
      }
      orbitdock_protocol::PermissionGrantScope::Session => {
        codex_app_server_protocol::PermissionGrantScope::Session
      }
    },
  })
}

pub(crate) fn dynamic_tool_response(
  response: codex_protocol::dynamic_tools::DynamicToolResponse,
) -> Result<DynamicToolCallResponse, ConnectorError> {
  serde_json::from_value(serde_json::to_value(response).map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to encode dynamic tool response: {error}"))
  })?)
  .map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to convert dynamic tool response for app-server: {error}"
    ))
  })
}

pub(crate) fn path_bufs(cwds: Vec<String>) -> Vec<PathBuf> {
  cwds.into_iter().map(PathBuf::from).collect()
}
