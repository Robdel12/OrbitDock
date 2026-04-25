use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use tokio::sync::oneshot;

use crate::{
  connectors::codex_session::CodexAction,
  runtime::session_registry::SessionRegistry,
  transport::http::{
    connector_actions::dispatch_codex_query,
    ApiResult,
  },
};

use super::{
  common::load_session_state, SessionCollaborationMode, SessionCollaborationModesResponse,
};

pub async fn list_collaboration_modes_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionCollaborationModesResponse> {
  let session = load_session_state(&state, &session_id).await?;
  if session.provider != orbitdock_protocol::Provider::Codex {
    return Ok(Json(SessionCollaborationModesResponse { data: Vec::new() }));
  }

  let (reply_tx, reply_rx) = oneshot::channel();
  let response = dispatch_codex_query(
    &state,
    &session_id,
    reply_rx,
    CodexAction::ListCollaborationModes { reply_tx },
  )
  .await?;

  Ok(Json(SessionCollaborationModesResponse {
    data: response
      .data
      .into_iter()
      .map(|mode| SessionCollaborationMode {
        name: mode.name,
        mode: mode.mode.map(|value| match value {
          codex_protocol::config_types::ModeKind::Plan => "plan".to_string(),
          codex_protocol::config_types::ModeKind::Default => "default".to_string(),
          codex_protocol::config_types::ModeKind::PairProgramming => {
            "pair_programming".to_string()
          }
          codex_protocol::config_types::ModeKind::Execute => "execute".to_string(),
        }),
        model: mode.model,
        reasoning_effort: mode
          .reasoning_effort
          .as_ref()
          .and_then(|value| value.as_ref())
          .map(ToString::to_string),
        clears_reasoning_effort: matches!(mode.reasoning_effort, Some(None)),
      })
      .collect(),
  }))
}
