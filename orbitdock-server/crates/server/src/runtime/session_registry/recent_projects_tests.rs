use orbitdock_protocol::RecentProject;
use orbitdock_protocol::{Provider, WorkspaceProviderKind};
use rusqlite::Connection;
use tempfile::TempDir;
use tokio::sync::mpsc;

use crate::domain::sessions::session::SessionHandle;

use crate::runtime::session_registry::SessionRegistry;

fn registry_with_worktree_rows(rows: &[(&str, &str)]) -> (TempDir, SessionRegistry) {
  let temp_dir = tempfile::tempdir().expect("temp dir");
  let db_path = temp_dir.path().join("orbitdock.sqlite");
  let conn = Connection::open(&db_path).expect("open sqlite db");
  conn
    .execute(
      "CREATE TABLE worktrees (worktree_path TEXT NOT NULL, status TEXT NOT NULL)",
      [],
    )
    .expect("create worktrees table");
  for (worktree_path, status) in rows {
    conn
      .execute(
        "INSERT INTO worktrees (worktree_path, status) VALUES (?1, ?2)",
        [worktree_path, status],
      )
      .expect("insert worktree row");
  }

  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary_and_db_path(
    persist_tx,
    db_path,
    true,
    WorkspaceProviderKind::Local,
  );

  (temp_dir, registry)
}

#[tokio::test]
async fn list_recent_projects_hides_removed_worktree_paths() {
  let (_temp_dir, registry) =
    registry_with_worktree_rows(&[("/repo/.orbitdock-worktrees/feature-a", "removed")]);

  for (session_id, path, last_activity_at) in [
    (
      "removed-session",
      "/repo/.orbitdock-worktrees/feature-a",
      "2026-03-08T12:00:00Z",
    ),
    (
      "visible-session-b",
      "/repo/.orbitdock-worktrees/feature-b",
      "2026-03-08T11:00:00Z",
    ),
    ("visible-session-root", "/repo", "2026-03-08T10:00:00Z"),
  ] {
    let mut session = SessionHandle::new(session_id.to_string(), Provider::Codex, path.to_string());
    session.set_last_activity_at(Some(last_activity_at.to_string()));
    session.refresh_snapshot();
    registry.add_session(session);
  }

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 2);
  assert_eq!(projects[0].path, "/repo/.orbitdock-worktrees/feature-b");
  assert_eq!(projects[1].path, "/repo");
}

#[tokio::test]
async fn list_recent_projects_aggregates_counts_and_latest_activity_for_visible_paths() {
  let (_temp_dir, registry) = registry_with_worktree_rows(&[]);

  for (session_id, path, last_activity_at) in [
    ("repo-1", "/repo", "2026-03-08T09:00:00Z"),
    ("other-1", "/other", "2026-03-08T08:00:00Z"),
    ("repo-2", "/repo", "2026-03-08T12:00:00Z"),
  ] {
    let mut session = SessionHandle::new(session_id.to_string(), Provider::Codex, path.to_string());
    session.set_last_activity_at(Some(last_activity_at.to_string()));
    session.refresh_snapshot();
    registry.add_session(session);
  }

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 2);
  assert_eq!(projects[0].path, "/repo");
  assert_eq!(projects[0].session_count, 2);
  assert_eq!(
    projects[0].last_active.as_deref(),
    Some("2026-03-08T12:00:00Z")
  );
  assert_eq!(projects[1].path, "/other");
}
