use std::convert::TryFrom;
use std::sync::Arc;

use axum::{http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use super::super::{session_load_error, ApiErrorResponse};
use crate::{
  infrastructure::persistence::PersistCommand,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
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

pub(super) fn next_http_message_id(prefix: &str) -> String {
  format!("{prefix}-{}", orbitdock_protocol::new_id())
}

pub(super) async fn flush_persistence(state: &Arc<SessionRegistry>) {
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

pub(super) async fn load_session_detail_snapshot(
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

pub(super) async fn accepted_response(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  flush_persistence(state).await;
  Ok(Json(AcceptedResponse {
    accepted: true,
    session_detail_snapshot: Some(load_session_detail_snapshot(state, session_id).await?),
  }))
}

pub(super) fn direct_connector_available(session: &orbitdock_protocol::SessionState) -> bool {
  session.control_mode == SessionControlMode::Direct
    && session.connector_attached
    && session.lifecycle_state != orbitdock_protocol::SessionLifecycleState::Ended
}

pub fn session_controls_for_state(
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
