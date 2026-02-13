//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::path::PathBuf;
use std::time::Duration;
use std::{
    fs::File,
    io::{BufRead, BufReader},
};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{
    ApprovalHistoryItem, ApprovalType, Message, MessageType, Provider, SessionStatus, TokenUsage,
    WorkStatus,
};

use crate::session_naming::name_from_first_prompt;

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
        forked_from_session_id: Option<String>,
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

    /// End any non-direct session row that accidentally uses a direct thread id as session id
    CleanupThreadShadowSession { thread_id: String, reason: String },

    /// Set custom name for a session
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },

    /// Persist session autonomy configuration
    SetSessionConfig {
        session_id: String,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },

    /// Reactivate an ended session (for resume)
    ReactivateSession { id: String },

    /// Upsert a Claude hook-backed session
    ClaudeSessionUpsert {
        id: String,
        project_path: String,
        project_name: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: Option<String>,
        source: Option<String>,
        agent_type: Option<String>,
        permission_mode: Option<String>,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
    },

    /// Update Claude session state/metadata from hook events
    ClaudeSessionUpdate {
        id: String,
        work_status: Option<String>,
        attention_reason: Option<Option<String>>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        source: Option<Option<String>>,
        agent_type: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        active_subagent_id: Option<Option<String>>,
        active_subagent_type: Option<Option<String>>,
        first_prompt: Option<String>,
        compact_count_increment: bool,
    },

    /// End Claude session
    ClaudeSessionEnd { id: String, reason: Option<String> },

    /// Increment prompt counter for Claude hook session
    ClaudePromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment tool counter for Claude hook session
    ClaudeToolIncrement { id: String },

    /// Create/refresh subagent row
    ClaudeSubagentStart {
        id: String,
        session_id: String,
        agent_type: String,
    },

    /// End subagent row
    ClaudeSubagentEnd {
        id: String,
        transcript_path: Option<String>,
    },

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

    /// Increment direct Codex prompt counter and set first prompt if missing
    CodexPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment rollout tool counter
    RolloutToolIncrement { id: String },

    /// Persist an approval request event
    ApprovalRequested {
        session_id: String,
        request_id: String,
        approval_type: ApprovalType,
        tool_name: Option<String>,
        command: Option<String>,
        file_path: Option<String>,
        cwd: Option<String>,
        proposed_amendment: Option<Vec<String>>,
    },

    /// Persist the user decision for an approval request
    ApprovalDecision {
        session_id: String,
        request_id: String,
        decision: String,
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
        info!(
            component = "persistence",
            event = "persistence.writer.started",
            db_path = %self.db_path.display(),
            batch_size = self.batch_size,
            flush_interval_ms = self.flush_interval.as_millis() as u64,
            "Persistence writer started"
        );

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
                debug!(
                    component = "persistence",
                    event = "persistence.flush.succeeded",
                    command_count = count,
                    "Persisted batched commands"
                );
            }
            Ok(Err(e)) => {
                error!(
                    component = "persistence",
                    event = "persistence.flush.failed",
                    error = %e,
                    "Persistence flush failed"
                );
            }
            Err(e) => {
                error!(
                    component = "persistence",
                    event = "persistence.flush.task_panicked",
                    error = %e,
                    "spawn_blocking panicked"
                );
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
            warn!(
                component = "persistence",
                event = "persistence.command.failed",
                error = %e,
                "Failed to execute persistence command"
            );
            // Continue with other commands
        }
    }

    tx.commit()?;

    Ok(count)
}

