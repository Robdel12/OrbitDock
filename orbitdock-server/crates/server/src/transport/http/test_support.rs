use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::mpsc;

use crate::infrastructure::persistence::{flush_batch_for_test, PersistCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};

pub(crate) fn new_test_state(is_primary: bool) -> Arc<SessionRegistry> {
  new_test_session_registry(is_primary)
}

pub(crate) fn ensure_test_db() -> PathBuf {
  ensure_server_test_data_dir();
  let db_path = crate::infrastructure::paths::db_path();
  let _ = std::fs::remove_file(&db_path);
  let _ = std::fs::remove_file(db_path.with_extension("db-wal"));
  let _ = std::fs::remove_file(db_path.with_extension("db-shm"));
  let mut conn = rusqlite::Connection::open(&db_path).expect("open test db");
  crate::infrastructure::migration_runner::run_migrations(&mut conn).expect("run test migrations");
  db_path
}

pub(crate) async fn new_persist_test_state(
  is_primary: bool,
) -> (
  Arc<SessionRegistry>,
  mpsc::Receiver<PersistCommand>,
  PathBuf,
  tokio::sync::MutexGuard<'static, ()>,
) {
  let guard = crate::support::test_support::test_env_lock().lock().await;
  let db_path = ensure_test_db();
  let (persist_tx, persist_rx) = mpsc::channel(32);
  (
    Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary)),
    persist_rx,
    db_path,
    guard,
  )
}

pub(crate) async fn flush_next_persist_command(
  persist_rx: &mut mpsc::Receiver<PersistCommand>,
  db_path: &PathBuf,
) {
  let command = persist_rx
    .recv()
    .await
    .expect("endpoint should enqueue a persistence command");
  flush_batch_for_test(db_path, vec![command]).expect("flush persisted command");
}
