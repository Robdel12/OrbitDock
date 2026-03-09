use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use orbitdock_protocol::ClientMessage;

use crate::runtime::session_registry::SessionRegistry;

use super::handler::handle_hook_message;

/// HTTP POST handler for `/api/hook`.
///
/// Accepts a `ClientMessage` JSON body, validates it's one of the 5 Claude hook
/// types, spawns fire-and-forget processing, and returns 204 immediately.
pub async fn hook_handler(
    State(state): State<Arc<SessionRegistry>>,
    Json(msg): Json<ClientMessage>,
) -> StatusCode {
    if !is_claude_hook(&msg) {
        return StatusCode::BAD_REQUEST;
    }

    tokio::spawn(async move {
        handle_hook_message(msg, &state).await;
    });

    StatusCode::NO_CONTENT
}

fn is_claude_hook(msg: &ClientMessage) -> bool {
    matches!(
        msg,
        ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. }
    )
}
