use std::collections::HashSet;

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};

use crate::support::session_time::chrono_now;

use super::{execute_command, PersistCommand, SyncEnvelope};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceSyncTarget {
  pub workspace_id: String,
  pub mission_id: Option<String>,
  pub acked_through: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceSyncApplyResult {
  pub acked_through: u64,
  pub touched_mission_ids: Vec<String>,
}

pub(crate) fn resolve_workspace_sync_target(
  conn: &Connection,
  token_id: &str,
) -> Result<Option<WorkspaceSyncTarget>> {
  conn
    .query_row(
      "SELECT w.id, mi.mission_id, w.sync_acked_through
         FROM workspaces w
         LEFT JOIN mission_issues mi ON mi.id = w.mission_issue_id
         WHERE w.sync_token = ?1",
      params![token_id],
      |row| {
        Ok(WorkspaceSyncTarget {
          workspace_id: row.get(0)?,
          mission_id: row.get(1)?,
          acked_through: row.get::<_, i64>(2)? as u64,
        })
      },
    )
    .optional()
    .context("resolve workspace sync target")
}

pub(crate) fn update_workspace_heartbeat(conn: &Connection, workspace_id: &str) -> Result<()> {
  conn
    .execute(
      "UPDATE workspaces
         SET last_heartbeat_at = ?2
         WHERE id = ?1",
      params![workspace_id, chrono_now()],
    )
    .with_context(|| format!("update workspace heartbeat for {workspace_id}"))?;
  Ok(())
}

pub(crate) fn apply_workspace_sync_batch(
  conn: &mut Connection,
  target: &WorkspaceSyncTarget,
  envelopes: &[SyncEnvelope],
) -> Result<WorkspaceSyncApplyResult> {
  let tx = conn
    .unchecked_transaction()
    .context("begin workspace sync transaction")?;
  let current_acked = current_workspace_acked_through(&tx, &target.workspace_id)?;

  if envelopes.is_empty() {
    update_workspace_sync_state(&tx, &target.workspace_id, current_acked)?;
    tx.commit()
      .context("commit workspace heartbeat transaction")?;
    return Ok(WorkspaceSyncApplyResult {
      acked_through: current_acked,
      touched_mission_ids: target.mission_id.clone().into_iter().collect(),
    });
  }

  validate_sync_batch(target, current_acked, envelopes)?;

  let filtered: Vec<&SyncEnvelope> = envelopes
    .iter()
    .filter(|envelope| envelope.sequence > current_acked)
    .collect();

  if filtered.is_empty() {
    update_workspace_sync_state(&tx, &target.workspace_id, current_acked)?;
    tx.commit()
      .context("commit workspace replay-ack transaction")?;
    return Ok(WorkspaceSyncApplyResult {
      acked_through: current_acked,
      touched_mission_ids: target.mission_id.clone().into_iter().collect(),
    });
  }

  let mut touched_mission_ids: HashSet<String> = target.mission_id.clone().into_iter().collect();

  for envelope in &filtered {
    tx.execute(
      "INSERT INTO sync_log (workspace_id, sequence, command_json)
             VALUES (?1, ?2, ?3)",
      params![
        target.workspace_id,
        envelope.sequence as i64,
        serde_json::to_string(&envelope.command).context("serialize sync command for audit log")?,
      ],
    )
    .with_context(|| {
      format!(
        "insert sync log for workspace {} sequence {}",
        target.workspace_id, envelope.sequence
      )
    })?;

    let command: PersistCommand = envelope.command.clone().into();
    execute_command(&tx, command).with_context(|| {
      format!(
        "replay sync command for workspace {} sequence {}",
        target.workspace_id, envelope.sequence
      )
    })?;

    collect_touched_missions(&tx, &envelope.command, &mut touched_mission_ids).with_context(
      || {
        format!(
          "collect mission ids for workspace {} sequence {}",
          target.workspace_id, envelope.sequence
        )
      },
    )?;
  }

  let acked_through = filtered
    .last()
    .map(|envelope| envelope.sequence)
    .unwrap_or(current_acked);

  tx.execute(
    "UPDATE workspaces
         SET sync_acked_through = ?2,
             last_heartbeat_at = ?3
         WHERE id = ?1",
    params![target.workspace_id, acked_through as i64, chrono_now()],
  )
  .with_context(|| {
    format!(
      "update sync ack state for workspace {}",
      target.workspace_id
    )
  })?;

  tx.commit().context("commit workspace sync transaction")?;

  let mut touched_mission_ids: Vec<String> = touched_mission_ids.into_iter().collect();
  touched_mission_ids.sort();

  Ok(WorkspaceSyncApplyResult {
    acked_through,
    touched_mission_ids,
  })
}

fn current_workspace_acked_through(conn: &Connection, workspace_id: &str) -> Result<u64> {
  conn
    .query_row(
      "SELECT sync_acked_through FROM workspaces WHERE id = ?1",
      params![workspace_id],
      |row| row.get::<_, i64>(0),
    )
    .with_context(|| format!("load current acked_through for workspace {workspace_id}"))
    .map(|value| value as u64)
}

fn update_workspace_sync_state(
  conn: &Connection,
  workspace_id: &str,
  acked_through: u64,
) -> Result<()> {
  conn
    .execute(
      "UPDATE workspaces
         SET sync_acked_through = ?2,
             last_heartbeat_at = ?3
         WHERE id = ?1",
      params![workspace_id, acked_through as i64, chrono_now()],
    )
    .with_context(|| format!("update sync state for workspace {workspace_id}"))?;
  Ok(())
}

fn validate_sync_batch(
  target: &WorkspaceSyncTarget,
  current_acked: u64,
  envelopes: &[SyncEnvelope],
) -> Result<()> {
  let mut previous_sequence = None;
  for envelope in envelopes {
    if envelope.workspace_id != target.workspace_id {
      anyhow::bail!(
        "workspace mismatch: expected {}, got {}",
        target.workspace_id,
        envelope.workspace_id
      );
    }

    if let Some(previous) = previous_sequence {
      if envelope.sequence != previous + 1 {
        anyhow::bail!(
          "non-contiguous sequence: expected {}, got {}",
          previous + 1,
          envelope.sequence
        );
      }
    }
    previous_sequence = Some(envelope.sequence);
  }

  let first_sequence = envelopes
    .first()
    .map(|envelope| envelope.sequence)
    .unwrap_or(current_acked);
  let expected_next = current_acked + 1;

  if first_sequence > expected_next {
    anyhow::bail!(
      "sequence gap: expected {}, got {}",
      expected_next,
      first_sequence
    );
  }

  if first_sequence <= current_acked {
    let all_acked = envelopes
      .iter()
      .all(|envelope| envelope.sequence <= current_acked);
    if !all_acked {
      anyhow::bail!(
        "batch overlaps already-acked sequence {} and must restart at {}",
        current_acked,
        expected_next
      );
    }
  }

  Ok(())
}

fn collect_touched_missions(
  conn: &Connection,
  command: &crate::infrastructure::persistence::SyncCommand,
  touched: &mut HashSet<String>,
) -> Result<()> {
  match command {
    crate::infrastructure::persistence::SyncCommand::SessionCreate(params) => {
      if let Some(mission_id) = &params.mission_id {
        touched.insert(mission_id.clone());
      }
    }
    crate::infrastructure::persistence::SyncCommand::MissionIssueUpsert { mission_id, .. }
    | crate::infrastructure::persistence::SyncCommand::MissionIssueUpdateState {
      mission_id, ..
    }
    | crate::infrastructure::persistence::SyncCommand::MissionIssueSetPrUrl {
      mission_id, ..
    } => {
      touched.insert(mission_id.clone());
    }
    crate::infrastructure::persistence::SyncCommand::SessionUpdate { id, .. }
    | crate::infrastructure::persistence::SyncCommand::SessionEnd { id, .. }
    | crate::infrastructure::persistence::SyncCommand::SetThreadId { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::SetClaudeSdkSessionId {
      session_id: id,
      ..
    }
    | crate::infrastructure::persistence::SyncCommand::SetCustomName { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::SetSummary { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::SetSessionConfig {
      session_id: id, ..
    }
    | crate::infrastructure::persistence::SyncCommand::MarkSessionRead { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::ReactivateSession { id }
    | crate::infrastructure::persistence::SyncCommand::TokensUpdate { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::TurnStateUpdate { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::TurnDiffInsert { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::RowAppend { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::RowUpsert { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::ToolCountIncrement { session_id: id }
    | crate::infrastructure::persistence::SyncCommand::ModelUpdate { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::EffortUpdate { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::UpsertSubagent { session_id: id, .. }
    | crate::infrastructure::persistence::SyncCommand::UpsertSubagents { session_id: id, .. } => {
      if let Some(mission_id) = mission_id_for_session(conn, id)? {
        touched.insert(mission_id);
      }
    }
    _ => {}
  }

  Ok(())
}

fn mission_id_for_session(conn: &Connection, session_id: &str) -> Result<Option<String>> {
  conn
    .query_row(
      "SELECT mission_id
         FROM sessions
         WHERE id = ?1
           AND mission_id IS NOT NULL
           AND mission_id != ''",
      params![session_id],
      |row| row.get(0),
    )
    .optional()
    .with_context(|| format!("load mission_id for session {session_id}"))
}

#[cfg(test)]
mod tests {
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
}
