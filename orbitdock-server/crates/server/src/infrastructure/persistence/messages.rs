use orbitdock_protocol::{Message, MessageType};
use rusqlite::{params, Connection, OptionalExtension};

pub(super) fn load_messages_from_db(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<Message>, anyhow::Error> {
    let mut msg_stmt = conn.prepare(
        "SELECT id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json
         FROM messages
         WHERE session_id = ?
         ORDER BY sequence",
    )?;

    let messages: Vec<Message> = msg_stmt
        .query_map(params![session_id], |row| {
            let type_str: String = row.get(1)?;
            let message_type = match type_str.as_str() {
                "user" => MessageType::User,
                "assistant" => MessageType::Assistant,
                "thinking" => MessageType::Thinking,
                "tool" => MessageType::Tool,
                "tool_result" | "toolResult" => MessageType::ToolResult,
                "steer" => MessageType::Steer,
                "shell" => MessageType::Shell,
                _ => MessageType::Assistant,
            };

            let duration_secs: Option<f64> = row.get(8)?;
            let is_error_int: i32 = row.get(9)?;
            let is_in_progress_int: i32 = row.get(10)?;
            let images_json: Option<String> = row.get(11)?;
            let images: Vec<orbitdock_protocol::ImageInput> = images_json
                .and_then(|j| serde_json::from_str(&j).ok())
                .unwrap_or_default();

            Ok(Message {
                id: row.get(0)?,
                session_id: session_id.to_string(),
                sequence: row
                    .get::<_, Option<i64>>(4)?
                    .and_then(|sequence| u64::try_from(sequence).ok()),
                message_type,
                content: row.get(2)?,
                timestamp: row.get(3)?,
                tool_name: row.get(5)?,
                tool_input: row.get(6)?,
                tool_output: row.get(7)?,
                duration_ms: duration_secs.map(|s| (s * 1000.0) as u64),
                is_error: is_error_int != 0,
                is_in_progress: is_in_progress_int != 0,
                images,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    Ok(messages)
}

pub struct MessagePage {
    pub messages: Vec<Message>,
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
) -> Result<MessagePage, anyhow::Error> {
    let total_count = count_messages_in_db(conn, session_id)?;
    if limit == 0 || total_count == 0 {
        return Ok(MessagePage {
            messages: vec![],
            total_count,
        });
    }

    let sql = if before_sequence.is_some() {
        "SELECT id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json
         FROM messages
         WHERE session_id = ?1 AND sequence < ?2
         ORDER BY sequence DESC
         LIMIT ?3"
    } else {
        "SELECT id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json
         FROM messages
         WHERE session_id = ?1
         ORDER BY sequence DESC
         LIMIT ?2"
    };

    let mut stmt = conn.prepare(sql)?;
    let limit = i64::try_from(limit).unwrap_or(i64::MAX);
    let mut messages: Vec<Message> = if let Some(before_sequence) = before_sequence {
        let before_sequence = i64::try_from(before_sequence).unwrap_or(i64::MAX);
        stmt.query_map(params![session_id, before_sequence, limit], |row| {
            let type_str: String = row.get(1)?;
            let message_type = match type_str.as_str() {
                "user" => MessageType::User,
                "assistant" => MessageType::Assistant,
                "thinking" => MessageType::Thinking,
                "tool" => MessageType::Tool,
                "tool_result" | "toolResult" => MessageType::ToolResult,
                "steer" => MessageType::Steer,
                "shell" => MessageType::Shell,
                _ => MessageType::Assistant,
            };

            let duration_secs: Option<f64> = row.get(8)?;
            let is_error_int: i32 = row.get(9)?;
            let is_in_progress_int: i32 = row.get(10)?;
            let images_json: Option<String> = row.get(11)?;
            let images: Vec<orbitdock_protocol::ImageInput> = images_json
                .and_then(|j| serde_json::from_str(&j).ok())
                .unwrap_or_default();

            Ok(Message {
                id: row.get(0)?,
                session_id: session_id.to_string(),
                sequence: row
                    .get::<_, Option<i64>>(4)?
                    .and_then(|sequence| u64::try_from(sequence).ok()),
                message_type,
                content: row.get(2)?,
                timestamp: row.get(3)?,
                tool_name: row.get(5)?,
                tool_input: row.get(6)?,
                tool_output: row.get(7)?,
                duration_ms: duration_secs.map(|s| (s * 1000.0) as u64),
                is_error: is_error_int != 0,
                is_in_progress: is_in_progress_int != 0,
                images,
            })
        })?
        .filter_map(|row| row.ok())
        .collect()
    } else {
        stmt.query_map(params![session_id, limit], |row| {
            let type_str: String = row.get(1)?;
            let message_type = match type_str.as_str() {
                "user" => MessageType::User,
                "assistant" => MessageType::Assistant,
                "thinking" => MessageType::Thinking,
                "tool" => MessageType::Tool,
                "tool_result" | "toolResult" => MessageType::ToolResult,
                "steer" => MessageType::Steer,
                "shell" => MessageType::Shell,
                _ => MessageType::Assistant,
            };

            let duration_secs: Option<f64> = row.get(8)?;
            let is_error_int: i32 = row.get(9)?;
            let is_in_progress_int: i32 = row.get(10)?;
            let images_json: Option<String> = row.get(11)?;
            let images: Vec<orbitdock_protocol::ImageInput> = images_json
                .and_then(|j| serde_json::from_str(&j).ok())
                .unwrap_or_default();

            Ok(Message {
                id: row.get(0)?,
                session_id: session_id.to_string(),
                sequence: row
                    .get::<_, Option<i64>>(4)?
                    .and_then(|sequence| u64::try_from(sequence).ok()),
                message_type,
                content: row.get(2)?,
                timestamp: row.get(3)?,
                tool_name: row.get(5)?,
                tool_input: row.get(6)?,
                tool_output: row.get(7)?,
                duration_ms: duration_secs.map(|s| (s * 1000.0) as u64),
                is_error: is_error_int != 0,
                is_in_progress: is_in_progress_int != 0,
                images,
            })
        })?
        .filter_map(|row| row.ok())
        .collect()
    };
    messages.reverse();

    Ok(MessagePage {
        messages,
        total_count,
    })
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

/// Load messages for a session directly from the database.
/// Used for lazy-loading messages when viewing closed sessions.
pub async fn load_messages_for_session(session_id: &str) -> Result<Vec<Message>, anyhow::Error> {
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
) -> Result<MessagePage, anyhow::Error> {
    let db_path = crate::infrastructure::paths::db_path();
    let session_id_owned = session_id.to_string();

    tokio::task::spawn_blocking(move || {
        if !db_path.exists() {
            return Ok(MessagePage {
                messages: vec![],
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
