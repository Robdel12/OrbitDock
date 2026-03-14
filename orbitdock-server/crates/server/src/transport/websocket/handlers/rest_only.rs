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
