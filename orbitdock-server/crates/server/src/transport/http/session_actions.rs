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
  runtime::{
    session_queries::{load_full_session_state, load_light_session_state},
    session_registry::SessionRegistry,
  },
};
use orbitdock_protocol::{
  ImageInput, MentionInput, Provider, SessionControlMode, SessionDetailSnapshot, SkillInput,
};

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

#[derive(Debug, Deserialize)]
pub struct SessionShellCommandRequest {
  pub command: String,
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

#[derive(Debug, Serialize)]
pub struct SessionControlsResponse {
  pub session_id: String,
  pub provider: Provider,
  pub controls: SessionControlsPayload,
}

#[derive(Debug, Serialize)]
pub struct SessionControlsPayload {
  pub shell_command: SessionControlCapability,
  pub stop_active_turn: SessionControlCapability,
  pub compact_context: SessionControlCapability,
  pub undo_last_turn: SessionControlCapability,
  pub rollback_turns: SessionControlCapability,
  pub stop_target: SessionControlCapability,
  pub rewind_to_message: SessionControlCapability,
}

#[derive(Debug, Serialize, Clone)]
pub struct SessionControlCapability {
  pub supported: bool,
  pub available: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub target_kind: Option<&'static str>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub max_count: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct StopTargetRequest {
  pub target_id: String,
}

#[derive(Debug, Deserialize)]
pub struct RewindToMessageRequest {
  pub message_id: String,
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

fn direct_connector_available(session: &orbitdock_protocol::SessionState) -> bool {
  session.control_mode == SessionControlMode::Direct
    && session.connector_attached
    && session.lifecycle_state != orbitdock_protocol::SessionLifecycleState::Ended
}

fn session_controls_for_state(
  session: &orbitdock_protocol::SessionState,
) -> SessionControlsPayload {
  let provider = session.provider;
  let available = direct_connector_available(session);
  let has_turns = session.turn_count > 0;
  let max_turns = u32::try_from(session.turn_count)
    .ok()
    .filter(|value| *value > 0);

  SessionControlsPayload {
    shell_command: SessionControlCapability {
      supported: provider == Provider::Codex,
      available: available && provider == Provider::Codex,
      target_kind: None,
      max_count: None,
    },
    stop_active_turn: SessionControlCapability {
      supported: matches!(provider, Provider::Claude | Provider::Codex),
      available: available && session.can_interrupt,
      target_kind: None,
      max_count: None,
    },
    compact_context: SessionControlCapability {
      supported: matches!(provider, Provider::Claude | Provider::Codex),
      available,
      target_kind: None,
      max_count: None,
    },
    undo_last_turn: SessionControlCapability {
      supported: matches!(provider, Provider::Claude | Provider::Codex),
      available: available && has_turns,
      target_kind: None,
      max_count: Some(1),
    },
    rollback_turns: SessionControlCapability {
      supported: matches!(provider, Provider::Claude | Provider::Codex),
      available: available && has_turns,
      target_kind: None,
      max_count: max_turns,
    },
    stop_target: SessionControlCapability {
      supported: provider == Provider::Claude,
      available: available && provider == Provider::Claude,
      target_kind: (provider == Provider::Claude).then_some("task"),
      max_count: None,
    },
    rewind_to_message: SessionControlCapability {
      supported: provider == Provider::Claude,
      available: available && provider == Provider::Claude && has_turns,
      target_kind: (provider == Provider::Claude).then_some("user_message"),
      max_count: None,
    },
  }
}

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

pub async fn stop_active_turn(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_stop_active_turn(&state, &session_id)
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

pub async fn post_session_shell_command(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SessionShellCommandRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
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

  crate::runtime::message_dispatch::dispatch_session_shell_command(
    &state,
    &session_id,
    command.to_string(),
  )
  .await
  .map_err(|code| dispatch_error_response(code, &session_id))?;

  flush_persistence(&state).await;
  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse {
      accepted: true,
      session_detail_snapshot: Some(load_session_detail_snapshot(&state, &session_id).await?),
    }),
  ))
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

pub async fn compact_context_control(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_compact_context(&state, &session_id)
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

pub async fn undo_last_turn_control(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_undo_last_turn(&state, &session_id)
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

pub async fn rollback_turns_control(
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
  crate::runtime::message_dispatch::dispatch_rollback_turns(&state, &session_id, body.num_turns)
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

pub async fn stop_target(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<StopTargetRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_stop_target(&state, &session_id, body.target_id)
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

pub async fn rewind_to_message(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<RewindToMessageRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  crate::runtime::message_dispatch::dispatch_rewind_to_message(
    &state,
    &session_id,
    body.message_id,
  )
  .await
  .map_err(|code| dispatch_error_response(code, &session_id))?;
  accepted_response(&state, &session_id).await
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::{
    domain::sessions::session::SessionHandle,
    infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
    transport::http::test_support::new_persist_test_state,
  };
  use axum::{extract::Path, extract::State};
  use tokio::sync::mpsc;

  fn persist_codex_session(
    db_path: &std::path::PathBuf,
    session_id: &str,
    control_mode: SessionControlMode,
  ) {
    flush_batch_for_test(
      db_path,
      vec![PersistCommand::SessionCreate(Box::new(
        SessionCreateParams {
          id: session_id.to_string(),
          provider: Provider::Codex,
          control_mode,
          project_path: "/tmp/orbitdock-controls-test".to_string(),
          project_name: Some("orbitdock-controls-test".to_string()),
          branch: Some("main".to_string()),
          model: Some("gpt-5".to_string()),
          approval_policy: None,
          sandbox_mode: None,
          permission_mode: None,
          collaboration_mode: None,
          multi_agent: None,
          personality: None,
          service_tier: None,
          developer_instructions: None,
          codex_config_mode: None,
          codex_config_profile: None,
          codex_model_provider: None,
          codex_config_source: None,
          codex_config_overrides_json: None,
          forked_from_session_id: None,
          mission_id: None,
          issue_identifier: None,
          allow_bypass_permissions: false,
          worktree_id: None,
        },
      ))],
    )
    .expect("persist codex session fixture");
  }

  fn persist_claude_session(db_path: &std::path::PathBuf, session_id: &str) {
    flush_batch_for_test(
      db_path,
      vec![PersistCommand::ClaudeSessionUpsert {
        id: session_id.to_string(),
        project_path: "/tmp/orbitdock-controls-test".to_string(),
        project_name: Some("orbitdock-controls-test".to_string()),
        branch: Some("main".to_string()),
        model: Some("claude-opus-4-1".to_string()),
        context_label: None,
        transcript_path: Some("/tmp/orbitdock-controls-test/transcript.jsonl".to_string()),
        source: Some("hook".to_string()),
        agent_type: None,
        permission_mode: Some("acceptEdits".to_string()),
        terminal_session_id: None,
        terminal_app: None,
        forked_from_session_id: None,
        repository_root: Some("/tmp/orbitdock-controls-test".to_string()),
        is_worktree: false,
        git_sha: Some("abc123".to_string()),
      }],
    )
    .expect("persist claude session fixture");
  }

  #[tokio::test]
  async fn controls_endpoint_reports_normalized_capabilities_for_codex() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(&db_path, &session_id, SessionControlMode::Direct);
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-controls-test".to_string(),
    ));
    let (action_tx, _action_rx) = mpsc::channel(4);
    state.set_codex_action_tx(&session_id, action_tx);

    let Json(response) = get_session_controls(Path(session_id), State(state))
      .await
      .expect("controls endpoint should succeed");

    assert_eq!(response.provider, Provider::Codex);
    assert!(response.controls.shell_command.supported);
    assert!(!response.controls.shell_command.available);
    assert!(response.controls.stop_active_turn.supported);
    assert!(!response.controls.stop_active_turn.available);
    assert!(response.controls.compact_context.supported);
    assert!(!response.controls.compact_context.available);
    assert!(response.controls.undo_last_turn.supported);
    assert!(!response.controls.undo_last_turn.available);
    assert!(response.controls.rollback_turns.supported);
    assert!(!response.controls.rollback_turns.available);
    assert!(!response.controls.stop_target.supported);
    assert!(!response.controls.rewind_to_message.supported);
  }

  #[tokio::test]
  async fn stop_target_returns_unsupported_for_codex_sessions() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(&db_path, &session_id, SessionControlMode::Direct);
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-controls-test".to_string(),
    ));
    let (action_tx, _action_rx) = mpsc::channel(4);
    state.set_codex_action_tx(&session_id, action_tx);

