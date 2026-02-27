use std::sync::Arc;

use tokio::sync::mpsc;

use crate::state::SessionRegistry;
use crate::websocket::{send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;

/// Handles Claude Code hook events forwarded over WebSocket.
///
/// Most variants delegate directly to `hook_handler::handle_hook_message`,
/// which processes the event against the session registry. The
/// `GetSubagentTools` variant is a REST-only endpoint and returns an error
/// directing the client to the HTTP API.
pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
) {
    match msg {
        ClientMessage::ClaudeSessionStart { .. }
        | ClientMessage::ClaudeSessionEnd { .. }
        | ClientMessage::ClaudeStatusEvent { .. }
        | ClientMessage::ClaudeToolEvent { .. }
        | ClientMessage::ClaudeSubagentEvent { .. } => {
            crate::hook_handler::handle_hook_message(msg, state).await;
        }

        ClientMessage::GetSubagentTools {
            session_id,
            subagent_id,
        } => {
            let _ = subagent_id;
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/subagents/{subagent_id}/tools",
                Some(session_id),
            )
            .await;
        }

        _ => {}
    }
}
