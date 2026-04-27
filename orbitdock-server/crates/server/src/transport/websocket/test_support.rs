use std::sync::Arc;

use tokio::sync::mpsc;

use crate::runtime::session_registry::SessionRegistry;
use crate::support::test_support::ensure_server_test_data_dir;

#[allow(dead_code)]
pub(crate) fn new_test_state() -> Arc<SessionRegistry> {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(128);
  Arc::new(SessionRegistry::new(persist_tx))
}
