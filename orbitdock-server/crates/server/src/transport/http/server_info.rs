use super::*;
use crate::runtime::server_info::{server_info_message, server_meta};
use crate::transport::http::errors::bad_request;
use orbitdock_protocol::WorkspaceProviderKind;

#[derive(Debug, Serialize)]
pub struct OpenAiKeyStatusResponse {
  pub configured: bool,
}

#[derive(Debug, Deserialize)]
pub struct SetOpenAiKeyRequest {
  pub key: String,
}

#[derive(Debug, Deserialize)]
pub struct SetServerRoleRequest {
  pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct ServerRoleResponse {
  pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderConfigResponse {
  pub workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Deserialize)]
pub struct SetWorkspaceProviderRequest {
  pub workspace_provider: WorkspaceProviderKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceProviderConfigKey {
  PublicServerUrl,
  DaytonaApiUrl,
  DaytonaApiKey,
  DaytonaImage,
  DaytonaTarget,
}

impl WorkspaceProviderConfigKey {
  fn parse(value: &str) -> Option<Self> {
    match value {
      "public-server-url" => Some(Self::PublicServerUrl),
      "daytona-api-url" => Some(Self::DaytonaApiUrl),
      "daytona-api-key" => Some(Self::DaytonaApiKey),
      "daytona-image" => Some(Self::DaytonaImage),
      "daytona-target" => Some(Self::DaytonaTarget),
      _ => None,
    }
  }

  fn key(self) -> &'static str {
    match self {
      Self::PublicServerUrl => "public-server-url",
      Self::DaytonaApiUrl => "daytona-api-url",
      Self::DaytonaApiKey => "daytona-api-key",
      Self::DaytonaImage => "daytona-image",
      Self::DaytonaTarget => "daytona-target",
    }
  }

  fn persisted_key(self) -> &'static str {
    match self {
      Self::PublicServerUrl => "public_server_url",
      Self::DaytonaApiUrl => "daytona_api_url",
      Self::DaytonaApiKey => "daytona_api_key",
      Self::DaytonaImage => "daytona_image",
      Self::DaytonaTarget => "daytona_target",
    }
  }

  fn is_secret(self) -> bool {
    matches!(self, Self::DaytonaApiKey)
  }

  fn env_var(self) -> Option<&'static str> {
    match self {
      Self::PublicServerUrl => Some("ORBITDOCK_PUBLIC_SERVER_URL"),
      Self::DaytonaApiUrl => Some("ORBITDOCK_DAYTONA_API_URL"),
      Self::DaytonaApiKey => Some("ORBITDOCK_DAYTONA_API_KEY"),
      Self::DaytonaImage => Some("ORBITDOCK_DAYTONA_IMAGE"),
      Self::DaytonaTarget => Some("ORBITDOCK_DAYTONA_TARGET"),
    }
  }
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderConfigValueResponse {
  pub key: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub value: Option<String>,
  pub configured: bool,
  pub secret: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SetWorkspaceProviderConfigValueRequest {
  pub value: String,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderTestResponse {
  pub ok: bool,
  pub provider: String,
  pub message: String,
}

pub async fn get_server_meta(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<orbitdock_protocol::ServerMeta> {
  // Activity-based update check: if enough time has passed, spawn a background check
  crate::runtime::background::update_checker::maybe_trigger_check(&state);

  Json(server_meta(&state))
}

#[derive(Debug, Deserialize)]
pub struct SetClientPrimaryClaimRequest {
  pub client_id: String,
  pub device_name: String,
  pub is_primary: bool,
}

pub async fn check_open_ai_key() -> Json<OpenAiKeyStatusResponse> {
  Json(OpenAiKeyStatusResponse {
    configured: crate::support::ai_naming::resolve_api_key().is_some(),
  })
}

pub async fn get_workspace_provider(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<WorkspaceProviderConfigResponse> {
  Json(WorkspaceProviderConfigResponse {
    workspace_provider: state.workspace_provider_kind(),
  })
}

pub async fn set_workspace_provider(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetWorkspaceProviderRequest>,
) -> ApiResult<WorkspaceProviderConfigResponse> {
  info!(
    component = "api",
    event = "api.workspace_provider.set",
    provider = body.workspace_provider.as_str(),
    "Workspace provider updated via REST"
  );

  state.set_workspace_provider_kind(body.workspace_provider);
  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: "workspace_provider".into(),
      value: body.workspace_provider.as_str().to_string(),
    })
    .await;

  Ok(Json(WorkspaceProviderConfigResponse {
    workspace_provider: body.workspace_provider,
  }))
}

pub async fn get_workspace_provider_config_value(
  Path(key): Path<String>,
) -> ApiResult<WorkspaceProviderConfigValueResponse> {
  let key = WorkspaceProviderConfigKey::parse(&key).ok_or_else(|| {
    bad_request(
      "invalid_workspace_provider_config_key",
      format!("Unknown mission provider config key: {key}"),
    )
  })?;
  Ok(Json(read_workspace_provider_config_value(key)))
}

pub async fn set_workspace_provider_config_value(
  State(state): State<Arc<SessionRegistry>>,
  Path(key): Path<String>,
  Json(body): Json<SetWorkspaceProviderConfigValueRequest>,
) -> ApiResult<WorkspaceProviderConfigValueResponse> {
  let key = WorkspaceProviderConfigKey::parse(&key).ok_or_else(|| {
    bad_request(
      "invalid_workspace_provider_config_key",
      format!("Unknown mission provider config key: {key}"),
    )
  })?;

  let value = body.value.trim().to_string();
  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: key.persisted_key().into(),
      value: value.clone(),
    })
    .await;

  let persisted = if value.is_empty() { None } else { Some(value) };
  Ok(Json(resolve_workspace_provider_config_value(
    key, persisted,
  )))
}

