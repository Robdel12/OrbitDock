use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, TurnStatus,
};
use orbitdock_protocol::Provider;
use rusqlite::{params, Connection, OptionalExtension};

/// Column layout for all message SELECT queries:
///   0: id, 1: type, 2: timestamp, 3: sequence, 4: row_data, 5: turn_status
const MESSAGE_SELECT: &str =
  "SELECT id, type, timestamp, sequence, row_data, turn_status FROM messages";

/// Deserialize a ConversationRowEntry from a database row.
fn row_entry_from_db(
  row: &rusqlite::Row<'_>,
  session_id: &str,
) -> Result<Option<ConversationRowEntry>, rusqlite::Error> {
  let sequence: i64 = row.get::<_, Option<i64>>(3)?.unwrap_or(0);
  let row_data: Option<String> = row.get(4)?;
  let msg_type: String = row.get(1)?;

  let conversation_row = if let Some(json) = row_data {
    match serde_json::from_str::<ConversationRow>(&json) {
      Ok(cr) => crate::domain::conversation_semantics::upgrade_row(
        Provider::Claude,
        normalize_legacy_message_kind(&msg_type, &json, cr),
      ),
      Err(_) => return Ok(None),
    }
  } else {
    // No row_data — skip. Legacy flat columns have been dropped (V042).
    return Ok(None);
  };

  let turn_status: TurnStatus = row
    .get::<_, Option<String>>(5)
    .ok()
    .flatten()
    .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
    .unwrap_or_default();

  Ok(Some(ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: sequence.max(0) as u64,
    turn_id: None,
    turn_status,
    row: conversation_row,
  }))
}

fn normalize_legacy_message_kind(
  msg_type: &str,
  raw_json: &str,
  row: ConversationRow,
) -> ConversationRow {
  match (msg_type, row) {
    ("steer", ConversationRow::User(message)) => ConversationRow::Steer(message),
    ("user", ConversationRow::User(message)) if raw_json_contains_legacy_steer(raw_json) => {
      ConversationRow::Steer(message)
    }
    (_, row) => row,
  }
}

fn raw_json_contains_legacy_steer(raw_json: &str) -> bool {
  serde_json::from_str::<serde_json::Value>(raw_json)
    .ok()
    .and_then(|value| {
      value
        .get("input_kind")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
    })
    .as_deref()
    == Some("steer")
}

pub(super) fn load_messages_from_db(
  conn: &Connection,
  session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
  let sql = format!("{MESSAGE_SELECT} WHERE session_id = ? ORDER BY sequence");
  let mut stmt = conn.prepare(&sql)?;

  let rows: Vec<ConversationRowEntry> = stmt
    .query_map(params![session_id], |row| {
      row_entry_from_db(row, session_id)
    })?
    .filter_map(|r| r.ok().flatten())
    .collect();

  Ok(rows)
}

pub struct RowPage {
  pub rows: Vec<ConversationRowEntry>,
  pub total_count: u64,
}

fn count_messages_in_db(conn: &Connection, session_id: &str) -> Result<u64, rusqlite::Error> {
  conn
    .query_row(
      "SELECT COUNT(*) FROM messages WHERE session_id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0),
    )
    .map(|count| count.max(0) as u64)
}

