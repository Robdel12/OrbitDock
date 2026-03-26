use std::path::PathBuf;
use std::sync::{Arc, Once, OnceLock};

use orbitdock_protocol::WorkspaceProviderKind;
use tokio::sync::{mpsc, Mutex};

use crate::infrastructure::paths;
use crate::runtime::session_registry::SessionRegistry;

static INIT_TEST_DATA_DIR: Once = Once::new();
#[allow(dead_code)]
static TEST_ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[allow(dead_code)]
pub(crate) fn test_env_lock() -> &'static Mutex<()> {
    TEST_ENV_LOCK.get_or_init(|| Mutex::new(()))
}

pub(crate) fn ensure_server_test_data_dir() {
    let dir = server_test_data_dir();
    INIT_TEST_DATA_DIR.call_once(|| {
        let _ = std::fs::remove_dir_all(&dir);
    });
    std::fs::create_dir_all(&dir).expect("create server test data dir");
    paths::init_data_dir(Some(&dir));
}

pub(crate) fn new_test_session_registry(is_primary: bool) -> Arc<SessionRegistry> {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(128);
    Arc::new(SessionRegistry::new_with_primary_and_db_path(
        persist_tx,
        paths::db_path(),
        is_primary,
        WorkspaceProviderKind::Local,
    ))
}

pub(crate) fn server_test_data_dir() -> PathBuf {
    std::env::temp_dir().join("orbitdock-server-test-data")
}
