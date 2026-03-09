use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::debug;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::OutboundMessage;

use super::message_groups::{classify_client_message, MessageGroup};

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

        match classify_client_message(&msg) {
            MessageGroup::Subscribe => {
                crate::transport::websocket::handlers::subscribe::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::SessionCrud => {
                crate::transport::websocket::handlers::session_crud::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::SessionLifecycle => {
                crate::transport::websocket::handlers::session_lifecycle::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::Messaging => {
                crate::transport::websocket::handlers::messaging::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::Approvals => {
                crate::transport::websocket::handlers::approvals::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::Config => {
                crate::transport::websocket::handlers::config::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::ClaudeHooks => {
                crate::transport::websocket::handlers::claude_hooks::handle(msg, client_tx, state)
                    .await;
            }

            MessageGroup::Shell => {
                crate::transport::websocket::handlers::shell::handle(
                    msg, client_tx, state, conn_id,
                )
                .await;
            }

            MessageGroup::RestOnly => {
                crate::transport::websocket::handlers::rest_only::handle(msg, client_tx).await;
            }
        }
    })
}
