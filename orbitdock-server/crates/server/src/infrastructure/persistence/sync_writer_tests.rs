use super::*;
use std::sync::Arc;
use std::time::Duration;

use rusqlite::Connection;
use tempfile::TempDir;
use tokio::sync::watch;

use crate::infrastructure::migration_runner;
use crate::infrastructure::persistence::SyncCommand;
use crate::infrastructure::persistence::{
  acknowledge_sync_outbox, append_sync_outbox_commands, load_pending_sync_envelopes,
};

fn setup_db() -> (TempDir, Connection) {
  let tempdir = TempDir::new().expect("tempdir");
  let db_path = tempdir.path().join("test.db");
  let mut conn = Connection::open(&db_path).expect("open db");
  migration_runner::run_migrations(&mut conn).expect("run migrations");
  conn
    .execute(
      "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused)
             VALUES ('mission-1', 'Mission', '/tmp/repo', 'linear', 'codex', 1, 0)",
      [],
    )
    .expect("insert mission");
  conn.execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt)
             VALUES ('mi-1', 'mission-1', 'issue-1', '#1', 'queued', 0)",
      [],
    )
    .expect("insert mission issue");
  conn
    .execute(
      "INSERT INTO workspaces (id, mission_issue_id, branch, sync_token)
             VALUES ('workspace-1', 'mi-1', 'mission/issue-1', 'token-1')",
      [],
    )
    .expect("insert workspace");
  (tempdir, conn)
}

fn sample_command() -> SyncCommand {
  SyncCommand::ModelUpdate {
    session_id: "session-1".into(),
    model: "gpt-5.4".into(),
  }
}

#[test]
fn append_sync_outbox_assigns_monotonic_sequences() {
  let (_tempdir, conn) = setup_db();
  let tx = conn.unchecked_transaction().expect("tx");

  append_sync_outbox_commands(&tx, "workspace-1", &[sample_command()]).expect("append first");
  append_sync_outbox_commands(&tx, "workspace-1", &[sample_command()]).expect("append second");
  tx.commit().expect("commit");

  let loaded = load_pending_sync_envelopes(&conn, "workspace-1", 10).expect("load outbox");
  assert_eq!(loaded.len(), 2);
  assert_eq!(loaded[0].sequence, 1);
  assert_eq!(loaded[1].sequence, 2);
}

#[test]
fn load_pending_sync_envelopes_reads_outbox_rows_in_order() {
  let (_tempdir, conn) = setup_db();
  let tx = conn.unchecked_transaction().expect("tx");
  append_sync_outbox_commands(&tx, "workspace-1", &[sample_command(), sample_command()])
    .expect("append outbox");
  tx.commit().expect("commit");

  let loaded = load_pending_sync_envelopes(&conn, "workspace-1", 10).expect("load pending");
  assert_eq!(loaded.len(), 2);
  assert_eq!(loaded[0].sequence, 1);
  assert_eq!(loaded[1].sequence, 2);
}

#[tokio::test]
async fn sync_writer_acknowledges_and_deletes_outbox_rows() {
  let (tempdir, conn) = setup_db();
  let tx = conn.unchecked_transaction().expect("tx");
  append_sync_outbox_commands(&tx, "workspace-1", &[sample_command(), sample_command()])
    .expect("append outbox");
  tx.commit().expect("commit");
  drop(conn);

  let state = Arc::new(tokio::sync::Mutex::new(Vec::<SyncBatchRequest>::new()));
  let post_batch_fn: PostBatchFn = Arc::new({
    let state = state.clone();
    move |_config: &SyncWriterConfig, request: SyncBatchRequest| {
      let state = state.clone();
      Box::pin(async move {
        state.lock().await.push(request);
        Ok(())
      })
    }
  });

  let (_shutdown_tx, shutdown_rx) = watch::channel(false);
  let mut writer = SyncWriter::new_with_post_fn(
    shutdown_rx,
    SyncWriterConfig {
      workspace_id: "workspace-1".into(),
      db_path: tempdir.path().join("test.db"),
      server_url: "http://sync.example.test".into(),
      auth_token: "token-1".into(),
      batch_size: 10,
      flush_interval: Duration::from_millis(5),
      heartbeat_interval: Duration::from_millis(5),
    },
    post_batch_fn,
  )
  .expect("writer");

  writer.flush_pending(false).await;

  let conn = Connection::open(tempdir.path().join("test.db")).expect("reopen db");
  let remaining: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM sync_outbox WHERE workspace_id = 'workspace-1'",
      [],
      |row| row.get(0),
    )
    .expect("count outbox");
  assert_eq!(remaining, 0);

  let acked = super::current_sync_acked_through(&conn, "workspace-1").expect("acked");
  assert_eq!(acked, 2);

  let requests = state.lock().await;
  assert_eq!(requests.len(), 1);
  assert_eq!(requests[0].commands.len(), 2);
}

#[test]
fn acknowledge_sync_outbox_updates_ack_state() {
  let (_tempdir, conn) = setup_db();
  acknowledge_sync_outbox(&conn, "workspace-1", 3).expect("ack outbox");

  let acked = super::current_sync_acked_through(&conn, "workspace-1").expect("acked");
  assert_eq!(acked, 3);
}
