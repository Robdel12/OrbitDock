use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;

use crate::infrastructure::github_releases::types::UpdateChannel;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

/// GET /api/server/update-status — returns the cached update check result (no network call).
pub async fn get_update_status(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<Option<orbitdock_protocol::UpdateStatus>> {
  Json(state.update_status())
}

/// POST /api/server/check-update — triggers a fresh check (5-min debounce).
pub async fn check_update(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<Option<orbitdock_protocol::UpdateStatus>> {
  if state.should_recheck_update_manual() {
    crate::runtime::background::update_checker::run_update_check(&state).await;
  }

  Json(state.update_status())
}

#[derive(Deserialize)]
pub struct SetUpdateChannelRequest {
  channel: String,
}

/// PUT /api/server/update-channel — sets the channel and triggers a re-check.
pub async fn set_update_channel(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetUpdateChannelRequest>,
) -> Result<Json<orbitdock_protocol::UpdateStatus>, (StatusCode, String)> {
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

  // Run a fresh check with the new channel
  crate::runtime::background::update_checker::run_update_check(&state).await;

  Ok(Json(state.update_status().unwrap_or(
    orbitdock_protocol::UpdateStatus {
      update_available: false,
      latest_version: None,
      release_url: None,
      channel: channel.to_string(),
      checked_at: Some(chrono::Utc::now().to_rfc3339()),
    },
  )))
}

/// GET /api/server/update-channel — returns the current update channel.
pub async fn get_update_channel() -> Json<serde_json::Value> {
  let channel = crate::infrastructure::persistence::load_config_value("update_channel")
    .and_then(|v: String| v.parse::<UpdateChannel>().ok())
    .unwrap_or_default();
  Json(serde_json::json!({ "channel": channel.to_string() }))
}
