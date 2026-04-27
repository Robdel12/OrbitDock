use rusqlite::{params, Connection};

use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
use orbitdock_protocol::{TokenUsage, TokenUsageSnapshotKind};

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

  let (provider, model): (String, Option<String>) = conn.query_row(
    "SELECT COALESCE(provider, 'claude'), model
     FROM sessions
     WHERE id = ?1",
    params![session_id],
    |row| Ok((row.get(0)?, row.get(1)?)),
  )?;

  let snapshot = super::TurnSnapshotRow {
    session_id: &session_id,
    turn_id: &turn_id,
    turn_seq,
    provider: &provider,
    model: model.as_deref(),
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
