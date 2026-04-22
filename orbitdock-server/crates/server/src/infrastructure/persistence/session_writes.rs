use rusqlite::{params, Connection, OptionalExtension};

use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
use orbitdock_protocol::{
  Provider, SessionControlMode, SessionLifecycleState, SessionStatus, TokenUsage,
  TokenUsageSnapshotKind, WorkStatus,
};

pub(super) struct SessionUpdateRecord {
  pub id: String,
  pub status: Option<SessionStatus>,
  pub work_status: Option<WorkStatus>,
  pub control_mode: Option<SessionControlMode>,
  pub lifecycle_state: Option<SessionLifecycleState>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
}

pub(super) struct TurnDiffInsertRecord {
  pub session_id: String,
  pub turn_id: String,
  pub turn_seq: u64,
  pub diff: Option<String>,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub context_window: u64,
  pub snapshot_kind: TokenUsageSnapshotKind,
}

pub(super) struct SessionAttentionUpdateRecord {
  pub session_id: String,
  pub attention_reason: Option<Option<String>>,
  pub last_tool: Option<Option<String>>,
  pub last_tool_at: Option<Option<String>>,
  pub pending_tool_name: Option<Option<String>>,
  pub pending_tool_input: Option<Option<String>>,
  pub pending_question: Option<Option<String>>,
}

pub(super) struct SessionConfigRecord {
  pub session_id: String,
  pub approval_policy: Option<Option<String>>,
  pub sandbox_mode: Option<Option<String>>,
  pub permission_mode: Option<Option<String>>,
  pub collaboration_mode: Option<Option<String>>,
  pub multi_agent: Option<Option<bool>>,
  pub personality: Option<Option<String>>,
  pub service_tier: Option<Option<String>>,
  pub developer_instructions: Option<Option<String>>,
  pub model: Option<Option<String>>,
  pub effort: Option<Option<String>>,
  pub codex_config_mode: Option<Option<orbitdock_protocol::CodexConfigMode>>,
  pub codex_config_profile: Option<Option<String>>,
  pub codex_model_provider: Option<Option<String>>,
  pub codex_config_source: Option<Option<orbitdock_protocol::CodexConfigSource>>,
  pub codex_config_overrides_json: Option<Option<String>>,
}

pub(super) fn persist_session_create(
  conn: &Connection,
  params: super::SessionCreateParams,
) -> Result<(), rusqlite::Error> {
  let super::SessionCreateParams {
    id,
    provider,
    project_path,
    project_name,
    branch,
    model,
    approval_policy,
    sandbox_mode,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides_json,
    forked_from_session_id,
    mission_id,
    issue_identifier,
    allow_bypass_permissions,
    worktree_id,
    control_mode,
  } = params;
  let provider_str = match provider {
    Provider::Claude => "claude",
    Provider::Codex => "codex",
  };

  let now = super::chrono_now();
  let codex_integration_mode: Option<&str> = match provider {
    Provider::Codex => Some("direct"),
    Provider::Claude => None,
  };
  let claude_integration_mode: Option<&str> = match provider {
    Provider::Claude => Some("direct"),
    Provider::Codex => None,
  };
  let control_mode = match control_mode {
    SessionControlMode::Direct => "direct",
    SessionControlMode::Passive => "passive",
  };
  let codex_config_source = codex_config_source.map(|source| match source {
    orbitdock_protocol::CodexConfigSource::Orbitdock => "orbitdock",
    orbitdock_protocol::CodexConfigSource::User => "user",
  });
  let codex_config_mode = codex_config_mode.map(|mode| match mode {
    orbitdock_protocol::CodexConfigMode::Inherit => "inherit",
    orbitdock_protocol::CodexConfigMode::Profile => "profile",
    orbitdock_protocol::CodexConfigMode::Custom => "custom",
  });

  conn.execute(
    "INSERT INTO sessions (
                id,
                project_path,
                project_name,
                branch,
                model,
                provider,
                status,
                work_status,
                lifecycle_state,
                control_mode,
                codex_integration_mode,
                claude_integration_mode,
                approval_policy,
                sandbox_mode,
                permission_mode,
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
                codex_config_mode,
                codex_config_profile,
                codex_model_provider,
                codex_config_source,
                codex_config_overrides_json,
                started_at,
                last_activity_at,
                last_progress_at,
                forked_from_session_id,
                mission_id,
                issue_identifier,
                allow_bypass_permissions,
                worktree_id,
                is_worktree
             )
             VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, 'active', 'waiting', 'open',
                ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                ?18, ?19, ?20, ?21, ?22, ?23, ?24, NULL,
                ?25, ?26, ?27, ?28, ?29, ?30
             )
             ON CONFLICT(id) DO UPDATE SET
               project_name = COALESCE(?3, project_name),
               branch = COALESCE(?4, branch),
               model = COALESCE(?5, model),
               control_mode = COALESCE(sessions.control_mode, excluded.control_mode),
               lifecycle_state = COALESCE(sessions.lifecycle_state, excluded.lifecycle_state),
               last_activity_at = ?24",
    params![
      id,
      project_path,
      project_name,
      branch,
      model,
      provider_str,
      control_mode,
      codex_integration_mode,
      claude_integration_mode,
      approval_policy,
      sandbox_mode,
      permission_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      codex_config_mode,
      codex_config_profile,
      codex_model_provider,
      codex_config_source,
      codex_config_overrides_json,
      now.clone(),
      now,
      forked_from_session_id,
      mission_id,
      issue_identifier,
      allow_bypass_permissions,
      worktree_id,
      worktree_id.is_some(),
    ],
  )?;
  Ok(())
}

