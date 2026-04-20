use std::sync::Arc;

use axum::{
  body::Bytes,
  extract::{Path, Query, State},
  http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
  response::IntoResponse,
  Json,
};
use serde::{Deserialize, Serialize};

use super::{
  dispatch_error_response, messaging_dispatch_error_response, session_load_error, ApiErrorResponse,
};
use crate::{
  infrastructure::persistence::PersistCommand,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
};
use orbitdock_protocol::{ImageInput, MentionInput, SessionDetailSnapshot, SkillInput};

#[derive(Debug, Serialize)]
pub struct AcceptedResponse {
  pub accepted: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
pub struct SendMessageResponse {
  pub accepted: bool,
  pub row: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
pub struct SteerTurnResponse {
  pub accepted: bool,
  pub row: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
pub struct UploadedImageAttachmentResponse {
  pub image: ImageInput,
}

#[derive(Debug, Deserialize)]
pub struct SendSessionMessageRequest {
  pub content: String,
  #[serde(default)]
  pub model: Option<String>,
  #[serde(default)]
  pub effort: Option<String>,
  #[serde(default)]
  pub skills: Vec<SkillInput>,
  #[serde(default)]
  pub images: Vec<ImageInput>,
  #[serde(default)]
  pub mentions: Vec<MentionInput>,
}

#[derive(Debug, Deserialize)]
pub struct SteerTurnRequest {
  #[serde(default)]
  pub content: String,
  #[serde(default)]
  pub images: Vec<ImageInput>,
  #[serde(default)]
  pub mentions: Vec<MentionInput>,
}

#[derive(Debug, Deserialize, Default)]
pub struct UploadImageAttachmentQuery {
  #[serde(default)]
  pub display_name: Option<String>,
  #[serde(default)]
  pub pixel_width: Option<u32>,
  #[serde(default)]
  pub pixel_height: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct RollbackTurnsRequest {
  pub num_turns: u32,
}

#[derive(Debug, Deserialize)]
pub struct StopTaskRequest {
  pub task_id: String,
}

#[derive(Debug, Deserialize)]
pub struct RewindFilesRequest {
  pub user_message_id: String,
}

fn next_http_message_id(prefix: &str) -> String {
  format!("{prefix}-{}", orbitdock_protocol::new_id())
}

async fn flush_persistence(state: &Arc<SessionRegistry>) {
  let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
  if state
    .persist()
    .send(PersistCommand::Flush { ack: ack_tx })
    .await
    .is_ok()
  {
    let _ = ack_rx.await;
  }
}

async fn load_session_detail_snapshot(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<SessionDetailSnapshot, (StatusCode, Json<ApiErrorResponse>)> {
  match load_full_session_state(state, session_id, false, false).await {
    Ok(session) => Ok(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    }),
    Err(error) => Err(session_load_error(session_id, error)),
  }
}

async fn accepted_response(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  flush_persistence(state).await;
  Ok(Json(AcceptedResponse {
    accepted: true,
    session_detail_snapshot: Some(load_session_detail_snapshot(state, session_id).await?),
  }))
}

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

  let user_row = crate::runtime::message_dispatch::dispatch_send_message(
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

pub async fn upload_session_image_attachment(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<UploadImageAttachmentQuery>,
  headers: HeaderMap,
  body: Bytes,
) -> Result<Json<UploadedImageAttachmentResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  if state.get_session(&session_id).is_none() {
    return Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    ));
  }

  if body.is_empty() {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_request",
        error: "Provide image bytes in the request body".to_string(),
      }),
    ));
  }

  let mime_type = headers
    .get(CONTENT_TYPE)
    .and_then(|value| value.to_str().ok())
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .ok_or_else(|| {
      (
        StatusCode::BAD_REQUEST,
        Json(ApiErrorResponse {
          code: "invalid_request",
          error: "Set the image MIME type in the Content-Type header".to_string(),
        }),
      )
    })?;

  let image = crate::infrastructure::images::store_uploaded_attachment(
    &session_id,
    body.as_ref(),
    mime_type,
    query.display_name.as_deref(),
    query.pixel_width,
    query.pixel_height,
  )
  .map_err(|error| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "attachment_store_failed",
        error,
      }),
    )
  })?;

  Ok(Json(UploadedImageAttachmentResponse { image }))
}

pub async fn get_session_image_attachment(
  Path((session_id, attachment_id)): Path<(String, String)>,
) -> Result<impl IntoResponse, (StatusCode, Json<ApiErrorResponse>)> {
  let (bytes, mime_type) = crate::infrastructure::images::read_attachment_bytes(
    &session_id,
    &attachment_id,
  )
  .map_err(|error| {
    let status = if error.contains("invalid attachment id") || error.contains("read attachment") {
      StatusCode::NOT_FOUND
    } else {
      StatusCode::INTERNAL_SERVER_ERROR
    };
    (
      status,
      Json(ApiErrorResponse {
        code: "attachment_read_failed",
        error,
      }),
    )
  })?;

  Ok(([(CONTENT_TYPE, mime_type)], bytes))
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

  let steer_row = crate::runtime::message_dispatch::dispatch_steer_turn(
    &state,
    session_id.clone(),
    body.content,
    body.images,
    body.mentions,
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

pub async fn interrupt_session(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_interrupt(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn compact_context(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_compact(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn undo_last_turn(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_undo(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn rollback_turns(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RollbackTurnsRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  if body.num_turns < 1 {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_argument",
        error: "num_turns must be >= 1".to_string(),
      }),
    ));
  }
  crate::runtime::message_dispatch::dispatch_rollback(&state, &session_id, body.num_turns)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn stop_task(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<StopTaskRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_stop_task(&state, &session_id, body.task_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn rewind_files(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RewindFilesRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_rewind_files(
    &state,
    &session_id,
    body.user_message_id,
  )
  .await
  .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}
