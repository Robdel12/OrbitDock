use std::sync::Arc;

use tokio::sync::mpsc;

use crate::runtime::session_registry::SessionRegistry;
use crate::support::test_support::ensure_server_test_data_dir;
use crate::transport::websocket::OutboundMessage;
use orbitdock_protocol::ServerMessage;

#[allow(dead_code)]
pub(crate) fn ensure_test_data_dir() {
    ensure_server_test_data_dir();
}

#[allow(dead_code)]
pub(crate) fn new_test_state() -> Arc<SessionRegistry> {
    ensure_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(128);
    Arc::new(SessionRegistry::new(persist_tx))
}

#[allow(dead_code)]
pub(crate) async fn recv_json(client_rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
    match client_rx.recv().await.expect("expected outbound message") {
        OutboundMessage::Json(message) => message,
        OutboundMessage::Raw(_) => panic!("expected JSON message, got raw payload"),
        OutboundMessage::Pong(_) => panic!("expected JSON message, got pong"),
    }
}
