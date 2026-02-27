use tokio::sync::mpsc;

use crate::websocket::{send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;

/// Handles `ClientMessage` variants that have been migrated to REST endpoints.
///
/// Each arm simply returns an error directing the client to the corresponding
/// HTTP endpoint. No shared state is needed — only `client_tx` for the reply.
pub(crate) async fn handle(msg: ClientMessage, client_tx: &mpsc::Sender<OutboundMessage>) {
    match msg {
        // ── Filesystem / browsing ─────────────────────────────────
        ClientMessage::BrowseDirectory { .. } => {
            send_rest_only_error(client_tx, "GET /api/fs/browse", None).await;
        }
        ClientMessage::ListRecentProjects { .. } => {
            send_rest_only_error(client_tx, "GET /api/fs/recent-projects", None).await;
        }

        // ── Config reads ──────────────────────────────────────────
        ClientMessage::CheckOpenAiKey { .. } => {
            send_rest_only_error(client_tx, "GET /api/server/openai-key", None).await;
        }
        ClientMessage::ListModels => {
            send_rest_only_error(client_tx, "GET /api/models/codex", None).await;
        }
        ClientMessage::ListClaudeModels => {
            send_rest_only_error(client_tx, "GET /api/models/claude", None).await;
        }

        // ── Usage ─────────────────────────────────────────────────
        ClientMessage::FetchCodexUsage { .. } => {
            send_rest_only_error(client_tx, "GET /api/usage/codex", None).await;
        }
        ClientMessage::FetchClaudeUsage { .. } => {
            send_rest_only_error(client_tx, "GET /api/usage/claude", None).await;
        }

        // ── Config mutations ──────────────────────────────────────
        ClientMessage::SetOpenAiKey { .. } => {
            send_rest_only_error(client_tx, "POST /api/server/openai-key", None).await;
        }
        ClientMessage::SetServerRole { .. } => {
            send_rest_only_error(client_tx, "PUT /api/server/role", None).await;
        }

        // ── Worktree management ───────────────────────────────────
        ClientMessage::ListWorktrees {
            request_id: _,
            repo_root,
        } => {
            send_rest_only_error(client_tx, "GET /api/worktrees?repo_root=...", repo_root).await;
        }
        ClientMessage::CreateWorktree { .. } => {
            send_rest_only_error(client_tx, "POST /api/worktrees", None).await;
        }
        ClientMessage::RemoveWorktree { .. } => {
            send_rest_only_error(client_tx, "DELETE /api/worktrees/{worktree_id}", None).await;
        }
        ClientMessage::DiscoverWorktrees { .. } => {
            send_rest_only_error(client_tx, "POST /api/worktrees/discover", None).await;
        }

        // ── Review comments ───────────────────────────────────────
        ClientMessage::ListReviewComments { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/review-comments",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::CreateReviewComment { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "POST /api/sessions/{session_id}/review-comments",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::UpdateReviewComment { comment_id, .. } => {
            send_rest_only_error(
                client_tx,
                "PATCH /api/review-comments/{comment_id}",
                Some(comment_id),
            )
            .await;
        }
        ClientMessage::DeleteReviewComment { comment_id } => {
            send_rest_only_error(
                client_tx,
                "DELETE /api/review-comments/{comment_id}",
                Some(comment_id),
            )
            .await;
        }

        // ── Codex account ─────────────────────────────────────────
        ClientMessage::CodexAccountRead { .. } => {
            send_rest_only_error(client_tx, "GET /api/codex/account", None).await;
        }
        ClientMessage::CodexLoginChatgptStart => {
            send_rest_only_error(client_tx, "POST /api/codex/login/start", None).await;
        }
        ClientMessage::CodexLoginChatgptCancel { .. } => {
            send_rest_only_error(client_tx, "POST /api/codex/login/cancel", None).await;
        }
        ClientMessage::CodexAccountLogout => {
            send_rest_only_error(client_tx, "POST /api/codex/logout", None).await;
        }

        // ── Skills / MCP ──────────────────────────────────────────
        ClientMessage::ListSkills { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/skills",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::ListRemoteSkills { session_id } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/skills/remote",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::DownloadRemoteSkill { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "POST /api/sessions/{session_id}/skills/download",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::ListMcpTools { session_id } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/mcp/tools",
                Some(session_id),
            )
            .await;
        }
        ClientMessage::RefreshMcpServers { session_id } => {
            send_rest_only_error(
                client_tx,
                "POST /api/sessions/{session_id}/mcp/refresh",
                Some(session_id),
            )
            .await;
        }

        _ => {
            tracing::warn!(?msg, "rest_only::handle called with unexpected variant");
        }
    }
}
