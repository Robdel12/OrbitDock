use std::sync::Arc;

use tokio::sync::mpsc;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::OutboundMessage;
use orbitdock_protocol::ClientMessage;

/// Handles Claude Code hook events forwarded over WebSocket.
///
/// All supported variants delegate directly to `hook_handler::handle_hook_message`,
/// which processes the event against the session registry.
pub(crate) async fn handle(
  msg: ClientMessage,
  _client_tx: &mpsc::Sender<OutboundMessage>,
  state: &Arc<SessionRegistry>,
) {
  match msg {
    ClientMessage::ClaudeSessionStart { .. }
    | ClientMessage::ClaudeSessionEnd { .. }
    | ClientMessage::ClaudeStatusEvent { .. }
    | ClientMessage::ClaudeToolEvent { .. }
    | ClientMessage::ClaudeSubagentEvent { .. } => {
      crate::connectors::hook_handler::handle_hook_message(msg, state).await;
    }

    _ => {}
  }
}
