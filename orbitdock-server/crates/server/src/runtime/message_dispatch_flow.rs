use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::{ImageInput, MentionInput, Provider, SkillInput};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::runtime::message_dispatch::DispatchMessageError;
use crate::runtime::session_registry::SessionRegistry;

pub(super) async fn send_user_message_to_connector(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  codex_tx: Option<mpsc::Sender<CodexAction>>,
  claude_tx: Option<mpsc::Sender<ClaudeAction>>,
  content: String,
  action_model: Option<String>,
  connector_effort: Option<String>,
  skills: Vec<SkillInput>,
  connector_images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
) -> Result<(), DispatchMessageError> {
  if let Some(tx) = codex_tx {
    if tx
      .send(CodexAction::SendMessage {
        content,
        model: action_model,
        effort: connector_effort,
        skills,
        images: connector_images,
        mentions,
      })
      .await
      .is_ok()
    {
      return Ok(());
    }

    crate::runtime::session_runtime_helpers::mark_direct_session_connector_detached(
      state,
      session_id,
      Provider::Codex,
    )
    .await;
    state.remove_codex_action_tx(session_id);
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  if let Some(tx) = claude_tx {
    if tx
      .send(ClaudeAction::SendMessage {
        content,
        model: action_model,
        effort: connector_effort,
        images: connector_images,
      })
      .await
      .is_ok()
    {
      return Ok(());
    }

    crate::runtime::session_runtime_helpers::mark_direct_session_connector_detached(
      state,
      session_id,
      Provider::Claude,
    )
    .await;
    state.remove_claude_action_tx(session_id);
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  Err(DispatchMessageError::ConnectorUnavailable)
}

pub(super) async fn send_steer_turn_to_connector(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  codex_tx: Option<mpsc::Sender<CodexAction>>,
  claude_tx: Option<mpsc::Sender<ClaudeAction>>,
  content: String,
  message_id: String,
  connector_images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
) -> Result<(), DispatchMessageError> {
  if let Some(tx) = codex_tx {
    if tx
      .send(CodexAction::SteerTurn {
        content,
        message_id,
        images: connector_images,
        mentions,
      })
      .await
      .is_ok()
    {
      return Ok(());
    }

    crate::runtime::session_runtime_helpers::mark_direct_session_connector_detached(
      state,
      session_id,
      Provider::Codex,
    )
    .await;
    state.remove_codex_action_tx(session_id);
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  if let Some(tx) = claude_tx {
    if tx
      .send(ClaudeAction::SteerTurn {
        content,
        message_id,
        images: connector_images,
      })
      .await
      .is_ok()
    {
      return Ok(());
    }

    crate::runtime::session_runtime_helpers::mark_direct_session_connector_detached(
      state,
      session_id,
      Provider::Claude,
    )
    .await;
    state.remove_claude_action_tx(session_id);
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  Err(DispatchMessageError::ConnectorUnavailable)
}
