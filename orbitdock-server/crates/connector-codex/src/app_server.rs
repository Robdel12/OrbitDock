use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, OnceLock};

use codex_app_server_client::InProcessAppServerRequestHandle;
use codex_app_server_protocol::{
  CancelLoginAccountParams, CancelLoginAccountResponse, ClientRequest, CollaborationModeListParams,
  CollaborationModeListResponse, ConfigBatchWriteParams, ConfigReadParams, ConfigReadResponse,
  ConfigValueWriteParams, ConfigWriteResponse, GetAccountParams, GetAccountRateLimitsResponse,
  GetAccountResponse, ListMcpServerStatusParams, ListMcpServerStatusResponse, LoginAccountParams,
  LoginAccountResponse, LogoutAccountResponse, McpServerOauthLoginParams,
  McpServerOauthLoginResponse, McpServerRefreshResponse, McpServerStatusDetail, ModelListParams,
  ModelListResponse, PluginInstallParams, PluginInstallResponse, PluginListParams,
  PluginListResponse, PluginUninstallParams, PluginUninstallResponse, RequestId,
  ServerNotification, SkillsListParams, SkillsListResponse, ThreadCompactStartParams,
  ThreadCompactStartResponse, ThreadForkParams, ThreadForkResponse, ThreadRollbackParams,
  ThreadRollbackResponse, ThreadSetNameParams, ThreadSetNameResponse, ThreadShellCommandParams,
  ThreadShellCommandResponse, ThreadStartParams, ThreadStartResponse, TurnInterruptParams,
  TurnInterruptResponse, TurnStartParams, TurnStartResponse, TurnSteerParams, TurnSteerResponse,
};
use codex_utils_absolute_path::AbsolutePathBuf;
use orbitdock_connector_core::{ConnectorError, ConnectorOutput};
use serde::de::DeserializeOwned;
use serde::Serialize;
use tokio::sync::{broadcast, mpsc, Mutex};

use crate::runtime::StreamingMessage;
use crate::{CodexConfigOverrides, CodexRuntimeOverrides};

pub(crate) mod compat;
mod host;
pub(crate) mod item_mapping;
pub(crate) mod notification_mapping;
mod request_mapping;
pub(crate) mod response_codec;
mod router;

use self::host::start_app_server;

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
    let mut cursor = None;
    let mut data = Vec::new();

    loop {
      let response: ListMcpServerStatusResponse = self
        .request(ClientRequest::McpServerStatusList {
          request_id: self.next_request_id(),
          params: ListMcpServerStatusParams {
            cursor,
            limit: Some(100),
            detail: Some(McpServerStatusDetail::ToolsAndAuthOnly),
          },
        })
        .await?;

      data.extend(response.data);
      cursor = response.next_cursor;
      if cursor.is_none() {
        return Ok(ListMcpServerStatusResponse {
          data,
          next_cursor: None,
        });
      }
    }
  }

  pub async fn mcp_server_oauth_login(
    &self,
    name: String,
  ) -> Result<McpServerOauthLoginResponse, ConnectorError> {
    self
      .request(ClientRequest::McpServerOauthLogin {
        request_id: self.next_request_id(),
        params: McpServerOauthLoginParams {
          name,
          scopes: None,
          timeout_secs: None,
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

  pub async fn thread_shell_command(
    &self,
    thread_id: String,
    command: String,
  ) -> Result<ThreadShellCommandResponse, ConnectorError> {
    self
      .request(ClientRequest::ThreadShellCommand {
        request_id: self.next_request_id(),
        params: ThreadShellCommandParams { thread_id, command },
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

#[cfg(test)]
#[path = "app_server_tests.rs"]
mod app_server_tests;