pub(super) fn persist_session_update(
  conn: &Connection,
  record: SessionUpdateRecord,
) -> Result<(), rusqlite::Error> {
  let SessionUpdateRecord {
    id,
    status,
    work_status,
    control_mode,
    lifecycle_state,
    last_activity_at,
    last_progress_at,
  } = record;
  let status_str = status.map(|s| match s {
    SessionStatus::Active => "active",
    SessionStatus::Ended => "ended",
  });

  let work_status_str = work_status.map(|s| match s {
    WorkStatus::Working => "working",
    WorkStatus::Waiting => "waiting",
    WorkStatus::Permission => "permission",
    WorkStatus::Question => "question",
    WorkStatus::Reply => "reply",
    WorkStatus::Ended => "ended",
  });

  let clears_pending = matches!(
    work_status,
    Some(WorkStatus::Working)
      | Some(WorkStatus::Waiting)
      | Some(WorkStatus::Reply)
      | Some(WorkStatus::Ended)
  );

  let mut updates = Vec::new();
  let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::new();

  if let Some(ref s) = status_str {
    updates.push("status = ?");
    params_vec.push(s);
  }
  if let Some(ref ws) = work_status_str {
    updates.push("work_status = ?");
    params_vec.push(ws);
  }
  if let Some(mode) = control_mode {
    updates.push("control_mode = ?");
    params_vec.push(match mode {
      SessionControlMode::Direct => &"direct",
      SessionControlMode::Passive => &"passive",
    });
  }
  if let Some(lifecycle_state) = lifecycle_state {
    updates.push(match lifecycle_state {
      SessionLifecycleState::Open => "lifecycle_state = 'open'",
      SessionLifecycleState::Resumable => "lifecycle_state = 'resumable'",
      SessionLifecycleState::Ended => "lifecycle_state = 'ended'",
    });
  } else if matches!(status, Some(SessionStatus::Ended))
    || matches!(work_status, Some(WorkStatus::Ended))
  {
    updates.push("lifecycle_state = 'ended'");
  } else {
    updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')");
  }
  if let Some(ref la) = last_activity_at {
    updates.push("last_activity_at = ?");
    params_vec.push(la);
  }
  if let Some(ref lp) = last_progress_at {
    updates.push("last_progress_at = ?");
    params_vec.push(lp);
  }
  if clears_pending {
    updates.push("pending_tool_name = NULL");
    updates.push("pending_tool_input = NULL");
    updates.push("pending_question = NULL");
    updates.push("pending_approval_id = NULL");
    updates.push(
      "attention_reason = CASE \
          WHEN attention_reason IN ('awaitingPermission', 'awaitingQuestion') THEN 'awaitingReply' \
          ELSE attention_reason \
       END",
    );
  }

  if !updates.is_empty() {
    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    params_vec.push(&id);

    conn.execute(&sql, rusqlite::params_from_iter(params_vec))?;
  }

  if clears_pending {
    let now = super::chrono_now();
    conn.execute(
      "UPDATE approval_history
           SET decision = 'abort',
               decided_at = COALESCE(decided_at, ?1)
           WHERE session_id = ?2
             AND decision IS NULL",
      params![now, id],
    )?;
  }

  Ok(())
}

