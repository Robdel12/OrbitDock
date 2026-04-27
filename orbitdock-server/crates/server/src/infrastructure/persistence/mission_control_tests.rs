use super::*;
use crate::infrastructure::migration_runner::run_migrations;

fn setup_test_db() -> Connection {
  let mut conn = Connection::open_in_memory().unwrap();
  run_migrations(&mut conn).unwrap();
  conn
}

fn insert_mission(conn: &Connection, id: &str, name: &str, created_at: &str) {
  conn
    .execute(
      "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused, created_at, updated_at)
             VALUES (?1, ?2, '/tmp/repo', 'linear', 'claude', 1, 0, ?3, ?3)",
      params![id, name, created_at],
    )
    .unwrap();
}

fn insert_issue(
  conn: &Connection,
  id: &str,
  mission_id: &str,
  issue_id: &str,
  orchestration_state: &str,
  created_at: &str,
) {
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?6)",
      params![
        id,
        mission_id,
        issue_id,
        format!("ISSUE-{issue_id}"),
        orchestration_state,
        created_at,
      ],
    )
    .unwrap();
}

fn insert_session(
  conn: &Connection,
  id: &str,
  project_path: &str,
  worktree_id: Option<&str>,
  created_at: &str,
) {
  conn
    .execute(
      "INSERT INTO sessions (
                id, project_path, project_name, status, work_status, provider,
                approval_policy, sandbox_mode, permission_mode, collaboration_mode,
                multi_agent, personality, service_tier, started_at, last_activity_at,
                worktree_id, is_worktree
             ) VALUES (
                ?1, ?2, 'repo', 'ended', 'ended', 'codex',
                'never', 'workspace-write', 'default', 'single',
                0, 'balanced', 'default', ?3, ?3,
                ?4, 1
             )",
      params![id, project_path, created_at, worktree_id],
    )
    .unwrap();
}

fn insert_worktree(
  conn: &Connection,
  id: &str,
  worktree_path: &str,
  status: &str,
  created_at: &str,
) {
  conn
    .execute(
      "INSERT INTO worktrees (
                id, repo_root, worktree_path, branch, base_branch, status,
                created_by, created_at
             ) VALUES (
                ?1, '/tmp/repo', ?2, 'mission/issue-1', 'main', ?3,
                'agent', ?4
             )",
      params![id, worktree_path, status, created_at],
    )
    .unwrap();
}

#[test]
fn load_missions_returns_descending_created_at_order() {
  let conn = setup_test_db();
  insert_mission(&conn, "m-old", "Old", "2026-01-01T00:00:00.000Z");
  insert_mission(&conn, "m-mid", "Mid", "2026-02-01T00:00:00.000Z");
  insert_mission(&conn, "m-new", "New", "2026-03-01T00:00:00.000Z");

  let missions = load_missions(&conn).unwrap();
  let ids: Vec<&str> = missions.iter().map(|m| m.id.as_str()).collect();
  assert_eq!(ids, vec!["m-new", "m-mid", "m-old"]);
}

#[test]
fn load_missions_returns_empty_for_no_rows() {
  let conn = setup_test_db();
  let missions = load_missions(&conn).unwrap();
  assert!(missions.is_empty());
}

#[test]
fn load_missions_with_counts_aggregates_issue_states() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "Mission One", "2026-03-01T00:00:00.000Z");

  insert_issue(
    &conn,
    "i1",
    "m1",
    "iss-1",
    "running",
    "2026-03-01T00:01:00.000Z",
  );
  insert_issue(
    &conn,
    "i2",
    "m1",
    "iss-2",
    "claimed",
    "2026-03-01T00:02:00.000Z",
  );
  insert_issue(
    &conn,
    "i3",
    "m1",
    "iss-3",
    "queued",
    "2026-03-01T00:03:00.000Z",
  );
  insert_issue(
    &conn,
    "i4",
    "m1",
    "iss-4",
    "retry_queued",
    "2026-03-01T00:04:00.000Z",
  );
  insert_issue(
    &conn,
    "i5",
    "m1",
    "iss-5",
    "completed",
    "2026-03-01T00:05:00.000Z",
  );
  insert_issue(
    &conn,
    "i6",
    "m1",
    "iss-6",
    "failed",
    "2026-03-01T00:06:00.000Z",
  );

  let results = load_missions_with_counts(&conn).unwrap();
  assert_eq!(results.len(), 1);

  let (mission, (active, queued, completed, failed)) = &results[0];
  assert_eq!(mission.id, "m1");
  assert_eq!(*active, 2);
  assert_eq!(*queued, 2);
  assert_eq!(*completed, 1);
  assert_eq!(*failed, 1);
}

