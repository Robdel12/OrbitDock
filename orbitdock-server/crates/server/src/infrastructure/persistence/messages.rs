use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
use rusqlite::{params, Connection, OptionalExtension};

/// Deserialize a ConversationRowEntry from a database row.
/// Prefers `row_data` JSON column; falls back to legacy flat columns for
/// messages written before V022 added `row_data`.
fn row_entry_from_db(
    row: &rusqlite::Row<'_>,
    session_id: &str,
) -> Result<Option<ConversationRowEntry>, rusqlite::Error> {
    let sequence: i64 = row.get::<_, Option<i64>>(4)?.unwrap_or(0);
    let row_data: Option<String> = row.get(5)?;

    let conversation_row = if let Some(json) = row_data {
        match serde_json::from_str::<ConversationRow>(&json) {
            Ok(cr) => cr,
            Err(_) => return Ok(None),
        }
    } else {
        // Legacy fallback: reconstruct from flat columns (id, type, content, timestamp).
        match legacy_row_from_db(row) {
            Some(cr) => cr,
            None => return Ok(None),
        }
    };

    Ok(Some(ConversationRowEntry {
        session_id: session_id.to_string(),
        sequence: sequence.max(0) as u64,
        turn_id: None,
        row: conversation_row,
    }))
}

/// Build a ConversationRow from the legacy flat columns for pre-V022 messages.
fn legacy_row_from_db(row: &rusqlite::Row<'_>) -> Option<ConversationRow> {
    let id: String = row.get(0).ok()?;
    let msg_type: String = row.get(1).ok()?;
    let content: String = row.get::<_, Option<String>>(2).ok()?.unwrap_or_default();
    let timestamp: Option<String> = row.get(3).ok()?;

    let msg = orbitdock_protocol::conversation_contracts::MessageRowContent {
        id,
        content,
        turn_id: None,
        timestamp,
        is_streaming: false,
        images: Vec::new(),
    };

    match msg_type.as_str() {
        "user" => Some(ConversationRow::User(msg)),
        "assistant" => Some(ConversationRow::Assistant(msg)),
        "thinking" => Some(ConversationRow::Thinking(msg)),
        "system" => Some(ConversationRow::System(msg)),
        // Tool, approval, question, etc. — render as system messages so they're visible
        _ => Some(ConversationRow::System(msg)),
    }
}

pub(super) fn load_messages_from_db(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, type, content, timestamp, sequence, row_data
         FROM messages
         WHERE session_id = ?
         ORDER BY sequence",
    )?;

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
    conn.query_row(
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
        "SELECT id, type, content, timestamp, sequence, row_data
         FROM messages
         WHERE session_id = ?1 AND sequence < ?2
         ORDER BY sequence DESC
         LIMIT ?3"
    } else {
        "SELECT id, type, content, timestamp, sequence, row_data
         FROM messages
         WHERE session_id = ?1
         ORDER BY sequence DESC
         LIMIT ?2"
    };

    let mut stmt = conn.prepare(sql)?;
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let mut rows: Vec<ConversationRowEntry> = if let Some(before_seq) = before_sequence {
        let before_seq = i64::try_from(before_seq).unwrap_or(i64::MAX);
        stmt.query_map(params![session_id, before_seq, limit], |row| {
            row_entry_from_db(row, session_id)
        })?
        .filter_map(|r| r.ok().flatten())
        .collect()
    } else {
        stmt.query_map(params![session_id, limit], |row| {
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
    let latest: Option<String> = conn
        .query_row(
            "SELECT content
             FROM messages
             WHERE session_id = ?1
               AND type IN ('user', 'assistant')
               AND is_in_progress = 0
               AND content IS NOT NULL
               AND trim(content) != ''
             ORDER BY sequence DESC
             LIMIT 1",
            params![session_id],
            |row| row.get(0),
        )
        .optional()?;

    Ok(latest.map(|content| content.chars().take(200).collect()))
}

/// Load a single row by its id and session_id from the database.
pub fn load_row_by_id(
    conn: &Connection,
    session_id: &str,
    row_id: &str,
) -> Result<Option<ConversationRowEntry>, anyhow::Error> {
    let mut stmt = conn.prepare(
        "SELECT id, type, content, timestamp, sequence, row_data
         FROM messages
         WHERE session_id = ?1 AND id = ?2
         LIMIT 1",
    )?;

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
