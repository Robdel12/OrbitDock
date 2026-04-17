use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use tracing::info;

use crate::{
  infrastructure::persistence::PersistCommand, runtime::session_registry::SessionRegistry,
  transport::http::errors::bad_request, transport::http::ApiResult,
};

use super::{
  SetWorkspaceProviderConfigValueRequest, SetWorkspaceProviderRequest, WorkspaceProviderConfigKey,
  WorkspaceProviderConfigResponse, WorkspaceProviderConfigValueResponse,
  WorkspaceProviderTestResponse,
};

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
  let key = parse_config_key(&key)?;
  Ok(Json(read_workspace_provider_config_value(key)))
}

pub async fn set_workspace_provider_config_value(
  State(state): State<Arc<SessionRegistry>>,
  Path(key): Path<String>,
  Json(body): Json<SetWorkspaceProviderConfigValueRequest>,
) -> ApiResult<WorkspaceProviderConfigValueResponse> {
  let key = parse_config_key(&key)?;
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
    orbitdock_protocol::WorkspaceProviderKind::Local => {
      "local mission workspace provider is ready".to_string()
    }
    orbitdock_protocol::WorkspaceProviderKind::Daytona => {
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

fn parse_config_key(
  key: &str,
) -> Result<
  WorkspaceProviderConfigKey,
  (
    axum::http::StatusCode,
    Json<crate::transport::http::ApiErrorResponse>,
  ),
> {
  WorkspaceProviderConfigKey::parse(key).ok_or_else(|| {
    bad_request(
      "invalid_workspace_provider_config_key",
      format!("Unknown mission provider config key: {key}"),
    )
  })
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
  let env_value = std::env::var(key.env_var()).ok().and_then(|value| {
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
      None
    } else {
      Some(trimmed)
    }
  });
  let source = if env_value.is_some() {
    Some("env".to_string())
  } else if persisted_value.is_some() {
    Some("settings".to_string())
  } else {
    None
  };
  let effective_value = env_value.or(persisted_value);

  WorkspaceProviderConfigValueResponse {
    key: key.key().to_string(),
    value: if key.is_secret() {
      None
    } else {
      effective_value.clone()
    },
    configured: effective_value.is_some(),
    secret: key.is_secret(),
    source,
  }
}
