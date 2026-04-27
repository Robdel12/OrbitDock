use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};

use super::super::{dispatch_error_response, session_load_error, ApiErrorResponse};
use super::common::{
  accepted_response, session_controls_for_state, RewindToMessageRequest, RollbackTurnsRequest,
  SessionControlsResponse, StopTargetRequest,
};
use crate::runtime::{
  session_queries::load_light_session_state, session_registry::SessionRegistry,
};

pub async fn get_session_controls(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<SessionControlsResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let session = load_light_session_state(&state, &session_id)
    .await
    .map_err(|error| session_load_error(&session_id, error))?;

  Ok(Json(SessionControlsResponse {
    session_id,
    provider: session.provider,
    controls: session_controls_for_state(&session),
  }))
}

pub async fn stop_active_turn(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_stop_active_turn(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn compact_context_control(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_compact_context(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn undo_last_turn_control(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_undo_last_turn(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn rollback_turns_control(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RollbackTurnsRequest>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  if body.num_turns < 1 {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_argument",
        error: "num_turns must be >= 1".to_string(),
      }),
    ));
  }
  crate::runtime::message_dispatch::dispatch_rollback_turns(&state, &session_id, body.num_turns)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn stop_target(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<StopTargetRequest>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_stop_target(&state, &session_id, body.target_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn rewind_to_message(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RewindToMessageRequest>,
) -> Result<Json<super::common::AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_rewind_to_message(
    &state,
    &session_id,
    body.message_id,
  )
  .await
  .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}