#[cfg(test)]
pub(crate) fn flush_batch_for_test(
    db_path: &PathBuf,
    batch: Vec<PersistCommand>,
) -> Result<usize, rusqlite::Error> {
    flush_batch(db_path, batch)
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
            forked_from_session_id,
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
                "INSERT INTO sessions (id, project_path, project_name, model, provider, status, work_status, codex_integration_mode, approval_policy, sandbox_mode, started_at, last_activity_at, forked_from_session_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'active', 'waiting', ?7, ?8, ?9, ?6, ?6, ?10)
                 ON CONFLICT(id) DO UPDATE SET
                   project_name = COALESCE(?3, project_name),
                   model = COALESCE(?4, model),
                   last_activity_at = ?6",
                params![id, project_path, project_name, model, provider_str, now, integration_mode, approval_policy, sandbox_mode, forked_from_session_id],
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
                MessageType::ToolResult => "tool_result",
                MessageType::Steer => "steer",
            };

            // Get next sequence number
            let seq: i64 = conn.query_row(
                "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE session_id = ?",
                params![session_id],
                |row| row.get(0),
            )?;

            conn.execute(
                "INSERT OR IGNORE INTO messages (id, session_id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_in_progress)
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

        PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, ?2),
                     attention_reason = 'none',
                     pending_tool_name = NULL,
                     pending_tool_input = NULL,
                     pending_question = NULL
                 WHERE id = ?3
                   AND (codex_integration_mode IS NULL OR codex_integration_mode != 'direct')",
                params![now, reason, thread_id],
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

        PersistCommand::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
        } => {
            conn.execute(
                "UPDATE sessions SET approval_policy = ?, sandbox_mode = ?, last_activity_at = ? WHERE id = ?",
                params![approval_policy, sandbox_mode, chrono_now(), session_id],
            )?;
        }

        PersistCommand::ReactivateSession { id } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE sessions SET status = 'active', work_status = 'waiting', ended_at = NULL, end_reason = NULL, last_activity_at = ?1 WHERE id = ?2",
                params![now, id],
            )?;
        }

        PersistCommand::ClaudeSessionUpsert {
            id,
            project_path,
            project_name,
            model,
            context_label,
            transcript_path,
            source,
            agent_type,
            permission_mode,
            terminal_session_id,
            terminal_app,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO sessions (
                    id, project_path, project_name, model, context_label, transcript_path,
                    provider, status, work_status, source, agent_type, permission_mode,
                    terminal_session_id, terminal_app, started_at, last_activity_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'claude', 'active', 'waiting', ?7, ?8, ?9, ?10, ?11, ?12, ?12)
                 ON CONFLICT(id) DO UPDATE SET
                    project_path = excluded.project_path,
                    project_name = COALESCE(excluded.project_name, sessions.project_name),
                    model = COALESCE(excluded.model, sessions.model),
                    context_label = COALESCE(excluded.context_label, sessions.context_label),
                    transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path),
                    provider = 'claude',
                    codex_integration_mode = NULL,
                    source = COALESCE(excluded.source, sessions.source),
                    agent_type = COALESCE(excluded.agent_type, sessions.agent_type),
                    permission_mode = COALESCE(excluded.permission_mode, sessions.permission_mode),
                    terminal_session_id = COALESCE(excluded.terminal_session_id, sessions.terminal_session_id),
                    terminal_app = COALESCE(excluded.terminal_app, sessions.terminal_app),
                    status = 'active',
                    last_activity_at = excluded.last_activity_at",
                params![
                    id,
                    project_path,
                    project_name,
                    model,
                    context_label,
                    transcript_path,
                    source,
                    agent_type,
                    permission_mode,
                    terminal_session_id,
                    terminal_app,
                    now,
                ],
            )?;
        }

        PersistCommand::ClaudeSessionUpdate {
            id,
            work_status,
            attention_reason,
            last_tool,
            last_tool_at,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            source,
            agent_type,
            permission_mode,
            active_subagent_id,
            active_subagent_type,
            first_prompt,
            compact_count_increment,
        } => {
            let mut updates: Vec<String> = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(ws) = work_status {
                updates.push("work_status = ?".to_string());
                params_vec.push(Box::new(ws));
            }
            if let Some(reason) = attention_reason {
                updates.push("attention_reason = ?".to_string());
                params_vec.push(Box::new(reason));
            }
            if let Some(tool) = last_tool {
                updates.push("last_tool = ?".to_string());
                params_vec.push(Box::new(tool));
            }
            if let Some(tool_at) = last_tool_at {
                updates.push("last_tool_at = ?".to_string());
                params_vec.push(Box::new(tool_at));
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
            if let Some(src) = source {
                updates.push("source = ?".to_string());
                params_vec.push(Box::new(src));
            }
            if let Some(agent) = agent_type {
                updates.push("agent_type = ?".to_string());
                params_vec.push(Box::new(agent));
            }
            if let Some(permission) = permission_mode {
                updates.push("permission_mode = ?".to_string());
                params_vec.push(Box::new(permission));
            }
            if let Some(subagent_id) = active_subagent_id {
                updates.push("active_subagent_id = ?".to_string());
                params_vec.push(Box::new(subagent_id));
            }
            if let Some(subagent_type) = active_subagent_type {
                updates.push("active_subagent_type = ?".to_string());
                params_vec.push(Box::new(subagent_type));
            }
            if let Some(prompt) = first_prompt {
                updates.push("first_prompt = COALESCE(first_prompt, ?)".to_string());
                params_vec.push(Box::new(prompt));
            }
            if compact_count_increment {
                updates.push("compact_count = COALESCE(compact_count, 0) + 1".to_string());
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

        PersistCommand::ClaudeSessionEnd { id, reason } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = ?1,
                     end_reason = COALESCE(?2, end_reason),
                     attention_reason = 'none',
                     pending_tool_name = NULL,
                     pending_tool_input = NULL,
                     pending_question = NULL,
                     active_subagent_id = NULL,
                     active_subagent_type = NULL,
                     last_activity_at = ?1
                 WHERE id = ?3",
                params![now, reason, id],
            )?;
        }

        PersistCommand::ClaudePromptIncrement { id, first_prompt } => {
            if let Some(prompt) = first_prompt {
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = COALESCE(prompt_count, 0) + 1,
                         first_prompt = COALESCE(first_prompt, ?1),
                         last_activity_at = ?2
                     WHERE id = ?3",
                    params![prompt, chrono_now(), id],
                )?;
            } else {
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = COALESCE(prompt_count, 0) + 1,
                         last_activity_at = ?1
                     WHERE id = ?2",
                    params![chrono_now(), id],
                )?;
            }
        }

        PersistCommand::ClaudeToolIncrement { id } => {
            conn.execute(
                "UPDATE sessions
                 SET tool_count = COALESCE(tool_count, 0) + 1,
                     last_activity_at = ?1
                 WHERE id = ?2",
                params![chrono_now(), id],
            )?;
        }

        PersistCommand::ClaudeSubagentStart {
            id,
            session_id,
            agent_type,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO subagents (id, session_id, agent_type, started_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(id) DO UPDATE SET
                   session_id = excluded.session_id,
                   agent_type = excluded.agent_type,
                   started_at = excluded.started_at",
                params![id, session_id, agent_type, now],
            )?;
        }

        PersistCommand::ClaudeSubagentEnd {
            id,
            transcript_path,
        } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE subagents
                 SET ended_at = ?1, transcript_path = ?2
                 WHERE id = ?3",
                params![now, transcript_path, id],
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
            if is_direct_thread_owned(conn, &id)? {
                return Ok(());
            }

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
                    status = 'active',
                    work_status = CASE
                        WHEN sessions.work_status IN ('permission', 'question', 'working') THEN sessions.work_status
                        ELSE 'waiting'
                    END,
                    ended_at = NULL,
                    end_reason = NULL,
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
            if is_direct_thread_owned(conn, &id)? {
                return Ok(());
            }

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

            // Rollout sessions are always Codex passive. Keep this authoritative so malformed
            // legacy rows self-heal even if they were originally inserted with wrong metadata.
            updates.push("provider = 'codex'".to_string());
            updates.push("codex_integration_mode = 'passive'".to_string());
            updates.push("codex_thread_id = COALESCE(codex_thread_id, id)".to_string());

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
                } else {
                    updates.push("ended_at = NULL".to_string());
                    updates.push("end_reason = NULL".to_string());
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
            if is_direct_thread_owned(conn, &id)? {
                return Ok(());
            }

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

        PersistCommand::CodexPromptIncrement { id, first_prompt } => {
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
            if is_direct_thread_owned(conn, &id)? {
                return Ok(());
            }

            conn.execute(
                "UPDATE sessions
                 SET tool_count = tool_count + 1,
                     last_activity_at = ?1
                 WHERE id = ?2",
                params![chrono_now(), id],
            )?;
        }

        PersistCommand::ApprovalRequested {
            session_id,
            request_id,
            approval_type,
            tool_name,
            command,
            file_path,
            cwd,
            proposed_amendment,
        } => {
            let approval_type_str = match approval_type {
                ApprovalType::Exec => "exec",
                ApprovalType::Patch => "patch",
                ApprovalType::Question => "question",
            };
            let proposed_amendment_json =
                proposed_amendment.and_then(|v| serde_json::to_string(&v).ok());
            let now = chrono_now();
            conn.execute(
                "INSERT INTO approval_history (
                    session_id, request_id, approval_type, tool_name, command, file_path, cwd,
                    proposed_amendment, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    session_id,
                    request_id,
                    approval_type_str,
                    tool_name,
                    command,
                    file_path,
                    cwd,
                    proposed_amendment_json,
                    now
                ],
            )?;
        }

        PersistCommand::ApprovalDecision {
            session_id,
            request_id,
            decision,
        } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE approval_history
                 SET decision = ?1, decided_at = ?2
                 WHERE id = (
                   SELECT id
                   FROM approval_history
                   WHERE session_id = ?3
                     AND request_id = ?4
                     AND decision IS NULL
                   ORDER BY id DESC
                   LIMIT 1
                 )",
                params![decision, now, session_id, request_id],
            )?;
        }
    }

    Ok(())
}