pub(super) fn load_message_page_from_db(
  conn: &Connection,
  session_id: &str,
  before_sequence: Option<u64>,
  limit: usize,
) -> Result<RowPage, anyhow::Error> {
  let total_count = count_messages_in_db(conn, session_id)?;
  if limit == 0 || total_count == 0 {
    return Ok(RowPage {
      rows: vec![],
      total_count,
    });
  }

  let sql = if before_sequence.is_some() {
    format!(
      "{MESSAGE_SELECT} WHERE session_id = ?1 AND sequence < ?2 ORDER BY sequence DESC LIMIT ?3"
    )
  } else {
    format!("{MESSAGE_SELECT} WHERE session_id = ?1 ORDER BY sequence DESC LIMIT ?2")
  };

  let mut stmt = conn.prepare(&sql)?;
  let limit = i64::try_from(limit).unwrap_or(i64::MAX);
  let mut rows: Vec<ConversationRowEntry> = if let Some(before_seq) = before_sequence {
    let before_seq = i64::try_from(before_seq).unwrap_or(i64::MAX);
    stmt
      .query_map(params![session_id, before_seq, limit], |row| {
        row_entry_from_db(row, session_id)
      })?
      .filter_map(|r| r.ok().flatten())
      .collect()
  } else {
    stmt
      .query_map(params![session_id, limit], |row| {
        row_entry_from_db(row, session_id)
      })?
      .filter_map(|r| r.ok().flatten())
      .collect()
  };
  rows.reverse();

  Ok(RowPage { rows, total_count })
}

pub(super) fn load_latest_completed_conversation_message_from_db(
  conn: &Connection,
  session_id: &str,
) -> Result<Option<String>, rusqlite::Error> {
  let row_data: Option<String> = conn
    .query_row(
      "SELECT row_data
             FROM messages
             WHERE session_id = ?1
               AND type IN ('user', 'assistant')
               AND is_in_progress = 0
               AND row_data IS NOT NULL
             ORDER BY sequence DESC
             LIMIT 1",
      params![session_id],
      |row| row.get(0),
    )
    .optional()?;

  let content = row_data.and_then(|json| {
    serde_json::from_str::<ConversationRow>(&json)
      .ok()
      .and_then(|row| super::extract_row_content(&row))
      .filter(|s| !s.trim().is_empty())
  });

  Ok(content.map(|c| c.chars().take(200).collect()))
}

/// Load a single row by its id and session_id from the database.
pub fn load_row_by_id(
  conn: &Connection,
  session_id: &str,
  row_id: &str,
) -> Result<Option<ConversationRowEntry>, anyhow::Error> {
  let sql = format!("{MESSAGE_SELECT} WHERE session_id = ?1 AND id = ?2 LIMIT 1");
  let mut stmt = conn.prepare(&sql)?;

  let entry = stmt
    .query_map(params![session_id, row_id], |row| {
      row_entry_from_db(row, session_id)
    })?
    .filter_map(|r| r.ok().flatten())
    .next();

  Ok(entry)
}

/// Load a single row by id asynchronously.
pub async fn load_row_by_id_async(
  session_id: &str,
  row_id: &str,
) -> Result<Option<ConversationRowEntry>, anyhow::Error> {
  let db_path = crate::infrastructure::paths::db_path();
  let session_id_owned = session_id.to_string();
  let row_id_owned = row_id.to_string();

  tokio::task::spawn_blocking(move || {
    if !db_path.exists() {
      return Ok(None);
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )?;

    load_row_by_id(&conn, &session_id_owned, &row_id_owned)
  })
  .await?
}

/// Load rows for a session directly from the database.
pub async fn load_messages_for_session(
  session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
  let db_path = crate::infrastructure::paths::db_path();
  let session_id_owned = session_id.to_string();

  tokio::task::spawn_blocking(move || {
    if !db_path.exists() {
      return Ok(Vec::new());
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )?;

    load_messages_from_db(&conn, &session_id_owned)
  })
  .await?
}

pub async fn load_message_page_for_session(
  session_id: &str,
  before_sequence: Option<u64>,
  limit: usize,
) -> Result<RowPage, anyhow::Error> {
  let db_path = crate::infrastructure::paths::db_path();
  let session_id_owned = session_id.to_string();

  tokio::task::spawn_blocking(move || {
    if !db_path.exists() {
      return Ok(RowPage {
        rows: vec![],
        total_count: 0,
      });
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )?;

    load_message_page_from_db(&conn, &session_id_owned, before_sequence, limit)
  })
  .await?
}
