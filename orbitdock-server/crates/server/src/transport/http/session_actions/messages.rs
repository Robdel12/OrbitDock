use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};

use super::super::{dispatch_error_response, messaging_dispatch_error_response, ApiErrorResponse};
use super::common::{
  accepted_response, flush_persistence, load_session_detail_snapshot, next_http_message_id,
  SendMessageResponse, SendSessionMessageRequest, SessionShellCommandRequest, SteerTurnRequest,
  SteerTurnResponse,
};
use crate::runtime::{
  message_dispatch::{dispatch_send_message, dispatch_session_shell_command, dispatch_steer_turn},
  session_registry::SessionRegistry,
};

pub async fn post_session_message(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SendSessionMessageRequest>,
) -> Result<(StatusCode, Json<SendMessageResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  if body.content.is_empty()
    && body.images.is_empty()
    && body.mentions.is_empty()
    && body.skills.is_empty()
  {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_request",
        error: "Provide content, images, mentions, or skills to send a turn".to_string(),
      }),
    ));
  }

  let message_id = next_http_message_id("user-http");

  let user_row = dispatch_send_message(
    &state,
    crate::runtime::message_dispatch::DispatchSendMessage {
      session_id: session_id.clone(),
      content: body.content,
      model: body.model,
      effort: body.effort,
      skills: body.skills,
      images: body.images,
      mentions: body.mentions,
      message_id,
    },
  )
  .await
  .map_err(|error| messaging_dispatch_error_response(error, &session_id))?;

  flush_persistence(&state).await;
  let session_detail_snapshot = Some(load_session_detail_snapshot(&state, &session_id).await?);

  Ok((
    StatusCode::ACCEPTED,
    Json(SendMessageResponse {
      accepted: true,
      row: user_row,
      session_detail_snapshot,
    }),
  ))
}

pub async fn post_session_shell_command(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SessionShellCommandRequest>,
) -> Result<(StatusCode, Json<super::common::AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)>
{
  let command = body.command.trim();
  if command.is_empty() {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_request",
        error: "Provide a non-empty session shell command".to_string(),
      }),
    ));
  }

  dispatch_session_shell_command(&state, &session_id, command.to_string())
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;

  Ok((
    StatusCode::ACCEPTED,
    accepted_response(&state, &session_id).await?,
  ))
}

pub async fn post_steer_turn(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SteerTurnRequest>,
) -> Result<(StatusCode, Json<SteerTurnResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  if body.content.is_empty() && body.images.is_empty() && body.mentions.is_empty() {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_request",
        error: "Provide content, images, or mentions to steer the active turn".to_string(),
      }),
    ));
  }

  let message_id = next_http_message_id("steer-http");

  let steer_row = dispatch_steer_turn(
    &state,
    session_id.clone(),
    body.content,
    body.images,
    body.mentions,
    body.expected_turn_id,
    message_id,
  )
  .await
  .map_err(|error| messaging_dispatch_error_response(error, &session_id))?;

  flush_persistence(&state).await;
  let session_detail_snapshot = Some(load_session_detail_snapshot(&state, &session_id).await?);

  Ok((
    StatusCode::ACCEPTED,
    Json(SteerTurnResponse {
      accepted: true,
      row: steer_row,
      session_detail_snapshot,
    }),
  ))
}