fn is_direct_thread_owned(conn: &Connection, thread_id: &str) -> Result<bool, rusqlite::Error> {
    let exists: i64 = conn.query_row(
        "SELECT EXISTS(
            SELECT 1
            FROM sessions
            WHERE codex_integration_mode = 'direct'
              AND codex_thread_id = ?1
        )",
        params![thread_id],
        |row| row.get(0),
    )?;
    Ok(exists == 1)
}

/// Check if a codex thread_id is already owned by a direct session row.
pub async fn is_direct_thread_owned_async(thread_id: &str) -> Result<bool, anyhow::Error> {
    let thread_id = thread_id.to_string();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");

    tokio::task::spawn_blocking(move || -> Result<bool, anyhow::Error> {
        if !db_path.exists() {
            return Ok(false);
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;
        Ok(is_direct_thread_owned(&conn, &thread_id)?)
    })
    .await?
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();

    // Format as ISO 8601
    let secs = duration.as_secs();
    time_to_iso8601(secs)
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
    pub provider: String,
    pub status: String,
    pub work_status: String,
    pub project_path: String,
    pub transcript_path: Option<String>,
    pub project_name: Option<String>,
    pub model: Option<String>,
    pub custom_name: Option<String>,
    pub codex_integration_mode: Option<String>,
    pub codex_thread_id: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub codex_input_tokens: i64,
    pub codex_output_tokens: i64,
    pub codex_cached_tokens: i64,
    pub codex_context_window: i64,
    pub messages: Vec<Message>,
    pub forked_from_session_id: Option<String>,
}

fn resolve_custom_name_from_first_prompt(
    conn: &Connection,
    session_id: &str,
    custom_name: Option<String>,
    first_prompt: Option<&str>,
) -> Result<Option<String>, rusqlite::Error> {
    if custom_name.is_some() {
        return Ok(custom_name);
    }

    let Some(prompt) = first_prompt else {
        return Ok(None);
    };

    let Some(derived_name) = name_from_first_prompt(prompt) else {
        return Ok(None);
    };

    conn.execute(
        "UPDATE sessions SET custom_name = ?1 WHERE id = ?2 AND custom_name IS NULL",
        params![derived_name, session_id],
    )?;

    Ok(Some(derived_name))
}

fn load_messages_from_db(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<Message>, anyhow::Error> {
    let mut msg_stmt = conn.prepare(
        "SELECT id, type, content, timestamp, tool_name, tool_input, tool_output, tool_duration, is_in_progress
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
                _ => MessageType::Assistant,
            };

            let duration_secs: Option<f64> = row.get(7)?;
            let is_error_int: i32 = row.get(8)?;

            Ok(Message {
                id: row.get(0)?,
                session_id: session_id.to_string(),
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

    Ok(messages)
}


/// A parsed item from a single JSONL entry. One entry can yield multiple items
/// (e.g. an assistant entry with both text and tool_use content blocks).
struct ParsedItem {
    message_type: MessageType,
    content: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    tool_output: Option<String>,
    /// Links tool_use → tool_result for pairing
    tool_use_id: Option<String>,
}

fn role_to_message_type(role: &str) -> MessageType {
    if role == "user" {
        MessageType::User
    } else {
        MessageType::Assistant
    }
}

/// Extract individual content items from a content array.
/// Handles text, tool_use, tool_result, and thinking blocks.
fn extract_content_items(content: &Value, role: &str) -> Vec<ParsedItem> {
    // Plain string content (Claude CLI user messages)
    if let Some(s) = content.as_str() {
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            return vec![ParsedItem {
                message_type: role_to_message_type(role),
                content: trimmed.to_string(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                tool_use_id: None,
            }];
        }
        return vec![];
    }

    let Some(array) = content.as_array() else {
        return vec![];
    };

    let mut items = Vec::new();
    let mut text_parts: Vec<String> = Vec::new();

    for item in array {
        let kind = item.get("type").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "text" | "input_text" | "output_text" | "summary_text" => {
                if let Some(text) = item.get("text").and_then(Value::as_str) {
                    let trimmed = text.trim();
                    if !trimmed.is_empty() {
                        text_parts.push(trimmed.to_string());
                    }
                }
            }
            "thinking" => {
                if let Some(text) = item.get("thinking").and_then(Value::as_str) {
                    let trimmed = text.trim();
                    if !trimmed.is_empty() {
                        items.push(ParsedItem {
                            message_type: MessageType::Thinking,
                            content: trimmed.to_string(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            tool_use_id: None,
                        });
                    }
                }
            }
            "tool_use" => {
                let name = item.get("name").and_then(Value::as_str).unwrap_or("unknown");
                let input = item.get("input").map(|v| v.to_string());
                let id = item.get("id").and_then(Value::as_str).map(String::from);
                items.push(ParsedItem {
                    message_type: MessageType::Tool,
                    content: String::new(),
                    tool_name: Some(name.to_string()),
                    tool_input: input,
                    tool_output: None,
                    tool_use_id: id,
                });
            }
            "tool_result" => {
                let output = item
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let id = item
                    .get("tool_use_id")
                    .and_then(Value::as_str)
                    .map(String::from);
                items.push(ParsedItem {
                    message_type: MessageType::Tool,
                    content: String::new(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: Some(output),
                    tool_use_id: id,
                });
            }
            _ => {}
        }
    }

    // Flush accumulated text as a single message
    if !text_parts.is_empty() {
        items.insert(
            0,
            ParsedItem {
                message_type: role_to_message_type(role),
                content: text_parts.join("\n\n"),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                tool_use_id: None,
            },
        );
    }

    items
}

/// Extract all messages from a single JSONL entry.
fn extract_entry_messages(entry: &Value) -> Vec<ParsedItem> {
    let entry_type = match entry.get("type").and_then(Value::as_str) {
        Some(t) => t,
        None => return vec![],
    };

    // New-format Codex passive: {"type": "response_item", "payload": {"type": "message", ...}}
    if entry_type == "response_item" {
        if let Some(payload) = entry.get("payload") {
            let payload_type = payload.get("type").and_then(Value::as_str).unwrap_or("");
            if payload_type == "message" {
                let role = payload
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("assistant");
                if let Some(content) = payload.get("content") {
                    return extract_content_items(content, role);
                }
            }
        }
        return vec![];
    }

    // Old-format Codex passive: {"type": "message", "role": "user", "content": [...]}
    if entry_type == "message" {
        let role = match entry.get("role").and_then(Value::as_str) {
            Some(r) => r,
            None => return vec![],
        };
        if let Some(content) = entry.get("content") {
            return extract_content_items(content, role);
        }
        return vec![];
    }

    // Claude CLI: {"type": "user"|"assistant", "message": {"role": "...", "content": ...}}
    let message = match entry.get("message") {
        Some(m) => m,
        None => return vec![],
    };
    let role = match message.get("role").and_then(Value::as_str) {
        Some(r) => r,
        None => return vec![],
    };
    let content = match message.get("content") {
        Some(c) => c,
        None => return vec![],
    };
    extract_content_items(content, role)
}

fn load_messages_from_transcript(
    transcript_path: &str,
    session_id: &str,
) -> Result<Vec<Message>, anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok(Vec::new()),
    };
    let reader = BufReader::new(file);

    let mut messages: Vec<Message> = Vec::new();
    let mut msg_counter: usize = 0;
    // Map tool_use_id → message index for pairing tool_result with its tool_use
    let mut tool_use_index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for line_result in reader.lines() {
        let line = match line_result {
            Ok(line) => line,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let value: Value = match serde_json::from_str(trimmed) {
            Ok(value) => value,
            Err(_) => continue,
        };

        let items = extract_entry_messages(&value);
        if items.is_empty() {
            continue;
        }

        let timestamp = value
            .get("timestamp")
            .and_then(Value::as_str)
            .unwrap_or("0")
            .to_string();

        for item in items {
            // tool_result: merge output into the matching tool_use message
            if item.tool_output.is_some() && item.tool_name.is_none() {
                if let Some(id) = &item.tool_use_id {
                    if let Some(&idx) = tool_use_index.get(id) {
                        messages[idx].tool_output = item.tool_output;
                        continue;
                    }
                }
            }

            let msg_idx = messages.len();
            // tool_use: register for later pairing
            if item.tool_name.is_some() {
                if let Some(id) = &item.tool_use_id {
                    tool_use_index.insert(id.clone(), msg_idx);
                }
            }

            messages.push(Message {
                id: format!("{session_id}:transcript:{msg_counter}"),
                session_id: session_id.to_string(),
                message_type: item.message_type,
                content: item.content,
                timestamp: timestamp.clone(),
                tool_name: item.tool_name,
                tool_input: item.tool_input,
                tool_output: item.tool_output,
                duration_ms: None,
                is_error: false,
            });
            msg_counter += 1;
        }
    }

    Ok(messages)
}

pub async fn load_messages_from_transcript_path(
    transcript_path: &str,
    session_id: &str,
) -> Result<Vec<Message>, anyhow::Error> {
    let transcript_path_owned = transcript_path.to_string();
    let session_id_owned = session_id.to_string();
    tokio::task::spawn_blocking(move || {
        load_messages_from_transcript(&transcript_path_owned, &session_id_owned)
    })
    .await?
}

/// Load recent sessions from the database for server restart recovery.
/// Includes ended sessions so UI history remains visible after app restart.
pub async fn load_sessions_for_startup() -> Result<Vec<RestoredSession>, anyhow::Error> {
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

        // Cleanup stale passive Codex sessions that were left active after prior crashes/restarts.
        // Keep actionable permission/question sessions alive, but end long-idle waiting/working rows.
        conn.execute(
            "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, 'startup_stale_passive')
             WHERE provider = 'codex'
               AND codex_integration_mode = 'passive'
               AND status = 'active'
               AND COALESCE(work_status, 'waiting') NOT IN ('permission', 'question')
               AND datetime(COALESCE(last_activity_at, started_at)) < datetime('now', '-15 minutes')",
            params![chrono_now()],
        )?;

        // Cleanup Claude "shell" sessions that were started but never received any
        // prompt/tool/message activity. These rows are usually created by hook
        // start events and otherwise appear as ghost active sessions after restart.
        conn.execute(
            "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, 'startup_empty_shell')
             WHERE provider = 'claude'
               AND status = 'active'
               AND COALESCE(prompt_count, 0) = 0
               AND COALESCE(tool_count, 0) = 0
               AND (first_prompt IS NULL OR trim(first_prompt) = '')
               AND (custom_name IS NULL OR trim(custom_name) = '')
               AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
            params![chrono_now()],
        )?;

        // Restore recent sessions into runtime for active + history UI continuity.
        let mut stmt = conn.prepare(
            "SELECT id, provider, status, work_status, project_path, transcript_path, project_name, model, custom_name, first_prompt, codex_integration_mode, codex_thread_id, started_at, last_activity_at, approval_policy, sandbox_mode,
                    COALESCE(codex_input_tokens, 0), COALESCE(codex_output_tokens, 0),
                    COALESCE(codex_cached_tokens, 0), COALESCE(codex_context_window, 0)
             FROM sessions
             ORDER BY
               datetime(last_activity_at) DESC,
               datetime(started_at) DESC
             LIMIT 1000"
        )?;

        #[allow(clippy::type_complexity)]
        let session_rows: Vec<(String, String, String, String, String, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, i64, i64, i64, i64)> = stmt
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
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                    row.get(14)?,
                    row.get(15)?,
                    row.get(16)?,
                    row.get(17)?,
                    row.get(18)?,
                    row.get(19)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();

        let mut sessions = Vec::new();

        for (id, provider, status, work_status, project_path, transcript_path, project_name, model, custom_name, first_prompt, codex_integration_mode, codex_thread_id, started_at, last_activity_at, approval_policy, sandbox_mode, codex_input_tokens, codex_output_tokens, codex_cached_tokens, codex_context_window) in session_rows {
            let mut messages = load_messages_from_db(&conn, &id)?;
            if messages.is_empty() {
                if let Some(path) = transcript_path.as_deref() {
                    messages = load_messages_from_transcript(path, &id)?;
                }
            }
            let custom_name = resolve_custom_name_from_first_prompt(
                &conn,
                &id,
                custom_name,
                first_prompt.as_deref(),
            )?;

            // Query fork origin separately (column may not exist on old schemas)
            let forked_from_session_id: Option<String> = conn
                .query_row(
                    "SELECT forked_from_session_id FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            sessions.push(RestoredSession {
                id,
                provider,
                status,
                work_status,
                project_path,
                transcript_path,
                project_name,
                model,
                custom_name,
                codex_integration_mode,
                codex_thread_id,
                started_at,
                last_activity_at,
                approval_policy,
                sandbox_mode,
                codex_input_tokens,
                codex_output_tokens,
                codex_cached_tokens,
                codex_context_window,
                messages,
                forked_from_session_id,
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
            "SELECT id, project_path, transcript_path, project_name, model, custom_name, first_prompt, started_at, last_activity_at, approval_policy, sandbox_mode,
                    COALESCE(codex_input_tokens, 0), COALESCE(codex_output_tokens, 0),
                    COALESCE(codex_cached_tokens, 0), COALESCE(codex_context_window, 0)
             FROM sessions
             WHERE id = ?1 AND provider = 'codex'
               AND (codex_integration_mode = 'direct' OR codex_integration_mode IS NULL)"
        )?;

        type DirectSessionRow = (
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
            i64,
            i64,
            i64,
        );

        let row: Option<DirectSessionRow> = stmt
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
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                    row.get(14)?,
                ))
            })
            .optional()?;

        let Some((id, project_path, transcript_path, project_name, model, custom_name, first_prompt, started_at, last_activity_at, approval_policy, sandbox_mode, codex_input_tokens, codex_output_tokens, codex_cached_tokens, codex_context_window)) = row else {
            return Ok(None);
        };

        let messages = load_messages_from_db(&conn, &id)?;
        let custom_name =
            resolve_custom_name_from_first_prompt(&conn, &id, custom_name, first_prompt.as_deref())?;

        Ok(Some(RestoredSession {
            id,
            provider: "codex".to_string(),
            status: "active".to_string(),
            work_status: "waiting".to_string(),
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            codex_integration_mode: Some("direct".to_string()),
            codex_thread_id: None,
            started_at,
            last_activity_at,
            approval_policy,
            sandbox_mode,
            codex_input_tokens,
            codex_output_tokens,
            codex_cached_tokens,
            codex_context_window,
            messages,
            forked_from_session_id: None, // load_session_by_id is for resume, fork origin not needed
        }))
    }).await??;

    Ok(result)
}

