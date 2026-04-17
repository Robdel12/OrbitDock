use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use serde::Deserialize;

use super::super::errors::ApiErrorResponse;
use super::super::AcceptedResponse;
use super::common::{accepted_response, flush_persistence, map_session_mutation_error};
use crate::runtime::session_mutations::{
  end_session as end_runtime_session, rename_session as rename_runtime_session,
  set_summary as set_runtime_summary, update_session_config as update_runtime_session_config,
  SessionConfigUpdate,
};
use crate::runtime::session_queries::{load_full_session_state, SessionLoadError};
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::{
  CodexApprovalPolicy, CodexApprovalsReviewer, CodexConfigMode, CodexSandboxPolicy,
  SessionDetailSnapshot,
};

#[derive(Debug, Deserialize)]
pub struct RenameSessionRequest {
  #[serde(default)]
  pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateSessionConfigRequest {
  #[serde(default)]
  pub approval_policy: Option<Option<String>>,
  #[serde(default)]
  pub approval_policy_details: Option<Option<CodexApprovalPolicy>>,
  #[serde(default)]
  pub sandbox_mode: Option<Option<String>>,
  #[serde(default)]
  pub sandbox_policy_details: Option<Option<CodexSandboxPolicy>>,
  #[serde(default)]
  pub approvals_reviewer: Option<Option<CodexApprovalsReviewer>>,
  #[serde(default)]
  pub permission_mode: Option<Option<String>>,
  #[serde(default)]
  pub collaboration_mode: Option<Option<String>>,
  #[serde(default)]
  pub multi_agent: Option<Option<bool>>,
  #[serde(default)]
  pub personality: Option<Option<String>>,
  #[serde(default)]
  pub service_tier: Option<Option<String>>,
  #[serde(default)]
  pub developer_instructions: Option<Option<String>>,
  #[serde(default)]
  pub model: Option<Option<String>>,
  #[serde(default)]
  pub effort: Option<Option<String>>,
  #[serde(default)]
  pub codex_config_mode: Option<Option<CodexConfigMode>>,
  #[serde(default)]
  pub codex_config_profile: Option<Option<String>>,
  #[serde(default)]
  pub codex_model_provider: Option<Option<String>>,
}

impl UpdateSessionConfigRequest {
  fn into_session_config_update(self) -> SessionConfigUpdate {
    SessionConfigUpdate {
      approval_policy: self.approval_policy,
      approval_policy_details: self.approval_policy_details,
      sandbox_mode: self.sandbox_mode,
      sandbox_policy_details: self.sandbox_policy_details,
      approvals_reviewer: self.approvals_reviewer,
      permission_mode: self.permission_mode,
      collaboration_mode: self.collaboration_mode,
      multi_agent: self.multi_agent,
      personality: self.personality,
      service_tier: self.service_tier,
      developer_instructions: self.developer_instructions,
      model: self.model,
      effort: self.effort,
      codex_config_mode: self.codex_config_mode,
      codex_config_profile: self.codex_config_profile,
      codex_model_provider: self.codex_model_provider,
    }
  }
}

#[derive(Debug, Deserialize)]
pub struct SetSummaryRequest {
  pub summary: String,
}

pub async fn rename_session(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RenameSessionRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  rename_runtime_session(&state, &session_id, body.name)
    .await
    .map_err(map_session_mutation_error)?;

  Ok(accepted_response(&state, &session_id).await)
}

pub async fn set_summary(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetSummaryRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  set_runtime_summary(&state, &session_id, body.summary)
    .await
    .map_err(map_session_mutation_error)?;

  Ok(accepted_response(&state, &session_id).await)
}

pub async fn update_session_config(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<UpdateSessionConfigRequest>,
) -> Result<Json<SessionDetailSnapshot>, (StatusCode, Json<ApiErrorResponse>)> {
  update_runtime_session_config(&state, &session_id, body.into_session_config_update())
    .await
    .map_err(map_session_mutation_error)?;

  flush_persistence(&state).await;

  match load_full_session_state(&state, &session_id, false, false).await {
    Ok(session) => Ok(Json(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    })),
    Err(SessionLoadError::NotFound) => Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    )),
    Err(SessionLoadError::Db(err)) => Err((
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "db_error",
        error: err,
      }),
    )),
    Err(SessionLoadError::Runtime(err)) => Err((
      StatusCode::SERVICE_UNAVAILABLE,
      Json(ApiErrorResponse {
        code: "runtime_error",
        error: err,
      }),
    )),
  }
}

pub async fn end_session(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  end_runtime_session(&state, &session_id).await;

  Ok(accepted_response(&state, &session_id).await)
}