pub(super) fn persist_session_end(
  conn: &Connection,
  id: String,
  reason: String,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "UPDATE sessions SET status = 'ended', work_status = 'ended', lifecycle_state = 'ended', ended_at = ?1, end_reason = ?2, last_activity_at = ?1 WHERE id = ?3",
    params![now, reason, id],
  )?;
  Ok(())
}

pub(super) fn persist_row_append(
  conn: &Connection,
  session_id: String,
  entry: ConversationRowEntry,
  viewer_present: bool,
  assigned_sequence: Option<u64>,
  sequence_tx: Option<tokio::sync::oneshot::Sender<u64>>,
) -> Result<(), rusqlite::Error> {
  let row_id = entry.id().to_string();
  let row_type = super::row_type_str(&entry.row);
  let row_data = serde_json::to_string(&entry.row).unwrap_or_else(|_| "{}".to_string());
  let now = super::chrono_now();

  let content_text = super::extract_row_content(&entry.row);
  let is_user = entry.row.is_user_input();

  conn.execute(
    "INSERT INTO messages (id, session_id, type, timestamp, sequence, row_data, turn_status)
         VALUES (?1, ?2, ?3, ?4, COALESCE(?5,
           (SELECT MAX(sequence) + 1 FROM messages WHERE session_id = ?2), 0),
           ?6, ?7)
         ON CONFLICT(id) DO NOTHING",
    params![
      row_id,
      session_id,
      row_type,
      now.clone(),
      assigned_sequence.map(|sequence| sequence as i64),
      row_data,
      super::turn_status_str(entry.turn_status),
    ],
  )?;

  if let Some(tx) = sequence_tx {
    let db_seq: i64 = conn.query_row(
      "SELECT sequence FROM messages WHERE id = ?1",
      params![row_id],
      |row| row.get(0),
    )?;
    let _ = tx.send(db_seq as u64);
  }

  if matches!(
    &entry.row,
    ConversationRow::User(_) | ConversationRow::Steer(_) | ConversationRow::Assistant(_)
  ) {
    if let Some(content) = &content_text {
      let truncated: String = content.chars().take(200).collect();
      let _ = conn.execute(
        "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
        params![truncated, session_id],
      );
    }
  }

  let _ = conn.execute(
    "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
    params![now, session_id],
  );
  if !is_user {
    let _ = conn.execute(
      "UPDATE sessions SET last_progress_at = ?1 WHERE id = ?2",
      params![now, session_id],
    );
  }

  if !is_user {
    if viewer_present {
      let db_seq: i64 = conn.query_row(
        "SELECT sequence FROM messages WHERE id = ?1",
        params![row_id],
        |row| row.get(0),
      )?;
      let _ = conn.execute(
        "UPDATE sessions SET last_read_sequence = MAX(last_read_sequence, ?1), unread_count = (
                        SELECT COUNT(*) FROM messages
                        WHERE session_id = ?2
                          AND sequence > ?1
                          AND type NOT IN ('user', 'steer')
                    ) WHERE id = ?2",
        params![db_seq, session_id],
      );
    } else {
      let _ = conn.execute(
        "UPDATE sessions SET unread_count = unread_count + 1 WHERE id = ?1",
        params![session_id],
      );
    }
  }

  Ok(())
}