/// Create a sender for the persistence writer
pub fn create_persistence_channel() -> (mpsc::Sender<PersistCommand>, mpsc::Receiver<PersistCommand>)
{
    mpsc::channel(1000)
}

/// List approval history, optionally scoped to a session
pub async fn list_approvals(
    session_id: Option<String>,
    limit: Option<u32>,
) -> Result<Vec<ApprovalHistoryItem>, anyhow::Error> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");
    let limit = limit.unwrap_or(200).min(1000) as i64;

    let items = tokio::task::spawn_blocking(move || -> Result<Vec<ApprovalHistoryItem>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(Vec::new());
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'approval_history'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(Vec::new());
        }

        let mut items = Vec::new();
        if let Some(session_id) = session_id {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, request_id, approval_type, tool_name, command, file_path, cwd, decision, proposed_amendment, created_at, decided_at
                 FROM approval_history
                 WHERE session_id = ?1
                 ORDER BY id DESC
                 LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![session_id, limit], |row| {
                let approval_type_str: String = row.get(3)?;
                let approval_type = match approval_type_str.as_str() {
                    "exec" => ApprovalType::Exec,
                    "patch" => ApprovalType::Patch,
                    "question" => ApprovalType::Question,
                    _ => ApprovalType::Exec,
                };
                let proposed_json: Option<String> = row.get(9)?;
                let proposed_amendment = proposed_json
                    .as_deref()
                    .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok());
                Ok(ApprovalHistoryItem {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    request_id: row.get(2)?,
                    approval_type,
                    tool_name: row.get(4)?,
                    command: row.get(5)?,
                    file_path: row.get(6)?,
                    cwd: row.get(7)?,
                    decision: row.get(8)?,
                    proposed_amendment,
                    created_at: row.get(10)?,
                    decided_at: row.get(11)?,
                })
            })?;
            for item in rows.flatten() {
                items.push(item);
            }
        } else {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, request_id, approval_type, tool_name, command, file_path, cwd, decision, proposed_amendment, created_at, decided_at
                 FROM approval_history
                 ORDER BY id DESC
                 LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], |row| {
                let approval_type_str: String = row.get(3)?;
                let approval_type = match approval_type_str.as_str() {
                    "exec" => ApprovalType::Exec,
                    "patch" => ApprovalType::Patch,
                    "question" => ApprovalType::Question,
                    _ => ApprovalType::Exec,
                };
                let proposed_json: Option<String> = row.get(9)?;
                let proposed_amendment = proposed_json
                    .as_deref()
                    .and_then(|s| serde_json::from_str::<Vec<String>>(s).ok());
                Ok(ApprovalHistoryItem {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    request_id: row.get(2)?,
                    approval_type,
                    tool_name: row.get(4)?,
                    command: row.get(5)?,
                    file_path: row.get(6)?,
                    cwd: row.get(7)?,
                    decision: row.get(8)?,
                    proposed_amendment,
                    created_at: row.get(10)?,
                    decided_at: row.get(11)?,
                })
            })?;
            for item in rows.flatten() {
                items.push(item);
            }
        }

        Ok(items)
    })
    .await??;

    Ok(items)
}

