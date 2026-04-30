use orbitdock_protocol::RecentProject;
use orbitdock_protocol::{Provider, WorkspaceProviderKind};
use rusqlite::Connection;
use std::fs;
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

fn registry_with_persisted_sessions(
  worktree_rows: &[(&str, &str)],
  session_rows: &[(&str, &str, &str, Option<&str>)],
) -> (TempDir, SessionRegistry) {
  let (temp_dir, registry) = registry_with_worktree_rows(worktree_rows);
  let conn = Connection::open(temp_dir.path().join("orbitdock.sqlite")).expect("open sqlite db");
  conn
    .execute(
      "CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        project_path TEXT NOT NULL,
        last_activity_at TEXT,
        mission_id TEXT,
        is_worktree INTEGER NOT NULL DEFAULT 0
      )",
      [],
    )
    .expect("create sessions table");
  for (session_id, project_path, last_activity_at, mission_id) in session_rows {
    let is_worktree = project_path.contains("/.orbitdock-worktrees/") as i64;
    conn
      .execute(
        "INSERT INTO sessions (id, project_path, last_activity_at, mission_id, is_worktree) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![session_id, project_path, last_activity_at, mission_id, is_worktree],
      )
      .expect("insert session row");
  }

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

#[tokio::test]
async fn list_recent_projects_uses_persisted_session_history() {
  let (_temp_dir, registry) = registry_with_persisted_sessions(
    &[("/repo/.orbitdock-worktrees/removed", "removed")],
    &[
      (
        "old-active-cache",
        "/only-in-db",
        "2026-03-08T08:00:00Z",
        None,
      ),
      ("repo-1", "/repo", "2026-03-08T09:00:00Z", None),
      ("repo-2", "/repo", "2026-03-08T12:00:00Z", None),
      (
        "removed-worktree",
        "/repo/.orbitdock-worktrees/removed",
        "2026-03-08T13:00:00Z",
        None,
      ),
      (
        "mission-session",
        "/repo/.orbitdock-worktrees/mission-123",
        "2026-03-08T14:00:00Z",
        Some("mission-1"),
      ),
    ],
  );

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 2);
  assert_eq!(projects[0].path, "/repo");
  assert_eq!(projects[0].session_count, 2);
  assert_eq!(
    projects[0].last_active.as_deref(),
    Some("2026-03-08T12:00:00Z")
  );
  assert_eq!(projects[1].path, "/only-in-db");
}

#[tokio::test]
async fn list_recent_projects_hides_mission_sessions_from_in_memory_fallback() {
  let (_temp_dir, registry) = registry_with_worktree_rows(&[]);

  let mut mission_session = SessionHandle::new(
    "mission-session".to_string(),
    Provider::Codex,
    "/repo/.orbitdock-worktrees/mission-123".to_string(),
  );
  mission_session.set_last_activity_at(Some("2026-03-08T12:00:00Z".to_string()));
  mission_session.set_mission_context(Some("mission-1".to_string()), Some("ISS-123".to_string()));
  registry.add_session(mission_session);

  let mut normal_session = SessionHandle::new(
    "normal-session".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  normal_session.set_last_activity_at(Some("2026-03-08T11:00:00Z".to_string()));
  normal_session.refresh_snapshot();
  registry.add_session(normal_session);

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 1);
  assert_eq!(projects[0].path, "/repo");
}

#[tokio::test]
async fn list_recent_projects_hides_missing_worktree_paths_from_persisted_history() {
  let temp_dir = tempfile::tempdir().expect("temp dir");
  let repo_path = temp_dir.path().join("repo");
  fs::create_dir_all(&repo_path).expect("create repo dir");
  let repo_path_str = repo_path.to_string_lossy().to_string();
  let missing_worktree_path = repo_path.join(".orbitdock-worktrees/feature-a");
  let missing_worktree_path_str = missing_worktree_path.to_string_lossy().to_string();

  let (_temp_dir, registry) = registry_with_persisted_sessions(
    &[],
    &[
      ("repo-session", &repo_path_str, "2026-03-08T09:00:00Z", None),
      (
        "missing-worktree-session",
        &missing_worktree_path_str,
        "2026-03-08T12:00:00Z",
        None,
      ),
    ],
  );

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 1);
  assert_eq!(projects[0].path, repo_path_str);
}

#[tokio::test]
async fn list_recent_projects_hides_missing_worktree_paths_from_in_memory_fallback() {
  let temp_dir = tempfile::tempdir().expect("temp dir");
  let repo_path = temp_dir.path().join("repo");
  fs::create_dir_all(&repo_path).expect("create repo dir");
  let repo_path_str = repo_path.to_string_lossy().to_string();
  let missing_worktree_path = repo_path.join(".orbitdock-worktrees/feature-a");
  let missing_worktree_path_str = missing_worktree_path.to_string_lossy().to_string();

  let (_registry_dir, registry) = registry_with_worktree_rows(&[]);

  let mut worktree_session = SessionHandle::new(
    "worktree-session".to_string(),
    Provider::Codex,
    missing_worktree_path_str,
  );
  worktree_session.set_last_activity_at(Some("2026-03-08T12:00:00Z".to_string()));
  worktree_session.set_worktree_info(Some(repo_path_str.clone()), true, Some("wt-1".to_string()));
  worktree_session.refresh_snapshot();
  registry.add_session(worktree_session);

  let mut repo_session = SessionHandle::new(
    "repo-session".to_string(),
    Provider::Codex,
    repo_path_str.clone(),
  );
  repo_session.set_last_activity_at(Some("2026-03-08T11:00:00Z".to_string()));
  repo_session.refresh_snapshot();
  registry.add_session(repo_session);

  let projects: Vec<RecentProject> = registry.list_recent_projects().await;

  assert_eq!(projects.len(), 1);
  assert_eq!(projects[0].path, repo_path_str);
}