    let response = stop_target(
      Path(session_id),
      State(state),
      Json(StopTargetRequest {
        target_id: "task-123".to_string(),
      }),
    )
    .await;

    match response {
      Ok(_) => panic!("expected stop_target to fail for codex"),
      Err((status, body)) => {
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.code, "unsupported_control");
      }
    }
  }

  #[tokio::test]
  async fn controls_endpoint_reports_targeted_controls_for_claude() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_claude_session(&db_path, &session_id);
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Claude,
      "/tmp/orbitdock-controls-test".to_string(),
    ));
    let (action_tx, _action_rx) = mpsc::channel(4);
    state.set_claude_action_tx(&session_id, action_tx);

    let Json(response) = get_session_controls(Path(session_id), State(state))
      .await
      .expect("controls endpoint should succeed");

    assert_eq!(response.provider, Provider::Claude);
    assert!(response.controls.stop_target.supported);
    assert_eq!(response.controls.stop_target.target_kind, Some("task"));
    assert!(response.controls.rewind_to_message.supported);
    assert_eq!(
      response.controls.rewind_to_message.target_kind,
      Some("user_message")
    );
    assert!(!response.controls.shell_command.supported);
  }

  #[tokio::test]
  async fn session_shell_command_returns_unsupported_for_claude_sessions() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_claude_session(&db_path, &session_id);
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Claude,
      "/tmp/orbitdock-controls-test".to_string(),
    ));
    let (action_tx, _action_rx) = mpsc::channel(4);
    state.set_claude_action_tx(&session_id, action_tx);

    let response = post_session_shell_command(
      Path(session_id),
      State(state),
      Json(SessionShellCommandRequest {
        command: "git status --short".to_string(),
      }),
    )
    .await;

    match response {
      Ok(_) => panic!("expected session shell command to fail for claude"),
      Err((status, body)) => {
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.code, "unsupported_session_shell");
      }
    }
  }
}
