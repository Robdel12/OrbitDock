//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::path::PathBuf;
use std::time::Duration;

use rusqlite::{params, Connection};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{Message, MessageType, Provider, SessionStatus, TokenUsage, WorkStatus};

/// Commands that can be persisted
#[derive(Debug, Clone)]
pub enum PersistCommand {
    /// Create a new session
    SessionCreate {
        id: String,
        provider: Provider,
        project_path: String,
        project_name: Option<String>,
        model: Option<String>,
    },

    /// Update session status/work_status
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
    },

    /// End a session
    SessionEnd {
        id: String,
        reason: String,
    },

    /// Append a message
    MessageAppend {
        session_id: String,
        message: Message,
    },

    /// Update a message (tool output, completion, etc.)
    MessageUpdate {
        session_id: String,
        message_id: String,
        content: Option<String>,
        tool_output: Option<String>,
        duration_ms: Option<u64>,
        is_error: Option<bool>,
    },

    /// Update token usage
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
    },

    /// Update diff/plan for session
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },
}

/// Persistence writer that batches SQLite writes
pub struct PersistenceWriter {
    rx: mpsc::Receiver<PersistCommand>,
    db_path: PathBuf,
    batch: Vec<PersistCommand>,
    batch_size: usize,
    flush_interval: Duration,
}

impl PersistenceWriter {
    /// Create a new persistence writer
    pub fn new(rx: mpsc::Receiver<PersistCommand>) -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");

        Self {
            rx,
            db_path,
            batch: Vec::with_capacity(100),
            batch_size: 50,
            flush_interval: Duration::from_millis(100),
        }
    }

    /// Run the persistence writer (call from tokio::spawn)
    pub async fn run(mut self) {
        info!("PersistenceWriter started, db: {:?}", self.db_path);

        let mut interval = tokio::time::interval(self.flush_interval);

        loop {
            tokio::select! {
                Some(cmd) = self.rx.recv() => {
                    self.batch.push(cmd);

                    // Flush if batch is large enough
                    if self.batch.len() >= self.batch_size {
                        self.flush().await;
                    }
                }

                _ = interval.tick() => {
                    // Periodic flush
                    if !self.batch.is_empty() {
                        self.flush().await;
                    }
                }
            }
        }
    }

    /// Flush the batch to SQLite
    async fn flush(&mut self) {
        if self.batch.is_empty() {
            return;
        }

        let batch = std::mem::take(&mut self.batch);
        let db_path = self.db_path.clone();

        // Use spawn_blocking for SQLite (it's not async)
        let result = tokio::task::spawn_blocking(move || {
            flush_batch(&db_path, batch)
        })
        .await;

        match result {
            Ok(Ok(count)) => {
                debug!("Persisted {} commands", count);
            }
            Ok(Err(e)) => {
                error!("Persistence flush failed: {}", e);
            }
            Err(e) => {
                error!("spawn_blocking panicked: {}", e);
            }
        }
    }
}

/// Flush a batch of commands to SQLite (runs in blocking thread)
fn flush_batch(db_path: &PathBuf, batch: Vec<PersistCommand>) -> Result<usize, rusqlite::Error> {
    let conn = Connection::open(db_path)?;

    // Set up connection for concurrent access
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;"
    )?;

    let count = batch.len();

    // Use a transaction for the entire batch
    let tx = conn.unchecked_transaction()?;

    for cmd in batch {
        if let Err(e) = execute_command(&tx, cmd) {
            warn!("Failed to execute command: {}", e);
            // Continue with other commands
        }
    }

    tx.commit()?;

    Ok(count)
}