#[test]
fn load_missions_with_counts_returns_zeros_when_no_issues() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "Empty", "2026-03-01T00:00:00.000Z");

  let results = load_missions_with_counts(&conn).unwrap();
  assert_eq!(results.len(), 1);
  let (_, (active, queued, completed, failed)) = &results[0];
  assert_eq!((*active, *queued, *completed, *failed), (0, 0, 0, 0));
}

#[test]
fn load_mission_by_id_returns_matching_row() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "Found", "2026-03-01T00:00:00.000Z");

  let row = load_mission_by_id(&conn, "m1").unwrap();
  assert!(row.is_some());
  assert_eq!(row.unwrap().name, "Found");
}

#[test]
fn load_mission_by_id_returns_none_for_missing() {
  let conn = setup_test_db();
  let row = load_mission_by_id(&conn, "nonexistent").unwrap();
  assert!(row.is_none());
}

#[test]
fn load_mission_issues_returns_only_matching_mission() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");
  insert_mission(&conn, "m2", "Two", "2026-03-01T00:00:00.000Z");

  insert_issue(
    &conn,
    "i1",
    "m1",
    "iss-1",
    "queued",
    "2026-03-01T00:01:00.000Z",
  );
  insert_issue(
    &conn,
    "i2",
    "m1",
    "iss-2",
    "running",
    "2026-03-01T00:02:00.000Z",
  );
  insert_issue(
    &conn,
    "i3",
    "m2",
    "iss-3",
    "queued",
    "2026-03-01T00:03:00.000Z",
  );

  let issues = load_mission_issues(&conn, "m1").unwrap();
  assert_eq!(issues.len(), 2);
  let issue_ids: Vec<&str> = issues.iter().map(|i| i.issue_id.as_str()).collect();
  assert_eq!(issue_ids, vec!["iss-1", "iss-2"]);
}

#[test]
fn load_mission_issues_returns_ascending_created_at() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

  insert_issue(
    &conn,
    "i-late",
    "m1",
    "iss-2",
    "queued",
    "2026-03-02T00:00:00.000Z",
  );
  insert_issue(
    &conn,
    "i-early",
    "m1",
    "iss-1",
    "queued",
    "2026-03-01T00:00:00.000Z",
  );

  let issues = load_mission_issues(&conn, "m1").unwrap();
  let issue_ids: Vec<&str> = issues.iter().map(|i| i.issue_id.as_str()).collect();
  assert_eq!(issue_ids, vec!["iss-1", "iss-2"]);
}