pub async fn test_workspace_provider(
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorkspaceProviderTestResponse> {
  let provider = state.workspace_provider_kind();
  let message = match provider {
    WorkspaceProviderKind::Local => "local mission workspace provider is ready".to_string(),
    WorkspaceProviderKind::Daytona => {
      let config = crate::infrastructure::daytona::DaytonaConfig::validate_runtime()
        .map_err(|err| bad_request("workspace_provider_test_failed", err.to_string()))?;
      let client = crate::infrastructure::daytona::DaytonaClient::new(config.clone())
        .map_err(|err| bad_request("workspace_provider_test_failed", err.to_string()))?;
      client
        .check_health()
        .await
        .map_err(|err| bad_request("workspace_provider_test_failed", err.to_string()))?;
      format!(
        "daytona mission workspace provider preflight passed; control plane is reachable at {}",
        config.api_url
      )
    }
  };

  Ok(Json(WorkspaceProviderTestResponse {
    ok: true,
    provider: provider.as_str().to_string(),
    message,
  }))
}

fn read_workspace_provider_config_value(
  key: WorkspaceProviderConfigKey,
) -> WorkspaceProviderConfigValueResponse {
  let persisted = crate::infrastructure::persistence::load_config_value(key.persisted_key())
    .and_then(|value| {
      let trimmed = value.trim().to_string();
      if trimmed.is_empty() {
        None
      } else {
        Some(trimmed)
      }
    });

  resolve_workspace_provider_config_value(key, persisted)
}

fn resolve_workspace_provider_config_value(
  key: WorkspaceProviderConfigKey,
  persisted_value: Option<String>,
) -> WorkspaceProviderConfigValueResponse {
  let env_value = key.env_var().and_then(|env_key| {
    std::env::var(env_key).ok().and_then(|value| {
      let trimmed = value.trim().to_string();
      if trimmed.is_empty() {
        None
      } else {
        Some(trimmed)
      }
    })
  });
  let source = if env_value.is_some() {
    Some("env".to_string())
  } else if persisted_value.is_some() {
    Some("settings".to_string())
  } else {
    None
  };
  let effective_value = env_value.or(persisted_value);

  workspace_provider_config_value_response(key, effective_value, source)
}

fn workspace_provider_config_value_response(
  key: WorkspaceProviderConfigKey,
  value: Option<String>,
  source: Option<String>,
) -> WorkspaceProviderConfigValueResponse {
  WorkspaceProviderConfigValueResponse {
    key: key.key().to_string(),
    value: if key.is_secret() { None } else { value.clone() },
    configured: value.is_some(),
    secret: key.is_secret(),
    source,
  }
}

pub async fn set_open_ai_key(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetOpenAiKeyRequest>,
) -> ApiResult<OpenAiKeyStatusResponse> {
  info!(
    component = "api",
    event = "api.openai_key.set",
    "OpenAI API key set via REST"
  );

  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: "openai_api_key".into(),
      value: body.key,
    })
    .await;

  Ok(Json(OpenAiKeyStatusResponse { configured: true }))
}

pub async fn set_server_role(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetServerRoleRequest>,
) -> ApiResult<ServerRoleResponse> {
  info!(
    component = "api",
    event = "api.server_role.set",
    is_primary = body.is_primary,
    "Server role updated via REST"
  );

  let _changed = state.set_primary(body.is_primary);

  let role_value = if body.is_primary {
    "primary".to_string()
  } else {
    "secondary".to_string()
  };
  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: "server_role".into(),
      value: role_value,
    })
    .await;

  let update = server_info_message(&state);
  state.broadcast_to_list(update);

  Ok(Json(ServerRoleResponse {
    is_primary: body.is_primary,
  }))
}

