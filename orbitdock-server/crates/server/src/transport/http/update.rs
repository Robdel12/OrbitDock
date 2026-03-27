use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::infrastructure::github_releases::types::UpdateChannel;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

/// GET /api/server/update-status — returns the cached update check result (no network call).
pub async fn get_update_status(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<Option<orbitdock_protocol::UpdateStatus>> {
  Json(state.update_status())
}

#[derive(Serialize)]
pub struct CheckUpdateResponse {
  #[serde(flatten)]
  status: Option<orbitdock_protocol::UpdateStatus>,
  #[serde(skip_serializing_if = "Option::is_none")]
  error: Option<String>,
}

/// POST /api/server/check-update — triggers a fresh check (5-min debounce).
/// Returns the check result or an error message if the check failed.
pub async fn check_update(
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<CheckUpdateResponse>, (StatusCode, String)> {
  if state.should_recheck_update_manual() {
    if let Err(e) = crate::runtime::background::update_checker::run_update_check(&state, None).await
    {
      return Ok(Json(CheckUpdateResponse {
        status: state.update_status(),
        error: Some(e.to_string()),
      }));
    }
  }

  Ok(Json(CheckUpdateResponse {
    status: state.update_status(),
    error: None,
  }))
}

#[derive(Deserialize)]
pub struct SetUpdateChannelRequest {
  channel: String,
}

/// PUT /api/server/update-channel — sets the channel and triggers a re-check.
/// Passes the new channel directly to the checker to avoid racing the config write.
pub async fn set_update_channel(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetUpdateChannelRequest>,
) -> Result<Json<CheckUpdateResponse>, (StatusCode, String)> {
  let channel: UpdateChannel = body
    .channel
    .parse()
    .map_err(|e: anyhow::Error| (StatusCode::BAD_REQUEST, e.to_string()))?;

  // Persist the channel preference
  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: "update_channel".to_string(),
      value: channel.to_string(),
    })
    .await;

  // Pass channel directly — don't re-read from DB (avoids race with batched writes)
  let error =
    match crate::runtime::background::update_checker::run_update_check(&state, Some(channel)).await
    {
      Ok(()) => None,
      Err(e) => Some(e.to_string()),
    };

  Ok(Json(CheckUpdateResponse {
    status: state.update_status(),
    error,
  }))
}

/// GET /api/server/update-channel — returns the current update channel.
pub async fn get_update_channel() -> Json<serde_json::Value> {
  let channel = UpdateChannel::resolve(None).unwrap_or_default();
  Json(serde_json::json!({ "channel": channel.to_string() }))
}