/// Execute a single persist command
fn execute_command(conn: &Connection, cmd: PersistCommand) -> Result<(), rusqlite::Error> {
    match cmd {
        PersistCommand::SessionCreate {
            id,
            provider,
            project_path,
            project_name,
            model,
        } => {
            let provider_str = match provider {
                Provider::Claude => "claude",
                Provider::Codex => "codex",
            };

            let now = chrono_now();

            conn.execute(
                "INSERT INTO sessions (id, project_path, project_name, model, provider, status, work_status, started_at, last_activity_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'active', 'waiting', ?6, ?6)
                 ON CONFLICT(id) DO UPDATE SET
                   project_name = COALESCE(?3, project_name),
                   model = COALESCE(?4, model),
                   last_activity_at = ?6",
                params![id, project_path, project_name, model, provider_str, now],
            )?;
        }

        PersistCommand::SessionUpdate {
            id,
            status,
            work_status,
            last_activity_at,
        } => {
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

            // Build dynamic update
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
            if let Some(ref la) = last_activity_at {
                updates.push("last_activity_at = ?");
                params_vec.push(la);
            }

            if !updates.is_empty() {
                let sql = format!(
                    "UPDATE sessions SET {} WHERE id = ?",
                    updates.join(", ")
                );
                params_vec.push(&id);

                conn.execute(&sql, rusqlite::params_from_iter(params_vec))?;
            }
        }

        PersistCommand::SessionEnd { id, reason } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE sessions SET status = 'ended', work_status = 'ended', ended_at = ?1, end_reason = ?2, last_activity_at = ?1 WHERE id = ?3",
                params![now, reason, id],
            )?;
        }

        PersistCommand::MessageAppend { session_id, message } => {
            let type_str = match message.message_type {
                MessageType::User => "user",
                MessageType::Assistant => "assistant",
                MessageType::Thinking => "thinking",
                MessageType::Tool => "tool",
                MessageType::ToolResult => "toolResult",
            };

            // Get next sequence number
            let seq: i64 = conn.query_row(
                "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE session_id = ?",
                params![session_id],
                |row| row.get(0),
            )?;

            conn.execute(
                "INSERT INTO messages (id, session_id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_in_progress)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    message.id,
                    session_id,
                    type_str,
                    message.content,
                    message.timestamp,
                    seq,
                    message.tool_name,
                    message.tool_input,
                    message.tool_output,
                    message.duration_ms.map(|d| d as f64 / 1000.0),
                    if message.is_error { 1 } else { 0 },
                ],
            )?;
        }

        PersistCommand::MessageUpdate {
            session_id,
            message_id,
            content,
            tool_output,
            duration_ms,
            is_error,
        } => {
            let mut updates = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(c) = content {
                updates.push("content = ?");
                params_vec.push(Box::new(c));
            }
            if let Some(o) = tool_output {
                updates.push("tool_output = ?");
                params_vec.push(Box::new(o));
            }
            if let Some(d) = duration_ms {
                updates.push("tool_duration = ?");
                params_vec.push(Box::new(d as f64 / 1000.0));
            }
            if let Some(e) = is_error {
                updates.push("is_in_progress = ?");
                params_vec.push(Box::new(if e { 1 } else { 0 }));
            }

            // Always mark as no longer in progress when updating
            updates.push("is_in_progress = 0");

            if !updates.is_empty() {
                let sql = format!(
                    "UPDATE messages SET {} WHERE id = ? AND session_id = ?",
                    updates.join(", ")
                );
                params_vec.push(Box::new(message_id));
                params_vec.push(Box::new(session_id));

                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|b| b.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
        }

        PersistCommand::TokensUpdate { session_id, usage } => {
            conn.execute(
                "UPDATE sessions SET
                   codex_input_tokens = ?1,
                   codex_output_tokens = ?2,
                   codex_cached_tokens = ?3,
                   codex_context_window = ?4,
                   last_activity_at = ?5
                 WHERE id = ?6",
                params![
                    usage.input_tokens as i64,
                    usage.output_tokens as i64,
                    usage.cached_tokens as i64,
                    usage.context_window as i64,
                    chrono_now(),
                    session_id,
                ],
            )?;
        }

        PersistCommand::TurnStateUpdate {
            session_id,
            diff,
            plan,
        } => {
            let mut updates = Vec::new();
            let mut params_vec: Vec<&dyn rusqlite::ToSql> = Vec::new();

            if let Some(ref d) = diff {
                updates.push("current_diff = ?");
                params_vec.push(d);
            }
            if let Some(ref p) = plan {
                updates.push("current_plan = ?");
                params_vec.push(p);
            }

            if !updates.is_empty() {
                let sql = format!(
                    "UPDATE sessions SET {} WHERE id = ?",
                    updates.join(", ")
                );
                params_vec.push(&session_id);

                conn.execute(&sql, rusqlite::params_from_iter(params_vec))?;
            }
        }
    }

    Ok(())
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();

    // Format as ISO 8601
    let secs = duration.as_secs();
    let datetime = time_to_iso8601(secs);
    datetime
}

/// Convert Unix timestamp to ISO 8601 string
fn time_to_iso8601(secs: u64) -> String {
    // Simple implementation - for production use chrono crate
    let days_since_epoch = secs / 86400;
    let time_of_day = secs % 86400;

    let hours = time_of_day / 3600;
    let minutes = (time_of_day % 3600) / 60;
    let seconds = time_of_day % 60;

    // Calculate year, month, day from days since epoch (1970-01-01)
    let mut days = days_since_epoch as i64;
    let mut year = 1970i64;

    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if days < days_in_year {
            break;
        }
        days -= days_in_year;
        year += 1;
    }

    let mut month = 1;
    let days_in_months = if is_leap_year(year) {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    for days_in_month in days_in_months {
        if days < days_in_month {
            break;
        }
        days -= days_in_month;
        month += 1;
    }

    let day = days + 1;

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

/// Create a sender for the persistence writer
pub fn create_persistence_channel() -> (mpsc::Sender<PersistCommand>, mpsc::Receiver<PersistCommand>) {
    mpsc::channel(1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_time_to_iso8601() {
        // 2024-01-15 12:30:45 UTC
        let result = time_to_iso8601(1705322445);
        assert!(result.starts_with("2024-01-15"));
    }
}