pub(super) fn persist_row_upsert(
  conn: &Connection,
  session_id: String,
  entry: ConversationRowEntry,
  viewer_present: bool,
  assigned_sequence: Option<u64>,
  sequence_tx: Option<tokio::sync::oneshot::Sender<u64>>,
) -> Result<(), rusqlite::Error> {
  let row_id = entry.id().to_string();
  let row_type = super::row_type_str(&entry.row);
  let row_data = serde_json::to_string(&entry.row).unwrap_or_else(|_| "{}".to_string());
  let content_text = super::extract_row_content(&entry.row);
  let is_user = entry.row.is_user_input();
  let now = super::chrono_now();

  conn.execute(
    "INSERT INTO messages (id, session_id, type, timestamp, sequence, row_data, turn_status)
         VALUES (?1, ?2, ?3, ?4, COALESCE(?5,
           (SELECT MAX(sequence) + 1 FROM messages WHERE session_id = ?2), 0),
           ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET
           type = excluded.type,
           row_data = excluded.row_data,
           turn_status = excluded.turn_status",
    params![
      row_id,
      session_id,
      row_type,
      now.clone(),
      assigned_sequence.map(|sequence| sequence as i64),
      row_data,
      super::turn_status_str(entry.turn_status),
    ],
  )?;

  if let Some(tx) = sequence_tx {
    let db_seq: i64 = conn.query_row(
      "SELECT sequence FROM messages WHERE id = ?1",
      params![row_id],
      |row| row.get(0),
    )?;
    let _ = tx.send(db_seq as u64);
  }

  if matches!(
    &entry.row,
    ConversationRow::User(_) | ConversationRow::Steer(_) | ConversationRow::Assistant(_)
  ) {
    if let Some(content) = &content_text {
      let truncated: String = content.chars().take(200).collect();
      let _ = conn.execute(
        "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
        params![truncated, session_id],
      );
    }
  }

  let _ = conn.execute(
    "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
    params![now, session_id],
  );
  if !is_user {
    let _ = conn.execute(
      "UPDATE sessions SET last_progress_at = ?1 WHERE id = ?2",
      params![now, session_id],
    );
  }

  if !is_user && viewer_present {
    let db_seq: i64 = conn.query_row(
      "SELECT sequence FROM messages WHERE id = ?1",
      params![row_id],
      |row| row.get(0),
    )?;
    let _ = conn.execute(
      "UPDATE sessions SET last_read_sequence = MAX(last_read_sequence, ?1), unread_count = (
                    SELECT COUNT(*) FROM messages
                    WHERE session_id = ?2
                      AND sequence > ?1
                      AND type NOT IN ('user', 'steer')
                ) WHERE id = ?2",
      params![db_seq, session_id],
    );
  }

  Ok(())
}

pub(super) fn persist_tokens_update(
  conn: &Connection,
  session_id: String,
  usage: TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET
           input_tokens = ?1,
           output_tokens = ?2,
           cached_tokens = ?3,
           context_window = ?4,
           last_activity_at = ?5
         WHERE id = ?6",
    params![
      usage.input_tokens as i64,
      usage.output_tokens as i64,
      usage.cached_tokens as i64,
      usage.context_window as i64,
      super::chrono_now(),
      session_id,
    ],
  )?;

  super::persist_usage_event(conn, &session_id, &usage, snapshot_kind)?;
  super::upsert_usage_session_state(conn, &session_id, &usage, snapshot_kind)?;
  Ok(())
}

pub(super) fn persist_turn_state_update(
  conn: &Connection,
  session_id: String,
  diff: Option<String>,
  plan: Option<String>,
) -> Result<(), rusqlite::Error> {
  let mut updates = Vec::new();
  let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::new();

  if let Some(ref diff) = diff {
    updates.push("current_diff = ?");
    params_vec.push(diff);
  }
  if let Some(ref plan) = plan {
    updates.push("current_plan = ?");
    params_vec.push(plan);
  }

  if !updates.is_empty() {
    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    params_vec.push(&session_id);

    conn.execute(&sql, rusqlite::params_from_iter(params_vec))?;
  }

  Ok(())
}

