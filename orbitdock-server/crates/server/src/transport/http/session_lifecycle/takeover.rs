use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use serde::{Deserialize, Serialize};

use super::super::errors::ApiErrorResponse;
use super::common::{flush_persistence, load_session_detail_snapshot, map_takeover_error};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_takeover::{takeover_passive_session, TakeoverSessionInputs};
use orbitdock_protocol::SessionDetailSnapshot;

#[derive(Debug, Deserialize)]
pub struct TakeoverSessionRequest {
  #[serde(default)]
  pub model: Option<String>,
  #[serde(default)]
  pub approval_policy: Option<String>,
  #[serde(default)]
  pub sandbox_mode: Option<String>,
  #[serde(default)]
  pub permission_mode: Option<String>,
  #[serde(default)]
  pub collaboration_mode: Option<String>,
  #[serde(default)]
  pub multi_agent: Option<bool>,
  #[serde(default)]
  pub personality: Option<String>,
  #[serde(default)]
  pub service_tier: Option<String>,
  #[serde(default)]
  pub developer_instructions: Option<String>,
  #[serde(default)]
  pub allowed_tools: Vec<String>,
  #[serde(default)]
  pub disallowed_tools: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct TakeoverSessionResponse {
  pub session_id: String,
  pub accepted: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<SessionDetailSnapshot>,
}

pub async fn takeover_session(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<TakeoverSessionRequest>,
) -> Result<Json<TakeoverSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  takeover_passive_session(
    &state,
    &session_id,
    TakeoverSessionInputs {
      model: body.model,
      approval_policy: body.approval_policy,
      sandbox_mode: body.sandbox_mode,
      permission_mode: body.permission_mode,
      collaboration_mode: body.collaboration_mode,
      multi_agent: body.multi_agent,
      personality: body.personality,
      service_tier: body.service_tier,
      developer_instructions: body.developer_instructions,
      allowed_tools: body.allowed_tools,
      disallowed_tools: body.disallowed_tools,
    },
  )
  .await
  .map_err(map_takeover_error)?;

  flush_persistence(&state).await;

  Ok(Json(TakeoverSessionResponse {
    session_id: session_id.clone(),
    accepted: true,
    session_detail_snapshot: Some(load_session_detail_snapshot(&state, &session_id).await?),
  }))
}
