use tokio::sync::mpsc;

use crate::websocket::{send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;

/// Handles `ClientMessage` variants that have been migrated to REST endpoints.
///
/// Each arm simply returns an error directing the client to the corresponding
/// HTTP endpoint. No shared state is needed — only `client_tx` for the reply.
pub(crate) async fn handle(msg: ClientMessage, client_tx: &mpsc::Sender<OutboundMessage>) {
    match msg {
        ClientMessage::BrowseDirectory { .. } => {
            send_rest_only_error(client_tx, "GET /api/fs/browse", None).await;
        }
        ClientMessage::ListRecentProjects { .. } => {
            send_rest_only_error(client_tx, "GET /api/fs/recent-projects", None).await;
        }
        ClientMessage::CheckOpenAiKey { .. } => {
            send_rest_only_error(client_tx, "GET /api/server/openai-key", None).await;
        }
        ClientMessage::FetchCodexUsage { .. } => {
            send_rest_only_error(client_tx, "GET /api/usage/codex", None).await;
        }
        ClientMessage::FetchClaudeUsage { .. } => {
            send_rest_only_error(client_tx, "GET /api/usage/claude", None).await;
        }
        _ => {
            tracing::warn!(?msg, "rest_only::handle called with unexpected variant");
        }
    }
}