pub(super) fn persist_turn_diff_insert(
  conn: &Connection,
  record: TurnDiffInsertRecord,
) -> Result<(), rusqlite::Error> {
  let TurnDiffInsertRecord {
    session_id,
    turn_id,
    turn_seq,
    diff,
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window,
    snapshot_kind,
  } = record;
  if let Some(ref diff_content) = diff {
    conn.execute(
      "INSERT OR REPLACE INTO turn_diffs (session_id, turn_id, diff, input_tokens, output_tokens, cached_tokens, context_window) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      params![session_id, turn_id, diff_content, input_tokens as i64, output_tokens as i64, cached_tokens as i64, context_window as i64],
    )?;

    conn.execute(
      "UPDATE sessions SET current_diff = NULL WHERE id = ?1",
      params![session_id],
    )?;
  }

  let snapshot = super::TurnSnapshotRow {
    session_id: &session_id,
    turn_id: &turn_id,
    turn_seq,
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window,
    snapshot_kind,
  };
  super::upsert_usage_turn_snapshot(conn, &snapshot)?;
  super::recompute_usage_ledger_for_session(conn, &session_id)?;
  Ok(())
}

pub(super) fn persist_set_thread_id(
  conn: &Connection,
  session_id: String,
  thread_id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET codex_thread_id = ? WHERE id = ? AND codex_thread_id IS NULL",
    params![thread_id, session_id],
  )?;
  Ok(())
}

pub(super) fn persist_cleanup_thread_shadow_session(
  conn: &Connection,
  thread_id: String,
  reason: String,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "UPDATE sessions
         SET status = 'ended',
             work_status = 'ended',
             lifecycle_state = 'ended',
             ended_at = COALESCE(ended_at, ?1),
             end_reason = COALESCE(end_reason, ?2),
             attention_reason = 'none',
             pending_tool_name = NULL,
             pending_tool_input = NULL,
             pending_question = NULL,
             pending_approval_id = NULL
         WHERE id = ?3
           AND (codex_integration_mode IS NULL OR codex_integration_mode != 'direct')",
    params![now, reason, thread_id],
  )?;
  Ok(())
}

pub(super) fn persist_set_claude_sdk_session_id(
  conn: &Connection,
  session_id: String,
  claude_sdk_session_id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET claude_sdk_session_id = ? WHERE id = ? AND claude_sdk_session_id IS NULL",
    params![claude_sdk_session_id, session_id],
  )?;
  Ok(())
}

pub(super) fn persist_cleanup_claude_shadow_session(
  conn: &Connection,
  claude_sdk_session_id: String,
  reason: String,
) -> Result<(), rusqlite::Error> {
  let now = super::chrono_now();
  conn.execute(
    "UPDATE sessions
         SET status = 'ended',
             work_status = 'ended',
             lifecycle_state = 'ended',
             ended_at = COALESCE(ended_at, ?1),
             end_reason = COALESCE(end_reason, ?2),
             attention_reason = 'none',
             pending_tool_name = NULL,
             pending_tool_input = NULL,
             pending_question = NULL,
             pending_approval_id = NULL
         WHERE id = ?3
           AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')",
    params![now, reason, claude_sdk_session_id],
  )?;
  Ok(())
}

pub(super) fn persist_set_custom_name(
  conn: &Connection,
  session_id: String,
  custom_name: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET custom_name = ?, last_activity_at = ? WHERE id = ?",
    params![custom_name, super::chrono_now(), session_id],
  )?;
  Ok(())
}

pub(super) fn persist_set_summary(
  conn: &Connection,
  session_id: String,
  summary: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET summary = ?, last_activity_at = ? WHERE id = ?",
    params![summary, super::chrono_now(), session_id],
  )?;
  Ok(())
}

