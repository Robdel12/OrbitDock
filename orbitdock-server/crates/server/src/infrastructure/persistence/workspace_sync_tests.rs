use super::*;
use crate::infrastructure::migration_runner::run_migrations;
use crate::infrastructure::persistence::{SyncCommand, SyncSessionCreateParams};
use orbitdock_protocol::{Provider, SessionControlMode};

fn setup_test_db() -> Connection {
  let mut conn = Connection::open_in_memory().unwrap();
  run_migrations(&mut conn).unwrap();
  conn
}

fn insert_workspace(conn: &Connection, id: &str, token_id: &str) {
  conn
    .execute(
      "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused)
             VALUES ('mission-1', 'Mission', '/tmp/repo', 'linear', 'codex', 1, 0)",
      [],
    )
    .unwrap();
  conn.execute(
      "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt)
             VALUES ('mi-1', 'mission-1', 'issue-1', '#1', 'queued', 0)",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO workspaces (id, mission_issue_id, branch, sync_token)
             VALUES (?1, 'mi-1', 'mission/issue-1', ?2)",
      params![id, token_id],
    )
    .unwrap();
}

#[test]
fn resolve_workspace_sync_target_matches_token_id() {
  let conn = setup_test_db();
  insert_workspace(&conn, "workspace-1", "token-1");

  let target = resolve_workspace_sync_target(&conn, "token-1")
    .unwrap()
    .expect("workspace target");

  assert_eq!(target.workspace_id, "workspace-1");
  assert_eq!(target.mission_id.as_deref(), Some("mission-1"));
  assert_eq!(target.acked_through, 0);
}

#[test]
fn apply_workspace_sync_batch_replays_commands_and_updates_ack() {
  let mut conn = setup_test_db();
  insert_workspace(&conn, "workspace-1", "token-1");
  let target = resolve_workspace_sync_target(&conn, "token-1")
    .unwrap()
    .unwrap();

  let batch = vec![SyncEnvelope {
    sequence: 1,
    workspace_id: "workspace-1".into(),
    timestamp: chrono_now(),
    command: SyncCommand::SessionCreate(Box::new(SyncSessionCreateParams {
      id: "session-1".into(),
      provider: Provider::Codex,
      control_mode: SessionControlMode::Direct,
      project_path: "/tmp/repo".into(),
      project_name: Some("repo".into()),
      branch: Some("main".into()),
      model: None,
      approval_policy: None,
      sandbox_mode: None,
      permission_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides_json: None,
      forked_from_session_id: None,
      mission_id: Some("mission-1".into()),
      issue_identifier: Some("#1".into()),
      allow_bypass_permissions: false,
      worktree_id: None,
    })),
  }];

  let result = apply_workspace_sync_batch(&mut conn, &target, &batch).unwrap();
  assert_eq!(result.acked_through, 1);
  assert_eq!(result.touched_mission_ids, vec!["mission-1".to_string()]);

  let acked: i64 = conn
    .query_row(
      "SELECT sync_acked_through FROM workspaces WHERE id = 'workspace-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(acked, 1);

  let log_count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM sync_log WHERE workspace_id = 'workspace-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(log_count, 1);

  let session_count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE id = 'session-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(session_count, 1);
}

#[test]
fn apply_workspace_sync_batch_rejects_sequence_gaps() {
  let mut conn = setup_test_db();
  insert_workspace(&conn, "workspace-1", "token-1");
  let target = resolve_workspace_sync_target(&conn, "token-1")
    .unwrap()
    .unwrap();

  let err = apply_workspace_sync_batch(
    &mut conn,
    &target,
    &[SyncEnvelope {
      sequence: 2,
      workspace_id: "workspace-1".into(),
      timestamp: chrono_now(),
      command: SyncCommand::SetSummary {
        session_id: "session-1".into(),
        summary: "gap".into(),
      },
    }],
  )
  .unwrap_err();

  assert!(err.to_string().contains("sequence gap"));
}

#[test]
fn apply_workspace_sync_batch_accepts_heartbeat_only() {
  let mut conn = setup_test_db();
  insert_workspace(&conn, "workspace-1", "token-1");
  let target = resolve_workspace_sync_target(&conn, "token-1")
    .unwrap()
    .unwrap();

  let result = apply_workspace_sync_batch(&mut conn, &target, &[]).unwrap();
  assert_eq!(result.acked_through, 0);
}

#[test]
fn apply_workspace_sync_batch_marks_mission_issue_commands_as_touched() {
  let mut conn = setup_test_db();
  insert_workspace(&conn, "workspace-1", "token-1");
  let target = resolve_workspace_sync_target(&conn, "token-1")
    .unwrap()
    .unwrap();

  let result = apply_workspace_sync_batch(
    &mut conn,
    &target,
    &[SyncEnvelope {
      sequence: 1,
      workspace_id: "workspace-1".into(),
      timestamp: chrono_now(),
      command: SyncCommand::MissionIssueUpdateState {
        mission_id: "mission-1".into(),
        issue_id: "issue-1".into(),
        orchestration_state: "provisioning".into(),
        session_id: None,
        workspace_id: Some("workspace-1".into()),
        attempt: Some(1),
        last_error: Some(None),
        retry_due_at: None,
        started_at: None,
        completed_at: None,
      },
    }],
  )
  .unwrap();

  assert_eq!(result.touched_mission_ids, vec!["mission-1".to_string()]);
}
