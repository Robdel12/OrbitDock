use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::{ImageInput, MentionInput, Provider, SkillInput};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::runtime::message_dispatch::DispatchMessageError;
use crate::runtime::session_registry::SessionRegistry;

pub(super) struct UserMessageConnectorRequest {
  pub codex_tx: Option<mpsc::Sender<CodexAction>>,
  pub claude_tx: Option<mpsc::Sender<ClaudeAction>>,
  pub content: String,
  pub action_model: Option<String>,
  pub connector_effort: Option<String>,
  pub skills: Vec<SkillInput>,
  pub connector_images: Vec<ImageInput>,
  pub mentions: Vec<MentionInput>,
}

pub(super) struct SteerTurnConnectorRequest {
  pub codex_tx: Option<mpsc::Sender<CodexAction>>,
  pub claude_tx: Option<mpsc::Sender<ClaudeAction>>,
  pub content: String,
  pub message_id: String,
  pub connector_images: Vec<ImageInput>,
  pub mentions: Vec<MentionInput>,
}

pub(super) async fn send_user_message_to_connector(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  request: UserMessageConnectorRequest,
) -> Result<(), DispatchMessageError> {
  let UserMessageConnectorRequest {
    codex_tx,
    claude_tx,
    content,
    action_model,
    connector_effort,
    skills,
    connector_images,
    mentions,
  } = request;
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
  request: SteerTurnConnectorRequest,
) -> Result<(), DispatchMessageError> {
  let SteerTurnConnectorRequest {
    codex_tx,
    claude_tx,
    content,
    message_id,
    connector_images,
    mentions,
  } = request;
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
      Provider::Claude,
    )
    .await;
    state.remove_claude_action_tx(session_id);
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  Err(DispatchMessageError::ConnectorUnavailable)
}