#[test]
fn load_mission_cleanup_candidates_returns_terminal_issue_worktrees() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

  insert_worktree(
    &conn,
    "wt-completed",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-1",
    "active",
    "2026-03-01T00:00:00.000Z",
  );
  insert_session(
    &conn,
    "sess-completed",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-1",
    Some("wt-completed"),
    "2026-03-01T00:00:00.000Z",
  );
  conn
    .execute(
      "INSERT INTO mission_issues (
                id, mission_id, issue_id, issue_identifier, orchestration_state,
                session_id, attempt, created_at, updated_at
             ) VALUES (
                'i-completed', 'm1', 'iss-1', 'ISSUE-1', 'completed',
                'sess-completed', 0, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z'
             )",
      [],
    )
    .unwrap();

  insert_worktree(
    &conn,
    "wt-running",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-2",
    "active",
    "2026-03-01T00:00:00.000Z",
  );
  insert_session(
    &conn,
    "sess-running",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-2",
    Some("wt-running"),
    "2026-03-01T00:00:00.000Z",
  );
  conn
    .execute(
      "INSERT INTO mission_issues (
                id, mission_id, issue_id, issue_identifier, orchestration_state,
                session_id, attempt, created_at, updated_at
             ) VALUES (
                'i-running', 'm1', 'iss-2', 'ISSUE-2', 'running',
                'sess-running', 0, '2026-03-01T00:01:00.000Z', '2026-03-01T00:01:00.000Z'
             )",
      [],
    )
    .unwrap();

  insert_worktree(
    &conn,
    "wt-removed",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-3",
    "removed",
    "2026-03-01T00:00:00.000Z",
  );
  insert_session(
    &conn,
    "sess-removed",
    "/tmp/repo/.orbitdock-worktrees/mission/issue-3",
    Some("wt-removed"),
    "2026-03-01T00:00:00.000Z",
  );
  conn
    .execute(
      "INSERT INTO mission_issues (
                id, mission_id, issue_id, issue_identifier, orchestration_state,
                session_id, attempt, created_at, updated_at
             ) VALUES (
                'i-removed', 'm1', 'iss-3', 'ISSUE-3', 'completed',
                'sess-removed', 0, '2026-03-01T00:02:00.000Z', '2026-03-01T00:02:00.000Z'
             )",
      [],
    )
    .unwrap();

  let candidates = load_mission_cleanup_candidates(&conn, "m1").unwrap();
  assert_eq!(
    candidates,
    vec![MissionCleanupCandidateRow {
      worktree_id: "wt-completed".into(),
      worktree_path: "/tmp/repo/.orbitdock-worktrees/mission/issue-1".into(),
    }]
  );
}

#[test]
fn load_retry_ready_issues_only_returns_eligible_rows() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i1', 'm1', 'iss-1', 'ISSUE-1', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i2', 'm1', 'iss-2', 'ISSUE-2', 'retry_queued', 1, '2099-01-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i3', 'm1', 'iss-3', 'ISSUE-3', 'queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i4', 'm1', 'iss-4', 'ISSUE-4', 'retry_queued', 5, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, created_at, updated_at)
             VALUES ('i5', 'm1', 'iss-5', 'ISSUE-5', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();

  let now = "2026-03-15T00:00:00.000Z";
  let max_retries = 3;

  let ready = load_retry_ready_issues(&conn, "m1", now, max_retries).unwrap();
  assert_eq!(ready.len(), 1);
  assert_eq!(ready[0].issue_id, "iss-1");
}

#[test]
fn load_retry_ready_issues_orders_by_retry_due_at_asc() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i-later', 'm1', 'iss-2', 'ISSUE-2', 'retry_queued', 1, '2026-03-02T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i-earlier', 'm1', 'iss-1', 'ISSUE-1', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
      [],
    )
    .unwrap();

  let ready = load_retry_ready_issues(&conn, "m1", "2026-03-15T00:00:00.000Z", 3).unwrap();
  let issue_ids: Vec<&str> = ready.iter().map(|i| i.issue_id.as_str()).collect();
  assert_eq!(issue_ids, vec!["iss-1", "iss-2"]);
}

#[test]
fn update_state_sync_changes_orchestration_state() {
  let conn = setup_test_db();
  insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");
  insert_issue(
    &conn,
    "i1",
    "m1",
    "iss-1",
    "queued",
    "2026-03-01T00:00:00.000Z",
  );

  update_mission_issue_state_sync(
    &conn,
    "m1",
    "iss-1",
    &MissionIssueStateUpdate {
      orchestration_state: "running",
      session_id: Some("session-abc"),
      workspace_id: None,
      attempt: Some(1),
      last_error: None,
      started_at: Some(Some("2026-03-01T01:00:00.000Z")),
      completed_at: None,
    },
  )
  .unwrap();

  let row: (String, Option<String>, u32, Option<String>) = conn
    .query_row(
      "SELECT orchestration_state, session_id, attempt, started_at FROM mission_issues WHERE issue_id = 'iss-1'",
      [],
      |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )
    .unwrap();

  assert_eq!(row.0, "running");
  assert_eq!(row.1.as_deref(), Some("session-abc"));
  assert_eq!(row.2, 1);
  assert_eq!(row.3.as_deref(), Some("2026-03-01T01:00:00.000Z"));
}
