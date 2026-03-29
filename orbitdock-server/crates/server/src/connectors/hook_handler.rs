use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use orbitdock_protocol::{ClientMessage, Provider};
use tracing::warn;

use crate::runtime::session_registry::SessionRegistry;

/// Shared HTTP POST handler for `/api/hook`.
///
/// The transport stays provider-agnostic at the ingress boundary: validate the
/// message, classify which provider owns it, then dispatch to the
/// provider-specific hook handler.
pub async fn hook_handler(
  State(state): State<Arc<SessionRegistry>>,
  Json(msg): Json<ClientMessage>,
) -> StatusCode {
  if classify_hook_provider(&msg).is_none() {
    return StatusCode::BAD_REQUEST;
  }

  tokio::spawn(async move {
    handle_hook_message(msg, &state).await;
  });

  StatusCode::NO_CONTENT
}

/// Route a supported hook message to the correct provider-specific handler.
pub async fn handle_hook_message(msg: ClientMessage, state: &Arc<SessionRegistry>) {
  match classify_hook_provider(&msg) {
    Some(Provider::Claude) => {
      crate::connectors::claude_hooks::handle_hook_message(msg, state).await
    }
    Some(Provider::Codex) => crate::connectors::codex_hooks::handle_hook_message(msg, state).await,
    None => {
      warn!(
        component = "hook_handler",
        event = "hook.ingress.unsupported_message",
        "Received non-hook message on shared hook ingress"
      );
    }
  }
}

/// Identify which provider owns a hook message.
pub fn classify_hook_provider(msg: &ClientMessage) -> Option<Provider> {
  match msg {
    ClientMessage::ClaudeSessionStart { .. }
    | ClientMessage::ClaudeSessionEnd { .. }
    | ClientMessage::ClaudeStatusEvent { .. }
    | ClientMessage::ClaudeToolEvent { .. }
    | ClientMessage::ClaudeSubagentEvent { .. } => Some(Provider::Claude),
    ClientMessage::CodexSessionStart { .. }
    | ClientMessage::CodexUserPromptSubmit { .. }
    | ClientMessage::CodexStopEvent { .. }
    | ClientMessage::CodexToolEvent { .. } => Some(Provider::Codex),
    _ => None,
  }
}