/// Delete one approval history item
pub async fn delete_approval(approval_id: i64) -> Result<bool, anyhow::Error> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = PathBuf::from(home).join(".orbitdock/orbitdock.db");

    let deleted = tokio::task::spawn_blocking(move || -> Result<bool, anyhow::Error> {
        if !db_path.exists() {
            return Ok(false);
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;
        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'approval_history'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(false);
        }
        let rows = conn.execute(
            "DELETE FROM approval_history WHERE id = ?1",
            params![approval_id],
        )?;
        Ok(rows > 0)
    })
    .await??;

    Ok(deleted)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::await_holding_lock)]

    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};
    use uuid::Uuid;

    static TEST_ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    struct HomeGuard {
        previous: Option<String>,
    }

    impl Drop for HomeGuard {
        fn drop(&mut self) {
            if let Some(prev) = &self.previous {
                std::env::set_var("HOME", prev);
            }
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        TEST_ENV_LOCK.get_or_init(|| Mutex::new(()))
    }

    fn set_test_home(path: &Path) -> HomeGuard {
        let previous = std::env::var("HOME").ok();
        std::env::set_var("HOME", path.to_string_lossy().to_string());
        HomeGuard { previous }
    }

    fn iso_minutes_ago(minutes: u64) -> String {
        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let secs = now_secs.saturating_sub(minutes * 60);
        time_to_iso8601(secs)
    }

    fn find_migrations_dir() -> PathBuf {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        for ancestor in manifest_dir.ancestors() {
            let candidate = ancestor.join("migrations");
            if candidate.is_dir() {
                return candidate;
            }
        }
        panic!(
            "Could not locate migrations directory from {:?}",
            manifest_dir
        );
    }

    fn create_test_home() -> PathBuf {
        let home = std::env::temp_dir().join(format!("orbitdock-server-test-{}", Uuid::new_v4()));
        fs::create_dir_all(home.join(".orbitdock")).expect("create .orbitdock");
        home
    }

    fn run_all_migrations(db_path: &Path) {
        let conn = Connection::open(db_path).expect("open db");
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )
        .expect("set pragmas");

        let migrations_dir = find_migrations_dir();
        let mut files: Vec<PathBuf> = fs::read_dir(&migrations_dir)
            .expect("read migrations")
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("sql"))
            .collect();
        files.sort();

        for file in files {
            let sql = fs::read_to_string(&file).expect("read migration");
            conn.execute_batch(&sql).unwrap_or_else(|err| {
                panic!("migration failed for {}: {}", file.display(), err);
            });
        }

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                type TEXT NOT NULL,
                content TEXT,
                timestamp TEXT NOT NULL,
                sequence INTEGER NOT NULL DEFAULT 0,
                tool_name TEXT,
                tool_input TEXT,
                tool_output TEXT,
                tool_duration REAL,
                is_in_progress INTEGER NOT NULL DEFAULT 0
            );",
        )
        .expect("ensure messages table");
    }

    #[test]
    fn test_time_to_iso8601() {
        // 2024-01-15 12:30:45 UTC
        let result = time_to_iso8601(1705322445);
        assert!(result.starts_with("2024-01-15"));
    }

    #[tokio::test]
    async fn startup_restore_includes_active_and_ended_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "direct-active".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/direct-active".into(),
                    project_name: Some("direct-active".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-active".into(),
                    thread_id: "passive-active".into(),
                    project_path: "/tmp/passive-active".into(),
                    project_name: Some("passive-active".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-active.jsonl".into(),
                    started_at: "2026-02-08T00:00:00Z".into(),
                },
                PersistCommand::SessionCreate {
                    id: "direct-ended".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/direct-ended".into(),
                    project_name: Some("direct-ended".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::SessionEnd {
                    id: "direct-ended".into(),
                    reason: "test".into(),
                },
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-ended".into(),
                    thread_id: "passive-ended".into(),
                    project_path: "/tmp/passive-ended".into(),
                    project_name: Some("passive-ended".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-ended.jsonl".into(),
                    started_at: "2026-02-08T00:00:00Z".into(),
                },
                PersistCommand::RolloutSessionUpdate {
                    id: "passive-ended".into(),
                    project_path: None,
                    model: None,
                    status: Some(SessionStatus::Ended),
                    work_status: Some(WorkStatus::Ended),
                    attention_reason: None,
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                    total_tokens: None,
                    last_tool: None,
                    last_tool_at: None,
                    custom_name: None,
                },
            ],
        )
        .expect("flush batch");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let restored_ids: Vec<String> = restored.iter().map(|s| s.id.clone()).collect();

        assert!(restored_ids.iter().any(|id| id == "direct-active"));
        assert!(restored_ids.iter().any(|id| id == "passive-active"));
        assert!(restored_ids.iter().any(|id| id == "direct-ended"));
        assert!(restored_ids.iter().any(|id| id == "passive-ended"));
        assert!(restored.iter().any(|s| s.status == "active"));
        assert!(restored.iter().any(|s| s.status == "ended"));
    }

    #[tokio::test]
    async fn startup_restore_keeps_recent_passive_active_and_ends_stale_passive() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-recent".into(),
                    thread_id: "passive-recent".into(),
                    project_path: "/tmp/passive-recent".into(),
                    project_name: Some("passive-recent".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-recent.jsonl".into(),
                    started_at: iso_minutes_ago(2),
                },
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-stale".into(),
                    thread_id: "passive-stale".into(),
                    project_path: "/tmp/passive-stale".into(),
                    project_name: Some("passive-stale".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-stale.jsonl".into(),
                    started_at: iso_minutes_ago(30),
                },
                PersistCommand::SessionUpdate {
                    id: "passive-recent".into(),
                    status: Some(SessionStatus::Active),
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(iso_minutes_ago(2)),
                },
                PersistCommand::SessionUpdate {
                    id: "passive-stale".into(),
                    status: Some(SessionStatus::Active),
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(iso_minutes_ago(30)),
                },
            ],
        )
        .expect("flush startup sessions");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let recent = restored
            .iter()
            .find(|s| s.id == "passive-recent")
            .expect("recent passive session should be restored");
        let stale = restored
            .iter()
            .find(|s| s.id == "passive-stale")
            .expect("stale passive session should be restored");

        assert_eq!(recent.status, "active");
        assert_eq!(recent.work_status, "waiting");
        assert_eq!(stale.status, "ended");
        assert_eq!(stale.work_status, "ended");

        let conn = Connection::open(&db_path).expect("open db");
        let stale_reason: Option<String> = conn
            .query_row(
                "SELECT end_reason FROM sessions WHERE id = ?1",
                params!["passive-stale"],
                |row| row.get(0),
            )
            .expect("query stale end_reason");
        assert_eq!(stale_reason.as_deref(), Some("startup_stale_passive"));
    }

    #[tokio::test]
    async fn stale_passive_ends_on_startup_then_reactivates_on_live_activity_across_restarts() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-restart-live".into(),
                    thread_id: "passive-restart-live".into(),
                    project_path: "/tmp/passive-restart-live".into(),
                    project_name: Some("passive-restart-live".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-restart-live.jsonl".into(),
                    started_at: iso_minutes_ago(30),
                },
                PersistCommand::SessionUpdate {
                    id: "passive-restart-live".into(),
                    status: Some(SessionStatus::Active),
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(iso_minutes_ago(30)),
                },
            ],
        )
        .expect("seed stale passive session");

        let first_restore = load_sessions_for_startup()
            .await
            .expect("first startup restore");
        let first = first_restore
            .iter()
            .find(|s| s.id == "passive-restart-live")
            .expect("stale session should exist after first restore");
        assert_eq!(first.status, "ended");
        assert_eq!(first.work_status, "ended");

        flush_batch(
            &db_path,
            vec![PersistCommand::RolloutSessionUpdate {
                id: "passive-restart-live".into(),
                project_path: None,
                model: None,
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                attention_reason: Some(Some("awaitingReply".into())),
                pending_tool_name: Some(None),
                pending_tool_input: Some(None),
                pending_question: Some(None),
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: None,
            }],
        )
        .expect("apply live rollout activity");

        let second_restore = load_sessions_for_startup()
            .await
            .expect("second startup restore");
        let second = second_restore
            .iter()
            .find(|s| s.id == "passive-restart-live")
            .expect("reactivated session should exist after second restore");
        assert_eq!(second.status, "active");
        assert_eq!(second.work_status, "waiting");

        let conn = Connection::open(&db_path).expect("open db");
        let (status, work_status, end_reason): (String, String, Option<String>) = conn
            .query_row(
                "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
                params!["passive-restart-live"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("query reactivated row");
        assert_eq!(status, "active");
        assert_eq!(work_status, "waiting");
        assert!(
            end_reason.is_none(),
            "end_reason should be cleared after live reactivation"
        );
    }

    #[tokio::test]
    async fn startup_ends_empty_active_claude_shell_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                // Ghost shell: start event only, no prompt/tool/message activity.
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-shell".into(),
                    project_path: "/tmp/claude-shell".into(),
                    project_name: Some("claude-shell".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-shell.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                },
                // Real session: has first prompt and should remain active.
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-real".into(),
                    project_path: "/tmp/claude-real".into(),
                    project_name: Some("claude-real".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-real.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                },
                PersistCommand::ClaudePromptIncrement {
                    id: "claude-real".into(),
                    first_prompt: Some("Ship the fix".into()),
                },
            ],
        )
        .expect("flush batch");

        let _ = load_sessions_for_startup().await.expect("load sessions");

        let conn = Connection::open(&db_path).expect("open db");
        let shell_status: (String, String, Option<String>) = conn
            .query_row(
                "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
                params!["claude-shell"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("query shell row");
        assert_eq!(shell_status.0, "ended");
        assert_eq!(shell_status.1, "ended");
        assert_eq!(shell_status.2.as_deref(), Some("startup_empty_shell"));

        let real_status: String = conn
            .query_row(
                "SELECT status FROM sessions WHERE id = ?1",
                params!["claude-real"],
                |row| row.get(0),
            )
            .expect("query real row");
        assert_eq!(real_status, "active");
    }

    #[tokio::test]
    async fn rollout_upsert_does_not_convert_direct_session_to_passive() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "shared-thread".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/direct".into(),
                    project_name: Some("direct".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::SetThreadId {
                    session_id: "shared-thread".into(),
                    thread_id: "shared-thread".into(),
                },
                PersistCommand::RolloutSessionUpsert {
                    id: "shared-thread".into(),
                    thread_id: "shared-thread".into(),
                    project_path: "/tmp/passive".into(),
                    project_name: Some("passive".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive.jsonl".into(),
                    started_at: "2026-02-08T00:00:00Z".into(),
                },
            ],
        )
        .expect("flush batch");

        let conn = Connection::open(&db_path).expect("open db");
        let (provider, mode, project_path): (String, Option<String>, String) = conn
            .query_row(
                "SELECT provider, codex_integration_mode, project_path FROM sessions WHERE id = ?1",
                params!["shared-thread"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("query session");

        assert_eq!(provider, "codex");
        assert_eq!(mode.as_deref(), Some("direct"));
        assert_eq!(project_path, "/tmp/direct");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let direct = restored
            .iter()
            .find(|s| s.id == "shared-thread")
            .expect("direct session restored");
        assert_eq!(direct.codex_integration_mode.as_deref(), Some("direct"));
    }

    #[tokio::test]
    async fn rollout_activity_reactivates_timed_out_passive_session() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        // Create a passive rollout-backed session and mark it ended (timeout path).
        flush_batch(
            &db_path,
            vec![
                PersistCommand::RolloutSessionUpsert {
                    id: "passive-timeout".into(),
                    thread_id: "passive-timeout".into(),
                    project_path: "/tmp/passive-timeout".into(),
                    project_name: Some("passive-timeout".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    context_label: Some("codex_cli_rs".into()),
                    transcript_path: "/tmp/passive-timeout.jsonl".into(),
                    started_at: "2026-02-08T00:00:00Z".into(),
                },
                PersistCommand::SessionEnd {
                    id: "passive-timeout".into(),
                    reason: "timeout".into(),
                },
            ],
        )
        .expect("flush ended session");

        // A new rollout event should reactivate the session and clear ended markers.
        flush_batch(
            &db_path,
            vec![PersistCommand::RolloutSessionUpdate {
                id: "passive-timeout".into(),
                project_path: None,
                model: None,
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                attention_reason: Some(Some("awaitingReply".into())),
                pending_tool_name: Some(None),
                pending_tool_input: Some(None),
                pending_question: Some(None),
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: None,
            }],
        )
        .expect("flush reactivation");

        let conn = Connection::open(&db_path).expect("open db");
        let (status, work_status, ended_at, end_reason): (
            String,
            String,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "SELECT status, work_status, ended_at, end_reason
                 FROM sessions
                 WHERE id = ?1",
                params!["passive-timeout"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("query session");

        assert_eq!(status, "active");
        assert_eq!(work_status, "waiting");
        assert!(
            ended_at.is_none(),
            "ended_at should be cleared on reactivation"
        );
        assert!(
            end_reason.is_none(),
            "end_reason should be cleared on reactivation"
        );
    }

    #[tokio::test]
    async fn startup_backfills_custom_name_from_first_prompt_for_claude_and_codex() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-1".into(),
                    project_path: "/tmp/claude".into(),
                    project_name: Some("claude".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-1.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                },
                PersistCommand::ClaudePromptIncrement {
                    id: "claude-1".into(),
                    first_prompt: Some("Investigate flaky CI and propose fixes".into()),
                },
                PersistCommand::SessionCreate {
                    id: "codex-1".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/codex".into(),
                    project_name: Some("codex".into()),
                    model: Some("gpt-5-codex".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::CodexPromptIncrement {
                    id: "codex-1".into(),
                    first_prompt: Some("Refactor flaky test setup".into()),
                },
            ],
        )
        .expect("flush batch");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let session = restored
            .iter()
            .find(|s| s.id == "claude-1")
            .expect("claude session restored");
        assert_eq!(
            session.custom_name.as_deref(),
            Some("Investigate flaky CI and propose fixes")
        );

        let codex_session = restored
            .iter()
            .find(|s| s.id == "codex-1")
            .expect("codex session restored");
        assert_eq!(
            codex_session.custom_name.as_deref(),
            Some("Refactor flaky test setup")
        );
    }

    #[tokio::test]
    async fn startup_restore_hydrates_claude_messages_from_transcript_when_db_messages_missing() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        let transcript_path = home.join("claude-hydrate.jsonl");
        fs::write(
            &transcript_path,
            r#"{"type":"user","timestamp":"2026-02-10T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Hello from transcript"}]}}
{"type":"assistant","timestamp":"2026-02-10T01:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Server hydration works"}]}}
"#,
        )
        .expect("write transcript");

        flush_batch(
            &db_path,
            vec![
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-hydrate".into(),
                    project_path: "/tmp/claude-hydrate".into(),
                    project_name: Some("claude-hydrate".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some(transcript_path.to_string_lossy().to_string()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                },
                PersistCommand::ClaudePromptIncrement {
                    id: "claude-hydrate".into(),
                    first_prompt: Some("Hello from transcript".into()),
                },
            ],
        )
        .expect("flush claude seed");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let session = restored
            .iter()
            .find(|s| s.id == "claude-hydrate")
            .expect("claude session restored");

        assert!(
            !session.messages.is_empty(),
            "expected transcript-backed message hydration"
        );
        assert!(session
            .messages
            .iter()
            .any(|m| m.content.contains("Hello from transcript")));
    }

    #[tokio::test]
    async fn startup_restore_hydrates_codex_messages_from_input_text_transcript_items() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _home_guard = set_test_home(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        let transcript_path = home.join("codex-input-text.jsonl");
        fs::write(
            &transcript_path,
            r#"{"type":"response_item","timestamp":"2026-02-10T01:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"User says hello"}]}}
{"type":"response_item","timestamp":"2026-02-10T01:00:01Z","payload":{"type":"message","role":"assistant","content":[{"type":"input_text","text":"Assistant replies"}]}}
"#,
        )
        .expect("write codex transcript");

        flush_batch(
            &db_path,
            vec![PersistCommand::RolloutSessionUpsert {
                id: "codex-input-text".into(),
                thread_id: "codex-input-text".into(),
                project_path: "/tmp/codex-input-text".into(),
                project_name: Some("codex-input-text".into()),
                branch: Some("main".into()),
                model: Some("gpt-5-codex".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: transcript_path.to_string_lossy().to_string(),
                started_at: iso_minutes_ago(1),
            }],
        )
        .expect("seed codex passive session");

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let session = restored
            .iter()
            .find(|s| s.id == "codex-input-text")
            .expect("codex session restored");

        assert!(session
            .messages
            .iter()
            .any(|m| m.content.contains("User says hello")));
        assert!(session
            .messages
            .iter()
            .any(|m| m.content.contains("Assistant replies")));
    }
}