pub(super) fn persist_set_transcript_path(
  conn: &Connection,
  session_id: String,
  transcript_path: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET transcript_path = ?, last_activity_at = ? WHERE id = ?",
    params![transcript_path, super::chrono_now(), session_id],
  )?;
  Ok(())
}

pub(super) fn persist_session_attention_update(
  conn: &Connection,
  record: SessionAttentionUpdateRecord,
) -> Result<(), rusqlite::Error> {
  let SessionAttentionUpdateRecord {
    session_id,
    attention_reason,
    last_tool,
    last_tool_at,
    pending_tool_name,
    pending_tool_input,
    pending_question,
  } = record;
  let mut updates: Vec<String> = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

  if let Some(reason) = attention_reason {
    updates.push("attention_reason = ?".to_string());
    params_vec.push(Box::new(reason));
  }
  if let Some(tool) = last_tool {
    updates.push("last_tool = ?".to_string());
    params_vec.push(Box::new(tool));
  }
  if let Some(last_tool_at) = last_tool_at {
    updates.push("last_tool_at = ?".to_string());
    params_vec.push(Box::new(last_tool_at));
  }
  if let Some(name) = pending_tool_name {
    updates.push("pending_tool_name = ?".to_string());
    params_vec.push(Box::new(name));
  }
  if let Some(input) = pending_tool_input {
    updates.push("pending_tool_input = ?".to_string());
    params_vec.push(Box::new(input));
  }
  if let Some(question) = pending_question {
    updates.push("pending_question = ?".to_string());
    params_vec.push(Box::new(question));
  }

  if !updates.is_empty() {
    updates.push("last_activity_at = ?".to_string());
    params_vec.push(Box::new(super::chrono_now()));

    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    params_vec.push(Box::new(session_id));

    let params_refs: Vec<&dyn rusqlite::ToSql> =
      params_vec.iter().map(|boxed| boxed.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  Ok(())
}

pub(super) fn persist_set_session_config(
  conn: &Connection,
  record: SessionConfigRecord,
) -> Result<(), rusqlite::Error> {
  let SessionConfigRecord {
    session_id,
    approval_policy,
    sandbox_mode,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides_json,
  } = record;
  let codex_config_source = codex_config_source.flatten().map(|source| match source {
    orbitdock_protocol::CodexConfigSource::Orbitdock => "orbitdock",
    orbitdock_protocol::CodexConfigSource::User => "user",
  });
  let codex_config_mode = codex_config_mode.flatten().map(|mode| match mode {
    orbitdock_protocol::CodexConfigMode::Inherit => "inherit",
    orbitdock_protocol::CodexConfigMode::Profile => "profile",
    orbitdock_protocol::CodexConfigMode::Custom => "custom",
  });
  let mut updates: Vec<String> = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

  if let Some(value) = approval_policy.flatten() {
    updates.push("approval_policy = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = sandbox_mode.flatten() {
    updates.push("sandbox_mode = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = permission_mode.flatten() {
    updates.push("permission_mode = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = collaboration_mode.flatten() {
    updates.push("collaboration_mode = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = multi_agent.flatten() {
    updates.push("multi_agent = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = personality.flatten() {
    updates.push("personality = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = service_tier.flatten() {
    updates.push("service_tier = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = developer_instructions.flatten() {
    updates.push("developer_instructions = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = model.flatten() {
    updates.push("model = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = effort.flatten() {
    updates.push("effort = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = codex_config_mode {
    updates.push("codex_config_mode = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = codex_config_profile.flatten() {
    updates.push("codex_config_profile = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = codex_model_provider.flatten() {
    updates.push("codex_model_provider = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = codex_config_source {
    updates.push("codex_config_source = ?".to_string());
    params_vec.push(Box::new(value));
  }
  if let Some(value) = codex_config_overrides_json.flatten() {
    updates.push("codex_config_overrides_json = ?".to_string());
    params_vec.push(Box::new(value));
  }

  if !updates.is_empty() {
    updates.push("last_activity_at = ?".to_string());
    params_vec.push(Box::new(super::chrono_now()));
    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    params_vec.push(Box::new(session_id));
    let params_refs: Vec<&dyn rusqlite::ToSql> =
      params_vec.iter().map(|value| value.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  Ok(())
}

pub(super) fn persist_mark_session_read(
  conn: &Connection,
  session_id: String,
  up_to_sequence: i64,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET last_read_sequence = MAX(last_read_sequence, ?1), unread_count = (
                SELECT COUNT(*) FROM messages
                WHERE session_id = ?2
                  AND sequence > ?1
                  AND type NOT IN ('user', 'steer')
            ) WHERE id = ?2",
    params![up_to_sequence, session_id],
  )?;
  Ok(())
}

pub(super) fn persist_reactivate_session(
  conn: &Connection,
  id: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions
         SET status = 'active',
             work_status = 'waiting',
             lifecycle_state = 'open',
             ended_at = NULL,
             end_reason = NULL
         WHERE id = ?1",
    params![id],
  )?;
  Ok(())
}

pub(super) fn persist_model_update(
  conn: &Connection,
  session_id: String,
  model: String,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET model = ?1 WHERE id = ?2",
    params![model, session_id],
  )?;
  Ok(())
}

pub(super) fn persist_effort_update(
  conn: &Connection,
  session_id: String,
  effort: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE sessions SET effort = ?1 WHERE id = ?2",
    params![effort, session_id],
  )?;
  Ok(())
}

pub(super) fn persist_set_integration_mode(
  conn: &Connection,
  session_id: String,
  codex_mode: Option<String>,
  claude_mode: Option<String>,
) -> Result<(), rusqlite::Error> {
  let mut updates = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
  let control_mode = match (codex_mode.as_deref(), claude_mode.as_deref()) {
    (Some("direct"), _) | (_, Some("direct")) => "direct",
    _ => "passive",
  };

  if let Some(m) = codex_mode {
    updates.push("codex_integration_mode = ?");
    params_vec.push(Box::new(m));
  }
  if let Some(m) = claude_mode {
    updates.push("claude_integration_mode = ?");
    params_vec.push(Box::new(m));
  }

  if !updates.is_empty() {
    updates.push("control_mode = ?");
    params_vec.push(Box::new(control_mode.to_string()));
    updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')");
    params_vec.push(Box::new(session_id));
    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  Ok(())
}

pub(super) fn persist_environment_update(
  conn: &Connection,
  session_id: String,
  cwd: Option<String>,
  git_branch: Option<String>,
  git_sha: Option<String>,
  repository_root: Option<String>,
  is_worktree: Option<bool>,
) -> Result<(), rusqlite::Error> {
  let mut updates = Vec::new();
  let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

  if let Some(ref cwd) = cwd {
    updates.push("current_cwd = ?");
    params_vec.push(Box::new(cwd.clone()));
  }
  if let Some(branch) = git_branch {
    updates.push("git_branch = ?");
    params_vec.push(Box::new(branch));
  }
  if let Some(sha) = git_sha {
    updates.push("git_sha = ?");
    params_vec.push(Box::new(sha));
  }
  if let Some(root) = repository_root {
    updates.push("repository_root = ?");
    params_vec.push(Box::new(root));
  }
  if let Some(worktree) = is_worktree {
    updates.push("is_worktree = ?");
    params_vec.push(Box::new(worktree as i32));

    if worktree {
      if let Some(ref cwd_val) = cwd {
        let wt_id: Option<String> = conn
          .query_row(
            "SELECT id FROM worktrees WHERE worktree_path = ?1",
            params![cwd_val],
            |row| row.get(0),
          )
          .optional()?;
        if let Some(ref wt_id) = wt_id {
          updates.push("worktree_id = ?");
          params_vec.push(Box::new(wt_id.clone()));
        }
      }
    }
  }

  if !updates.is_empty() {
    params_vec.push(Box::new(session_id));
    let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
    let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
  }

  Ok(())
}
