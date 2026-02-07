//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::path::PathBuf;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension};
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
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },

    /// Update session status/work_status
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
    },

    /// End a session
    SessionEnd { id: String, reason: String },

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

    /// Store codex-core thread ID for a session
    SetThreadId {
        session_id: String,
        thread_id: String,
    },

    /// Set custom name for a session
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },

    /// Reactivate an ended session (for resume)
    ReactivateSession { id: String },

    /// Upsert a passive rollout-backed Codex session
    RolloutSessionUpsert {
        id: String,
        thread_id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: String,
        started_at: String,
    },

    /// Update rollout-backed session state
    RolloutSessionUpdate {
        id: String,
        project_path: Option<String>,
        model: Option<String>,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        attention_reason: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        total_tokens: Option<i64>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        custom_name: Option<Option<String>>,
    },

    /// Increment rollout prompt counter and set first prompt if missing
    RolloutPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment rollout tool counter
    RolloutToolIncrement { id: String },
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
        let result = tokio::task::spawn_blocking(move || flush_batch(&db_path, batch)).await;

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
         PRAGMA synchronous = NORMAL;",
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
            approval_policy,
            sandbox_mode,
        } => {
            let provider_str = match provider {
                Provider::Claude => "claude",
                Provider::Codex => "codex",
            };

            let now = chrono_now();
            let integration_mode: Option<&str> = match provider {
                Provider::Codex => Some("direct"),
                Provider::Claude => None,
            };

            conn.execute(
                "INSERT INTO sessions (id, project_path, project_name, model, provider, status, work_status, codex_integration_mode, approval_policy, sandbox_mode, started_at, last_activity_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'active', 'waiting', ?7, ?8, ?9, ?6, ?6)
                 ON CONFLICT(id) DO UPDATE SET
                   project_name = COALESCE(?3, project_name),
                   model = COALESCE(?4, model),
                   last_activity_at = ?6",
                params![id, project_path, project_name, model, provider_str, now, integration_mode, approval_policy, sandbox_mode],
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
                let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
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

        PersistCommand::MessageAppend {
            session_id,
            message,
        } => {
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
                let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
                params_vec.push(&session_id);

                conn.execute(&sql, rusqlite::params_from_iter(params_vec))?;
            }
        }

        PersistCommand::SetThreadId {
            session_id,
            thread_id,
        } => {
            conn.execute(
                "UPDATE sessions SET codex_thread_id = ? WHERE id = ?",
                params![thread_id, session_id],
            )?;
        }

        PersistCommand::SetCustomName {
            session_id,
            custom_name,
        } => {
            conn.execute(
                "UPDATE sessions SET custom_name = ?, last_activity_at = ? WHERE id = ?",
                params![custom_name, chrono_now(), session_id],
            )?;
        }

        PersistCommand::ReactivateSession { id } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE sessions SET status = 'active', work_status = 'waiting', ended_at = NULL, end_reason = NULL, last_activity_at = ?1 WHERE id = ?2",
                params![now, id],
            )?;
        }

        PersistCommand::RolloutSessionUpsert {
            id,
            thread_id,
            project_path,
            project_name,
            branch,
            model,
            context_label,
            transcript_path,
            started_at,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO sessions (
                    id, project_path, project_name, branch, model, context_label, transcript_path,
                    provider, status, work_status, codex_integration_mode, codex_thread_id,
                    started_at, last_activity_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'codex', 'active', 'waiting', 'passive', ?8, ?9, ?10)
                 ON CONFLICT(id) DO UPDATE SET
                    project_path = excluded.project_path,
                    project_name = COALESCE(excluded.project_name, sessions.project_name),
                    branch = COALESCE(excluded.branch, sessions.branch),
                    model = COALESCE(excluded.model, sessions.model),
                    context_label = COALESCE(excluded.context_label, sessions.context_label),
                    transcript_path = excluded.transcript_path,
                    provider = 'codex',
                    codex_integration_mode = 'passive',
                    codex_thread_id = excluded.codex_thread_id,
                    last_activity_at = excluded.last_activity_at",
                params![
                    id,
                    project_path,
                    project_name,
                    branch,
                    model,
                    context_label,
                    transcript_path,
                    thread_id,
                    started_at,
                    now,
                ],
            )?;
        }

        PersistCommand::RolloutSessionUpdate {
            id,
            project_path,
            model,
            status,
            work_status,
            attention_reason,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            total_tokens,
            last_tool,
            last_tool_at,
            custom_name,
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

            let mut updates: Vec<String> = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(path) = project_path {
                updates.push("project_path = ?".to_string());
                params_vec.push(Box::new(path));
            }
            if let Some(m) = model {
                updates.push("model = ?".to_string());
                params_vec.push(Box::new(m));
            }
            if let Some(s) = status_str {
                updates.push("status = ?".to_string());
                params_vec.push(Box::new(s.to_string()));
                if s == "ended" {
                    updates.push("ended_at = COALESCE(ended_at, ?)".to_string());
                    params_vec.push(Box::new(chrono_now()));
                }
            }
            if let Some(ws) = work_status_str {
                updates.push("work_status = ?".to_string());
                params_vec.push(Box::new(ws.to_string()));
            }
            if let Some(reason) = attention_reason {
                updates.push("attention_reason = ?".to_string());
                params_vec.push(Box::new(reason));
            }
            if let Some(tool_name) = pending_tool_name {
                updates.push("pending_tool_name = ?".to_string());
                params_vec.push(Box::new(tool_name));
            }
            if let Some(tool_input) = pending_tool_input {
                updates.push("pending_tool_input = ?".to_string());
                params_vec.push(Box::new(tool_input));
            }
            if let Some(question) = pending_question {
                updates.push("pending_question = ?".to_string());
                params_vec.push(Box::new(question));
            }
            if let Some(tokens) = total_tokens {
                updates.push("total_tokens = ?".to_string());
                params_vec.push(Box::new(tokens));
            }
            if let Some(tool) = last_tool {
                updates.push("last_tool = ?".to_string());
                params_vec.push(Box::new(tool));
            }
            if let Some(tool_at) = last_tool_at {
                updates.push("last_tool_at = ?".to_string());
                params_vec.push(Box::new(tool_at));
            }
            if let Some(name) = custom_name {
                updates.push("custom_name = ?".to_string());
                params_vec.push(Box::new(name));
            }

            if !updates.is_empty() {
                updates.push("last_activity_at = ?".to_string());
                params_vec.push(Box::new(chrono_now()));

                let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
                params_vec.push(Box::new(id));

                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|b| b.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
        }

        PersistCommand::RolloutPromptIncrement { id, first_prompt } => {
            if let Some(prompt) = first_prompt {
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = prompt_count + 1,
                         first_prompt = COALESCE(first_prompt, ?1),
                         last_activity_at = ?2
                     WHERE id = ?3",
                    params![prompt, chrono_now(), id],
                )?;
            } else {
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = prompt_count + 1,
                         last_activity_at = ?1
                     WHERE id = ?2",
                    params![chrono_now(), id],
                )?;
            }
        }

        PersistCommand::RolloutToolIncrement { id } => {
            conn.execute(
                "UPDATE sessions
                 SET tool_count = tool_count + 1,
                     last_activity_at = ?1
                 WHERE id = ?2",
                params![chrono_now(), id],
            )?;
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

/// A session restored from the database on startup
#[derive(Debug)]
pub struct RestoredSession {
    pub id: String,
    pub project_path: String,
    pub project_name: Option<String>,
    pub model: Option<String>,
    pub custom_name: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub messages: Vec<Message>,
}

/// Load active Codex sessions from the database (for server restart recovery)
pub async fn load_active_codex_sessions() -> Result<Vec<RestoredSession>, anyhow::Error> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");

    let sessions = tokio::task::spawn_blocking(move || -> Result<Vec<RestoredSession>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(Vec::new());
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;"
        )?;

        // Load active codex sessions
        let mut stmt = conn.prepare(
            "SELECT id, project_path, project_name, model, custom_name, started_at, last_activity_at, approval_policy, sandbox_mode
             FROM sessions
             WHERE provider = 'codex' AND status = 'active'
               AND (codex_integration_mode = 'direct' OR codex_integration_mode IS NULL)"
        )?;

        #[allow(clippy::type_complexity)]
        let session_rows: Vec<(String, String, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>)> = stmt
            .query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();

        let mut sessions = Vec::new();

        for (id, project_path, project_name, model, custom_name, started_at, last_activity_at, approval_policy, sandbox_mode) in session_rows {
            // Load messages for this session
            let mut msg_stmt = conn.prepare(
                "SELECT id, type, content, timestamp, tool_name, tool_input, tool_output, tool_duration, is_in_progress
                 FROM messages
                 WHERE session_id = ?
                 ORDER BY sequence"
            )?;

            let messages: Vec<Message> = msg_stmt
                .query_map(params![&id], |row| {
                    let type_str: String = row.get(1)?;
                    let message_type = match type_str.as_str() {
                        "user" => MessageType::User,
                        "assistant" => MessageType::Assistant,
                        "thinking" => MessageType::Thinking,
                        "tool" => MessageType::Tool,
                        "toolResult" => MessageType::ToolResult,
                        _ => MessageType::Assistant,
                    };

                    let duration_secs: Option<f64> = row.get(7)?;
                    let is_error_int: i32 = row.get(8)?;

                    Ok(Message {
                        id: row.get(0)?,
                        session_id: id.clone(),
                        message_type,
                        content: row.get(2)?,
                        timestamp: row.get(3)?,
                        tool_name: row.get(4)?,
                        tool_input: row.get(5)?,
                        tool_output: row.get(6)?,
                        duration_ms: duration_secs.map(|s| (s * 1000.0) as u64),
                        is_error: is_error_int != 0,
                    })
                })?
                .filter_map(|r| r.ok())
                .collect();

            sessions.push(RestoredSession {
                id,
                project_path,
                project_name,
                model,
                custom_name,
                started_at,
                last_activity_at,
                approval_policy,
                sandbox_mode,
                messages,
            });
        }

        Ok(sessions)
    }).await??;

    Ok(sessions)
}