pub async fn set_client_primary_claim(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetClientPrimaryClaimRequest>,
) -> Json<AcceptedResponse> {
  state.set_client_primary_claim(0, body.client_id, body.device_name, body.is_primary);
  let update = server_info_message(&state);
  state.broadcast_to_list(update);
  Json(AcceptedResponse { accepted: true })
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::transport::http::test_support::new_persist_test_state;

  struct EnvVarGuard {
    key: &'static str,
    original: Option<String>,
  }

  impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
      let original = std::env::var(key).ok();
      unsafe {
        std::env::set_var(key, value);
      }
      Self { key, original }
    }
  }

  impl Drop for EnvVarGuard {
    fn drop(&mut self) {
      match &self.original {
        Some(value) => unsafe {
          std::env::set_var(self.key, value);
        },
        None => unsafe {
          std::env::remove_var(self.key);
        },
      }
    }
  }

  #[tokio::test]
  async fn workspace_provider_endpoint_returns_authoritative_state_and_enqueues_config_write() {
    let (state, mut persist_rx, _db_path, guard) = new_persist_test_state(true).await;
    drop(guard);

    let Json(updated) = set_workspace_provider(
      State(state.clone()),
      Json(SetWorkspaceProviderRequest {
        workspace_provider: WorkspaceProviderKind::Local,
      }),
    )
    .await
    .expect("set workspace provider should succeed");

    assert_eq!(updated.workspace_provider, WorkspaceProviderKind::Local);
    assert_eq!(
      state.workspace_provider_kind(),
      WorkspaceProviderKind::Local
    );

    let command = persist_rx
      .recv()
      .await
      .expect("workspace provider update should enqueue persistence");
    assert!(matches!(
        command,
        PersistCommand::SetConfig { ref key, ref value }
            if key == "workspace_provider" && value == "local"
    ));

    let Json(reloaded) = get_workspace_provider(State(state)).await;
    assert_eq!(reloaded.workspace_provider, WorkspaceProviderKind::Local);
  }

  #[tokio::test]
  async fn workspace_provider_config_endpoint_redacts_secret_values() {
    let (state, mut persist_rx, _db_path, guard) = new_persist_test_state(true).await;
    drop(guard);

    let Json(updated) = set_workspace_provider_config_value(
      State(state),
      Path("daytona-api-key".to_string()),
      Json(SetWorkspaceProviderConfigValueRequest {
        value: "secret-token".to_string(),
      }),
    )
    .await
    .expect("set workspace provider config should succeed");

    assert_eq!(updated.key, "daytona-api-key");
    assert!(updated.configured);
    assert!(updated.secret);
    assert_eq!(updated.value, None);
    assert_eq!(updated.source.as_deref(), Some("settings"));

    let command = persist_rx
      .recv()
      .await
      .expect("workspace provider config update should enqueue persistence");
    assert!(matches!(
      command,
      PersistCommand::SetConfig { ref key, ref value }
        if key == "daytona_api_key" && value == "secret-token"
    ));
  }

  #[tokio::test]
  async fn workspace_provider_test_reports_local_provider_ready() {
    let (state, _persist_rx, _db_path, guard) = new_persist_test_state(true).await;
    drop(guard);

    let Json(response) = test_workspace_provider(State(state))
      .await
      .expect("provider test should succeed");

    assert!(response.ok);
    assert_eq!(response.provider, "local");
    assert!(response.message.contains("ready"));
  }

  #[tokio::test]
  async fn workspace_provider_config_endpoint_reports_env_override_as_effective_source() {
    let _env_guard = EnvVarGuard::set("ORBITDOCK_DAYTONA_API_URL", "https://env.daytona.example");
    let (state, mut persist_rx, _db_path, guard) = new_persist_test_state(true).await;
    drop(guard);

    let Json(updated) = set_workspace_provider_config_value(
      State(state),
      Path("daytona-api-url".to_string()),
      Json(SetWorkspaceProviderConfigValueRequest {
        value: "https://settings.daytona.example".to_string(),
      }),
    )
    .await
    .expect("set workspace provider config should succeed");

    assert_eq!(updated.key, "daytona-api-url");
    assert_eq!(
      updated.value.as_deref(),
      Some("https://env.daytona.example")
    );
    assert!(updated.configured);
    assert_eq!(updated.source.as_deref(), Some("env"));

    let command = persist_rx
      .recv()
      .await
      .expect("workspace provider config update should enqueue persistence");
    assert!(matches!(
      command,
      PersistCommand::SetConfig { ref key, ref value }
        if key == "daytona_api_url" && value == "https://settings.daytona.example"
    ));

    let Json(reloaded) = get_workspace_provider_config_value(Path("daytona-api-url".to_string()))
      .await
      .expect("get workspace provider config should succeed");
    assert_eq!(
      reloaded.value.as_deref(),
      Some("https://env.daytona.example")
    );
    assert_eq!(reloaded.source.as_deref(), Some("env"));
  }

  #[tokio::test]
  async fn workspace_provider_config_endpoint_treats_blank_values_as_clear() {
    let (state, mut persist_rx, _db_path, guard) = new_persist_test_state(true).await;
    drop(guard);

    let Json(updated) = set_workspace_provider_config_value(
      State(state),
      Path("daytona-target".to_string()),
      Json(SetWorkspaceProviderConfigValueRequest {
        value: "   ".to_string(),
      }),
    )
    .await
    .expect("clear workspace provider config should succeed");

    assert_eq!(updated.key, "daytona-target");
    assert!(!updated.configured);
    assert_eq!(updated.value, None);
    assert_eq!(updated.source, None);

    let command = persist_rx
      .recv()
      .await
      .expect("workspace provider config clear should enqueue persistence");
    assert!(matches!(
      command,
      PersistCommand::SetConfig { ref key, ref value }
        if key == "daytona_target" && value.is_empty()
    ));
  }
}
