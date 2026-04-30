use super::*;

fn setup_test_db() -> (tempfile::TempDir, PathBuf) {
  let dir = tempfile::tempdir().unwrap();
  let db_path = dir.path().join("orbitdock.db");
  let conn = Connection::open(&db_path).unwrap();
  conn
    .execute_batch(
      "CREATE TABLE worktrees (
         id TEXT PRIMARY KEY,
         repo_root TEXT NOT NULL,
         worktree_path TEXT NOT NULL UNIQUE,
         branch TEXT NOT NULL,
         base_branch TEXT,
         status TEXT NOT NULL DEFAULT 'active',
         created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
         last_session_ended_at TEXT,
         last_health_check_at TEXT,
         disk_present INTEGER NOT NULL DEFAULT 1,
         auto_prune INTEGER NOT NULL DEFAULT 1,
         custom_name TEXT,
         created_by TEXT
       );
       CREATE TABLE sessions (
         id TEXT PRIMARY KEY,
         status TEXT NOT NULL DEFAULT 'active',
         lifecycle_state TEXT NOT NULL DEFAULT 'open',
         project_path TEXT NOT NULL DEFAULT '',
         ended_at TEXT,
         worktree_id TEXT
       );",
    )
    .unwrap();
  (dir, db_path)
}

#[test]
fn load_worktree_session_stats_counts_active_and_total_sessions() {
  let (_dir, db_path) = setup_test_db();
  let conn = Connection::open(&db_path).unwrap();
  conn
    .execute(
      "INSERT INTO worktrees (id, repo_root, worktree_path, branch, created_by, last_session_ended_at)
       VALUES ('wt-1', '/tmp/repo', '/tmp/repo/.orbitdock-worktrees/feature-a', 'feature-a', 'user', '2026-03-01T00:00:00Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (id, status, lifecycle_state, project_path, ended_at, worktree_id)
       VALUES ('session-1', 'active', 'open', '/tmp/repo/.orbitdock-worktrees/feature-a', NULL, 'wt-1')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (id, status, lifecycle_state, project_path, ended_at, worktree_id)
       VALUES ('session-2', 'ended', 'ended', '/tmp/repo/.orbitdock-worktrees/feature-a', '2026-04-10T00:00:00Z', 'wt-1')",
      [],
    )
    .unwrap();

  let stats = load_worktree_session_stats(&db_path, Some("/tmp/repo"));
  let entry = stats.get("wt-1").unwrap();

  assert_eq!(entry.active_session_count, 1);
  assert_eq!(entry.total_session_count, 2);
  assert_eq!(
    entry.last_session_ended_at.as_deref(),
    Some("2026-04-10T00:00:00Z")
  );
}
