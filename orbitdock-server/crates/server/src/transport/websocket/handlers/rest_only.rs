use tokio::sync::mpsc;

use crate::transport::websocket::rest_only_policy::rest_only_route;
use crate::transport::websocket::{send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;

/// Handles `ClientMessage` variants that have been migrated to REST endpoints.
///
/// Each arm simply returns an error directing the client to the corresponding
/// HTTP endpoint. No shared state is needed — only `client_tx` for the reply.
pub(crate) async fn handle(msg: ClientMessage, client_tx: &mpsc::Sender<OutboundMessage>) {
    if let Some(route) = rest_only_route(&msg) {
        send_rest_only_error(client_tx, route.endpoint, route.session_id).await;
    } else {
        tracing::warn!(?msg, "rest_only::handle called with unexpected variant");
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ClientMessage, ServerMessage};
    use tokio::sync::mpsc;

    async fn recv_json(client_rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
        match client_rx.recv().await.expect("expected outbound message") {
            OutboundMessage::Json(message) => message,
            other => panic!("expected JSON outbound message, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn browse_directory_returns_rest_only_error() {
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(4);

        handle(
            ClientMessage::BrowseDirectory {
                path: Some("/tmp".to_string()),
                request_id: "req-1".to_string(),
            },
            &client_tx,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert_eq!(
                    message,
                    "Use REST endpoint GET /api/fs/browse for this request"
                );
                assert_eq!(session_id, None);
            }
            other => panic!("expected rest-only Error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn review_comment_routes_include_authoritative_id() {
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(4);

        handle(
            ClientMessage::UpdateReviewComment {
                comment_id: "comment-1".to_string(),
                body: Some("updated".to_string()),
                tag: None,
                status: None,
            },
            &client_tx,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert_eq!(
                    message,
                    "Use REST endpoint PATCH /api/review-comments/{comment_id} for this request"
                );
                assert_eq!(session_id.as_deref(), Some("comment-1"));
            }
            other => panic!("expected rest-only Error, got {:?}", other),
        }
    }
}
