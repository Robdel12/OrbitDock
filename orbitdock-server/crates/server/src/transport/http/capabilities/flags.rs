use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_connector_claude::session::ClaudeAction;

use crate::{
  runtime::session_registry::SessionRegistry,
  transport::http::{
    connector_actions::dispatch_claude_action, AcceptedResponse, ApiErrorResponse,
  },
};

use super::{common::accepted_without_detail, ApplyFlagSettingsRequest};

pub async fn apply_flag_settings(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<ApplyFlagSettingsRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  dispatch_claude_action(
    &state,
    &session_id,
    ClaudeAction::ApplyFlagSettings {
      settings: body.settings,
    },
  )
  .await?;

  Ok(accepted_without_detail())
}
