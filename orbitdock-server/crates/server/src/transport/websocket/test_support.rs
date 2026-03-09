use std::sync::{Arc, Once};

use tokio::sync::mpsc;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::OutboundMessage;
use orbitdock_protocol::ServerMessage;

static INIT_TEST_DATA_DIR: Once = Once::new();

pub(crate) fn ensure_test_data_dir() {
    INIT_TEST_DATA_DIR.call_once(|| {
        let dir = std::env::temp_dir().join("orbitdock-server-test-data");
        let _ = std::fs::remove_dir_all(&dir);
        crate::infrastructure::paths::init_data_dir(Some(&dir));
    });
}

pub(crate) fn new_test_state() -> Arc<SessionRegistry> {
    ensure_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(128);
    Arc::new(SessionRegistry::new(persist_tx))
}

pub(crate) async fn recv_json(client_rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
    match client_rx.recv().await.expect("expected outbound message") {
        OutboundMessage::Json(message) => message,
        OutboundMessage::Raw(_) => panic!("expected JSON message, got raw payload"),
        OutboundMessage::Pong(_) => panic!("expected JSON message, got pong"),
    }
}
