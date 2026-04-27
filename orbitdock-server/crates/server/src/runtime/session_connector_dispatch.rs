use std::sync::Arc;

use orbitdock_connector_core::{
  ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent, ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::{Provider, StateChanges};

use crate::domain::sessions::session::SessionHandle;
use crate::runtime::session_registry::SessionRegistry;

#[derive(Debug, Clone)]
pub(crate) enum ConnectorDispatch {
  State(Box<ConnectorStateEvent>),
  RuntimeDirective(ConnectorRuntimeDirective),
  TransportEffect(ConnectorTransportEffect),
}

pub(crate) fn classify_connector_output(output: ConnectorOutput) -> ConnectorDispatch {
  match output {
    ConnectorOutput::State(event) => ConnectorDispatch::State(event),
    ConnectorOutput::Runtime(directive) => ConnectorDispatch::RuntimeDirective(directive),
    ConnectorOutput::Transport(effect) => ConnectorDispatch::TransportEffect(effect),
  }
}

pub(crate) async fn handle_connector_transport_effect(
  effect: ConnectorTransportEffect,
  state: &Arc<SessionRegistry>,
  session_id: &str,
) {
  let tool_pty = state.tool_pty_service();
  match effect {
    ConnectorTransportEffect::ToolPtyCreated { tool_id } => {
      tool_pty.create_for_tool(tool_id, session_id.to_string());
    }
    ConnectorTransportEffect::ToolPtyOutput { tool_id, bytes } => {
      tool_pty.feed_output(&tool_id, &bytes);
    }
    ConnectorTransportEffect::ToolPtyExited { tool_id, exit_code } => {
      tool_pty.finish(&tool_id, exit_code);
    }
  }
}

pub(crate) fn should_suppress_connector_user_echo(
  handle: &SessionHandle,
  event: &ConnectorStateEvent,
) -> bool {
  if handle.provider() != Provider::Codex
    || handle.to_snapshot().codex_integration_mode
      != Some(orbitdock_protocol::CodexIntegrationMode::Direct)
  {
    return false;
  }

  let ConnectorStateEvent::ConversationRowCreated(entry) = event else {
    return false;
  };

  let ConversationRow::User(message) = &entry.row else {
    return false;
  };

  handle.has_user_row_with_content(&message.content)
}

pub(crate) fn upgrade_connector_row_event(
  provider: Provider,
  event: ConnectorStateEvent,
) -> ConnectorStateEvent {
  match event {
    ConnectorStateEvent::ConversationRowCreated(mut entry) => {
      entry.row = crate::domain::conversation_semantics::upgrade_row(provider, entry.row);
      ConnectorStateEvent::ConversationRowCreated(entry)
    }
    ConnectorStateEvent::ConversationRowUpdated { row_id, mut entry } => {
      entry.row = crate::domain::conversation_semantics::upgrade_row(provider, entry.row);
      ConnectorStateEvent::ConversationRowUpdated { row_id, entry }
    }
    other => other,
  }
}

pub(crate) fn include_derived_affordances_for_state_delta(
  changes: &mut StateChanges,
  handle: &SessionHandle,
) {
  if changes.status.is_none()
    && changes.work_status.is_none()
    && changes.control_mode.is_none()
    && changes.lifecycle_state.is_none()
  {
    return;
  }

  let snapshot = handle.to_snapshot();
  let retained = handle.retained_state();
  changes.steerable = Some(snapshot.steerable);
  changes.accepts_user_input = Some(retained.accepts_user_input);
}