/// Load a specific session by ID (for resume — includes ended sessions)
pub async fn load_session_by_id(id: &str) -> Result<Option<RestoredSession>, anyhow::Error> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");
    let id_owned = id.to_string();

    let result = tokio::task::spawn_blocking(move || -> Result<Option<RestoredSession>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;"
        )?;

        let mut stmt = conn.prepare(
            "SELECT id, project_path, project_name, model, custom_name, started_at, last_activity_at, approval_policy, sandbox_mode
             FROM sessions
             WHERE id = ?1 AND provider = 'codex'
               AND (codex_integration_mode = 'direct' OR codex_integration_mode IS NULL)"
        )?;

        let row: Option<(String, String, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>)> = stmt
            .query_row(params![&id_owned], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ))
            })
            .optional()?;

        let Some((id, project_path, project_name, model, custom_name, started_at, last_activity_at, approval_policy, sandbox_mode)) = row else {
            return Ok(None);
        };

        // Load messages
        let mut msg_stmt = conn.prepare(
            "SELECT id, type, content, timestamp, tool_name, tool_input, tool_output, tool_duration, is_in_progress
             FROM messages
             WHERE session_id = ?
             ORDER BY sequence"
        )?;

        let messages: Vec<Message> = msg_stmt
            .query_map(params![&id], |row| {
                let type_str: String = row.get(1)?;
                let message_type = match type_str.as_str() {
                    "user" => MessageType::User,
                    "assistant" => MessageType::Assistant,
                    "thinking" => MessageType::Thinking,
                    "tool" => MessageType::Tool,
                    "toolResult" => MessageType::ToolResult,
                    _ => MessageType::Assistant,
                };

                let duration_secs: Option<f64> = row.get(7)?;
                let is_error_int: i32 = row.get(8)?;

                Ok(Message {
                    id: row.get(0)?,
                    session_id: id.clone(),
                    message_type,
                    content: row.get(2)?,
                    timestamp: row.get(3)?,
                    tool_name: row.get(4)?,
                    tool_input: row.get(5)?,
                    tool_output: row.get(6)?,
                    duration_ms: duration_secs.map(|s| (s * 1000.0) as u64),
                    is_error: is_error_int != 0,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(Some(RestoredSession {
            id,
            project_path,
            project_name,
            model,
            custom_name,
            started_at,
            last_activity_at,
            approval_policy,
            sandbox_mode,
            messages,
        }))
    }).await??;

    Ok(result)
}

/// Create a sender for the persistence writer
pub fn create_persistence_channel() -> (mpsc::Sender<PersistCommand>, mpsc::Receiver<PersistCommand>)
{
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
