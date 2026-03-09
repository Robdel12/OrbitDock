use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::debug;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::OutboundMessage;

/// Dispatch a single client WebSocket message.
///
/// Each handler group lives in its own module under `ws_handlers/`, so each
/// `.await` site produces an independently-sized future. This keeps the
/// parent future small enough for the default 2 MiB thread stack in debug
/// builds.
pub(crate) fn handle_client_message<'a>(
    msg: ClientMessage,
    client_tx: &'a mpsc::Sender<OutboundMessage>,
    state: &'a Arc<SessionRegistry>,
    conn_id: u64,
) -> Pin<Box<dyn Future<Output = ()> + Send + 'a>> {
    Box::pin(async move {
        debug!(
            component = "websocket",
            event = "ws.message.received",
            connection_id = conn_id,
            message = ?msg,
            "Received client message"
        );

        match msg {
            ClientMessage::SubscribeList
            | ClientMessage::SubscribeSession { .. }
            | ClientMessage::UnsubscribeSession { .. } => {
                crate::transport::websocket::handlers::subscribe::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::CreateSession { .. }
            | ClientMessage::EndSession { .. }
            | ClientMessage::RenameSession { .. }
            | ClientMessage::UpdateSessionConfig { .. }
            | ClientMessage::ForkSession { .. }
            | ClientMessage::ForkSessionToWorktree { .. }
            | ClientMessage::ForkSessionToExistingWorktree { .. } => {
                crate::transport::websocket::handlers::session_crud::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::ResumeSession { .. } | ClientMessage::TakeoverSession { .. } => {
                crate::transport::websocket::handlers::session_lifecycle::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::SendMessage { .. }
            | ClientMessage::SteerTurn { .. }
            | ClientMessage::AnswerQuestion { .. }
            | ClientMessage::InterruptSession { .. }
            | ClientMessage::CompactContext { .. }
            | ClientMessage::UndoLastTurn { .. }
            | ClientMessage::RollbackTurns { .. }
            | ClientMessage::StopTask { .. }
            | ClientMessage::RewindFiles { .. } => {
                crate::transport::websocket::handlers::messaging::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::ApproveTool { .. }
            | ClientMessage::ListApprovals { .. }
            | ClientMessage::DeleteApproval { .. } => {
                crate::transport::websocket::handlers::approvals::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::SetClientPrimaryClaim { .. } => {
                crate::transport::websocket::handlers::config::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. }
            | ClientMessage::GetSubagentTools { .. } => {
                crate::transport::websocket::handlers::claude_hooks::handle(msg, client_tx, state)
                    .await;
            }

            ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => {
                crate::transport::websocket::handlers::shell::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            ClientMessage::BrowseDirectory { .. }
            | ClientMessage::ListRecentProjects { .. }
            | ClientMessage::CheckOpenAiKey { .. }
            | ClientMessage::FetchCodexUsage { .. }
            | ClientMessage::FetchClaudeUsage { .. }
            | ClientMessage::SetServerRole { .. }
            | ClientMessage::SetOpenAiKey { .. }
            | ClientMessage::ListModels
            | ClientMessage::ListClaudeModels
            | ClientMessage::CodexAccountRead { .. }
            | ClientMessage::CodexLoginChatgptStart
            | ClientMessage::CodexLoginChatgptCancel { .. }
            | ClientMessage::CodexAccountLogout
            | ClientMessage::ListSkills { .. }
            | ClientMessage::ListRemoteSkills { .. }
            | ClientMessage::DownloadRemoteSkill { .. }
            | ClientMessage::ListMcpTools { .. }
            | ClientMessage::RefreshMcpServers { .. }
            | ClientMessage::ListWorktrees { .. }
            | ClientMessage::CreateWorktree { .. }
            | ClientMessage::RemoveWorktree { .. }
            | ClientMessage::DiscoverWorktrees { .. }
            | ClientMessage::CreateReviewComment { .. }
            | ClientMessage::UpdateReviewComment { .. }
            | ClientMessage::DeleteReviewComment { .. }
            | ClientMessage::ListReviewComments { .. } => {
                crate::transport::websocket::handlers::rest_only::handle(msg, client_tx).await;
            }
        }
    })
}
