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
    TokenUsageSnapshotKind, WorkStatus,
};

/// Commands that can be persisted
#[derive(Debug, Clone)]
pub enum PersistCommand {
    /// Create a new session
    SessionCreate {
        id: String,
        provider: Provider,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        permission_mode: Option<String>,
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
        is_in_progress: Option<bool>,
    },

    /// Update token usage
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
        snapshot_kind: TokenUsageSnapshotKind,
    },

    /// Update diff/plan for session
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },

    /// Persist a per-turn diff snapshot
    TurnDiffInsert {
        session_id: String,
        turn_id: String,
        turn_seq: u64,
        diff: String,
        input_tokens: u64,
        output_tokens: u64,
        cached_tokens: u64,
        context_window: u64,
        snapshot_kind: TokenUsageSnapshotKind,
    },

    /// Store codex-core thread ID for a session
    SetThreadId {
        session_id: String,
        thread_id: String,
    },

    /// End any non-direct session row that accidentally uses a direct thread id as session id
    CleanupThreadShadowSession { thread_id: String, reason: String },

    /// Store Claude SDK session ID for a direct Claude session
    SetClaudeSdkSessionId {
        session_id: String,
        claude_sdk_session_id: String,
    },

    /// End the hook-created shadow row for a managed Claude direct session
    CleanupClaudeShadowSession {
        claude_sdk_session_id: String,
        reason: String,
    },

    /// Set custom name for a session
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },

    /// Set AI-generated summary for a session
    SetSummary { session_id: String, summary: String },

    /// Persist session autonomy configuration
    SetSessionConfig {
        session_id: String,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        permission_mode: Option<String>,
    },

    /// Mark messages as read up to a given sequence number
    MarkSessionRead {
        session_id: String,
        up_to_sequence: i64,
    },

    /// Reactivate an ended session (for resume)
    ReactivateSession { id: String },

    /// Upsert a Claude hook-backed session
    ClaudeSessionUpsert {
        id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: Option<String>,
        source: Option<String>,
        agent_type: Option<String>,
        permission_mode: Option<String>,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
        forked_from_session_id: Option<String>,
        repository_root: Option<String>,
        is_worktree: bool,
        git_sha: Option<String>,
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

    /// Increment tool counter for any direct session (transition-driven)
    ToolCountIncrement { session_id: String },

    /// Update model name for a session
    ModelUpdate { session_id: String, model: String },

    /// Update effort level for a session
    EffortUpdate {
        session_id: String,
        effort: Option<String>,
    },

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

    /// Create a review comment
    ReviewCommentCreate {
        id: String,
        session_id: String,
        turn_id: Option<String>,
        file_path: String,
        line_start: u32,
        line_end: Option<u32>,
        body: String,
        tag: Option<String>,
    },

    /// Update a review comment
    ReviewCommentUpdate {
        id: String,
        body: Option<String>,
        tag: Option<String>,
        status: Option<String>,
    },

    /// Delete a review comment
    ReviewCommentDelete { id: String },

    /// Update integration mode for a session (takeover: passive → direct)
    SetIntegrationMode {
        session_id: String,
        codex_mode: Option<String>,
        claude_mode: Option<String>,
    },

    /// Update environment info (cwd, git branch, git sha, worktree)
    EnvironmentUpdate {
        session_id: String,
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        repository_root: Option<String>,
        is_worktree: Option<bool>,
    },

    /// Upsert a key-value config entry
    SetConfig { key: String, value: String },

    /// Replace all cached Claude models
    SaveClaudeModels {
        models: Vec<orbitdock_protocol::ClaudeModelOption>,
    },

    /// Insert a single Claude model if it doesn't already exist.
    /// Preserves richer metadata from direct connector sessions.
    UpsertClaudeModelIfAbsent { value: String, display_name: String },

    /// Persist a new worktree row
    WorktreeCreate {
        id: String,
        repo_root: String,
        worktree_path: String,
        branch: String,
        base_branch: Option<String>,
        created_by: String,
    },

    /// Update worktree lifecycle status
    WorktreeUpdateStatus {
        id: String,
        status: String,
        last_session_ended_at: Option<String>,
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
        let db_path = crate::paths::db_path();

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
            branch,
            model,
            approval_policy,
            sandbox_mode,
            permission_mode,
            forked_from_session_id,
        } => {
            let provider_str = match provider {
                Provider::Claude => "claude",
                Provider::Codex => "codex",
            };

            let now = chrono_now();
            let codex_integration_mode: Option<&str> = match provider {
                Provider::Codex => Some("direct"),
                Provider::Claude => None,
            };
            let claude_integration_mode: Option<&str> = match provider {
                Provider::Claude => Some("direct"),
                Provider::Codex => None,
            };

            conn.execute(
                "INSERT INTO sessions (id, project_path, project_name, branch, model, provider, status, work_status, codex_integration_mode, claude_integration_mode, approval_policy, sandbox_mode, permission_mode, started_at, last_activity_at, forked_from_session_id)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', 'waiting', ?8, ?12, ?9, ?10, ?13, ?7, ?7, ?11)
                 ON CONFLICT(id) DO UPDATE SET
                   project_name = COALESCE(?3, project_name),
                   branch = COALESCE(?4, branch),
                   model = COALESCE(?5, model),
                   last_activity_at = ?7",
                params![id, project_path, project_name, branch, model, provider_str, now, codex_integration_mode, approval_policy, sandbox_mode, forked_from_session_id, claude_integration_mode, permission_mode],
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

            // When work_status transitions away from permission/question, clear stale
            // pending state that may have been written by the hook path. Without this,
            // a Claude process crash (no Stop hook) leaves the DB with work_status=waiting
            // but pending_tool_name/attention_reason still set from the PermissionRequest hook.
            let clears_pending = matches!(
                work_status,
                Some(WorkStatus::Working)
                    | Some(WorkStatus::Waiting)
                    | Some(WorkStatus::Reply)
                    | Some(WorkStatus::Ended)
            );

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

            // If the session moved out of an approval/question state without explicit
            // per-request decisions, close any orphaned unresolved approval rows so replay
            // does not resurrect stale approval cards.
            if clears_pending {
                let now = chrono_now();
                conn.execute(
                    "UPDATE approval_history
                     SET decision = 'abort',
                         decided_at = COALESCE(decided_at, ?1)
                     WHERE session_id = ?2
                       AND decision IS NULL",
                    params![now, id],
                )?;
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
                MessageType::Shell => "shell",
            };

            // Get next sequence number
            let seq: i64 = conn.query_row(
                "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE session_id = ?",
                params![session_id],
                |row| row.get(0),
            )?;

            let images_json: Option<String> = if message.images.is_empty() {
                None
            } else {
                serde_json::to_string(&message.images).ok()
            };

            conn.execute(
                "INSERT OR IGNORE INTO messages (id, session_id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
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
                    if message.is_in_progress { 1 } else { 0 },
                    images_json,
                ],
            )?;

            // Update last_message on the session for dashboard context lines.
            // Ignore in-progress assistant deltas to avoid single-token summaries.
            if matches!(
                message.message_type,
                MessageType::User | MessageType::Assistant
            ) && !message.is_in_progress
            {
                let truncated: String = message.content.chars().take(200).collect();
                let _ = conn.execute(
                    "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
                    params![truncated, session_id],
                );
            }

            // Increment cached unread count for non-user, non-steer messages
            if !matches!(message.message_type, MessageType::User | MessageType::Steer) {
                let _ = conn.execute(
                    "UPDATE sessions SET unread_count = unread_count + 1 WHERE id = ?1",
                    params![session_id],
                );
            }
        }

        PersistCommand::MessageUpdate {
            session_id,
            message_id,
            content,
            tool_output,
            duration_ms,
            is_error,
            is_in_progress,
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
                updates.push("is_error = ?");
                params_vec.push(Box::new(if e { 1 } else { 0 }));
            }
            if let Some(in_progress) = is_in_progress {
                updates.push("is_in_progress = ?");
                params_vec.push(Box::new(if in_progress { 1 } else { 0 }));
            }

            if !updates.is_empty() {
                let sql = format!(
                    "UPDATE messages SET {} WHERE id = ? AND session_id = ?",
                    updates.join(", ")
                );
                params_vec.push(Box::new(message_id.clone()));
                params_vec.push(Box::new(session_id.clone()));

                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|b| b.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }

            // Keep sessions.last_message aligned to completed conversation messages.
            // We intentionally skip in-progress assistant deltas to avoid noisy one-char lines.
            let candidate: Option<String> = conn
                .query_row(
                    "SELECT type, content, is_in_progress FROM messages WHERE id = ?1 AND session_id = ?2",
                    params![message_id, session_id],
                    |row| {
                        let message_type: String = row.get(0)?;
                        let content: Option<String> = row.get(1)?;
                        let is_in_progress: i64 = row.get(2)?;
                        Ok((message_type, content, is_in_progress))
                    },
                )
                .optional()?
                .and_then(|(message_type, content, is_in_progress)| {
                    if (message_type == "user" || message_type == "assistant") && is_in_progress == 0 {
                        content
                    } else {
                        None
                    }
                });

            if let Some(content) = candidate {
                let truncated: String = content.chars().take(200).collect();
                let _ = conn.execute(
                    "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
                    params![truncated, session_id],
                );
            }
        }

        PersistCommand::TokensUpdate {
            session_id,
            usage,
            snapshot_kind,
        } => {
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
                    chrono_now(),
                    session_id,
                ],
            )?;

            persist_usage_event(conn, &session_id, &usage, snapshot_kind)?;
            upsert_usage_session_state(conn, &session_id, &usage, snapshot_kind)?;
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

        PersistCommand::TurnDiffInsert {
            session_id,
            turn_id,
            turn_seq,
            diff,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            snapshot_kind,
        } => {
            conn.execute(
                "INSERT OR REPLACE INTO turn_diffs (session_id, turn_id, diff, input_tokens, output_tokens, cached_tokens, context_window) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![session_id, turn_id, diff, input_tokens as i64, output_tokens as i64, cached_tokens as i64, context_window as i64],
            )?;

            upsert_usage_turn_snapshot(
                conn,
                &session_id,
                &turn_id,
                turn_seq,
                input_tokens,
                output_tokens,
                cached_tokens,
                context_window,
                snapshot_kind,
            )?;
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
                     pending_question = NULL,
                     pending_approval_id = NULL
                 WHERE id = ?3
                   AND (codex_integration_mode IS NULL OR codex_integration_mode != 'direct')",
                params![now, reason, thread_id],
            )?;
        }

        PersistCommand::SetClaudeSdkSessionId {
            session_id,
            claude_sdk_session_id,
        } => {
            conn.execute(
                "UPDATE sessions SET claude_sdk_session_id = ? WHERE id = ?",
                params![claude_sdk_session_id, session_id],
            )?;
        }

        PersistCommand::CleanupClaudeShadowSession {
            claude_sdk_session_id,
            reason,
        } => {
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
                     pending_question = NULL,
                     pending_approval_id = NULL
                 WHERE id = ?3
                   AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')",
                params![now, reason, claude_sdk_session_id],
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

        PersistCommand::SetSummary {
            session_id,
            summary,
        } => {
            conn.execute(
                "UPDATE sessions SET summary = ?, last_activity_at = ? WHERE id = ?",
                params![summary, chrono_now(), session_id],
            )?;
        }

        PersistCommand::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
            permission_mode,
        } => {
            conn.execute(
                "UPDATE sessions SET approval_policy = COALESCE(?, approval_policy), sandbox_mode = COALESCE(?, sandbox_mode), permission_mode = COALESCE(?, permission_mode), last_activity_at = ? WHERE id = ?",
                params![approval_policy, sandbox_mode, permission_mode, chrono_now(), session_id],
            )?;
        }

        PersistCommand::MarkSessionRead {
            session_id,
            up_to_sequence,
        } => {
            conn.execute(
                "UPDATE sessions SET last_read_sequence = MAX(last_read_sequence, ?1), unread_count = (
                    SELECT COUNT(*) FROM messages
                    WHERE session_id = ?2
                      AND sequence > ?1
                      AND type NOT IN ('user', 'steer')
                ) WHERE id = ?2",
                params![up_to_sequence, session_id],
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
            branch,
            model,
            context_label,
            transcript_path,
            source,
            agent_type,
            permission_mode,
            terminal_session_id,
            terminal_app,
            forked_from_session_id,
            repository_root,
            is_worktree,
            git_sha,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO sessions (
                    id, project_path, project_name, branch, model, context_label, transcript_path,
                    provider, status, work_status, source, agent_type, permission_mode,
                    claude_integration_mode, terminal_session_id, terminal_app,
                    started_at, last_activity_at, forked_from_session_id,
                    repository_root, is_worktree, git_sha
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'claude', 'active', 'waiting', ?8, ?9, ?10, 'passive', ?11, ?12, ?13, ?13, ?14, ?15, ?16, ?17)
                 ON CONFLICT(id) DO UPDATE SET
                    project_path = excluded.project_path,
                    project_name = COALESCE(excluded.project_name, sessions.project_name),
                    branch = COALESCE(excluded.branch, sessions.branch),
                    model = COALESCE(excluded.model, sessions.model),
                    context_label = COALESCE(excluded.context_label, sessions.context_label),
                    transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path),
                    provider = 'claude',
                    codex_integration_mode = NULL,
                    claude_integration_mode = COALESCE(sessions.claude_integration_mode, 'passive'),
                    source = COALESCE(excluded.source, sessions.source),
                    agent_type = COALESCE(excluded.agent_type, sessions.agent_type),
                    permission_mode = COALESCE(excluded.permission_mode, sessions.permission_mode),
                    terminal_session_id = COALESCE(excluded.terminal_session_id, sessions.terminal_session_id),
                    terminal_app = COALESCE(excluded.terminal_app, sessions.terminal_app),
                    forked_from_session_id = COALESCE(excluded.forked_from_session_id, sessions.forked_from_session_id),
                    repository_root = COALESCE(excluded.repository_root, sessions.repository_root),
                    is_worktree = excluded.is_worktree,
                    git_sha = COALESCE(excluded.git_sha, sessions.git_sha),
                    status = 'active',
                    last_activity_at = excluded.last_activity_at",
                params![
                    id,
                    project_path,
                    project_name,
                    branch,
                    model,
                    context_label,
                    transcript_path,
                    source,
                    agent_type,
                    permission_mode,
                    terminal_session_id,
                    terminal_app,
                    now,
                    forked_from_session_id,
                    repository_root,
                    is_worktree as i32,
                    git_sha,
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
            let has_attention_reason = attention_reason.is_some();
            let clears_pending = matches!(
                work_status.as_deref(),
                Some("working") | Some("waiting") | Some("reply") | Some("ended")
            );

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
            if clears_pending {
                updates.push("pending_tool_name = NULL".to_string());
                updates.push("pending_tool_input = NULL".to_string());
                updates.push("pending_question = NULL".to_string());
                updates.push("pending_approval_id = NULL".to_string());
                if !has_attention_reason {
                    updates.push(
                        "attention_reason = CASE \
                            WHEN attention_reason IN ('awaitingPermission', 'awaitingQuestion') THEN 'awaitingReply' \
                            ELSE attention_reason \
                         END"
                            .to_string(),
                    );
                }
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
                params_vec.push(Box::new(id.clone()));

                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|b| b.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }

            if clears_pending {
                let now = chrono_now();
                conn.execute(
                    "UPDATE approval_history
                     SET decision = 'abort',
                         decided_at = COALESCE(decided_at, ?1)
                     WHERE session_id = ?2
                       AND decision IS NULL",
                    params![now, id],
                )?;
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
                     pending_approval_id = NULL,
                     active_subagent_id = NULL,
                     active_subagent_type = NULL,
                     last_activity_at = ?1
                 WHERE id = ?3",
                params![now, reason, id],
            )?;
        }

        PersistCommand::ClaudePromptIncrement { id, first_prompt } => {
            if let Some(ref prompt) = first_prompt {
                let truncated: String = prompt.chars().take(200).collect();
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = COALESCE(prompt_count, 0) + 1,
                         first_prompt = COALESCE(first_prompt, ?1),
                         last_message = ?1,
                         last_activity_at = ?2
                     WHERE id = ?3",
                    params![truncated, chrono_now(), id],
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

        PersistCommand::ToolCountIncrement { session_id } => {
            conn.execute(
                "UPDATE sessions
                 SET tool_count = COALESCE(tool_count, 0) + 1,
                     last_activity_at = ?1
                 WHERE id = ?2",
                params![chrono_now(), session_id],
            )?;
        }

        PersistCommand::ModelUpdate { session_id, model } => {
            conn.execute(
                "UPDATE sessions SET model = ?1 WHERE id = ?2",
                params![model, session_id],
            )?;
        }

        PersistCommand::EffortUpdate { session_id, effort } => {
            conn.execute(
                "UPDATE sessions SET effort = ?1 WHERE id = ?2",
                params![effort, session_id],
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

            if let Some(ref prompt) = first_prompt {
                let truncated: String = prompt.chars().take(200).collect();
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = prompt_count + 1,
                         first_prompt = COALESCE(first_prompt, ?1),
                         last_message = ?1,
                         last_activity_at = ?2
                     WHERE id = ?3",
                    params![truncated, chrono_now(), id],
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
            if let Some(ref prompt) = first_prompt {
                let truncated: String = prompt.chars().take(200).collect();
                conn.execute(
                    "UPDATE sessions
                     SET prompt_count = prompt_count + 1,
                         first_prompt = COALESCE(first_prompt, ?1),
                         last_message = ?1,
                         last_activity_at = ?2
                     WHERE id = ?3",
                    params![truncated, chrono_now(), id],
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
            let updated = conn.execute(
                "UPDATE approval_history
                 SET approval_type = ?1,
                     tool_name = ?2,
                     command = ?3,
                     file_path = ?4,
                     cwd = ?5,
                     proposed_amendment = ?6
                 WHERE session_id = ?7
                   AND request_id = ?8
                   AND decision IS NULL",
                params![
                    approval_type_str,
                    tool_name.as_deref(),
                    command.as_deref(),
                    file_path.as_deref(),
                    cwd.as_deref(),
                    proposed_amendment_json.as_deref(),
                    &session_id,
                    &request_id
                ],
            )?;
            if updated == 0 {
                conn.execute(
                    "INSERT INTO approval_history (
                        session_id, request_id, approval_type, tool_name, command, file_path, cwd,
                        proposed_amendment, created_at
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    params![
                        &session_id,
                        &request_id,
                        approval_type_str,
                        tool_name.as_deref(),
                        command.as_deref(),
                        file_path.as_deref(),
                        cwd.as_deref(),
                        proposed_amendment_json.as_deref(),
                        now
                    ],
                )?;
            }
            // Keep session pending_approval_id aligned to the queue head (oldest unresolved)
            // and atomically increment approval_version.
            conn.execute(
                "UPDATE sessions
                 SET pending_approval_id = (
                    SELECT ah.request_id
                    FROM approval_history ah
                    WHERE ah.session_id = ?1
                      AND ah.decision IS NULL
                      AND ah.id > COALESCE(
                        (
                            SELECT MAX(resolved.id)
                            FROM approval_history resolved
                            WHERE resolved.session_id = ah.session_id
                              AND resolved.request_id = ah.request_id
                              AND resolved.decision IS NOT NULL
                        ),
                        0
                      )
                    ORDER BY ah.id ASC
                    LIMIT 1
                 ),
                 approval_version = approval_version + 1
                 WHERE id = ?1",
                params![session_id],
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
                 WHERE session_id = ?3
                   AND request_id = ?4
                   AND decision IS NULL",
                params![decision, now, session_id, request_id],
            )?;
            // Recompute the queue head after each decision and atomically increment approval_version.
            conn.execute(
                "UPDATE sessions
                 SET pending_approval_id = (
                    SELECT ah.request_id
                    FROM approval_history ah
                    WHERE ah.session_id = ?1
                      AND ah.decision IS NULL
                      AND ah.id > COALESCE(
                        (
                            SELECT MAX(resolved.id)
                            FROM approval_history resolved
                            WHERE resolved.session_id = ah.session_id
                              AND resolved.request_id = ah.request_id
                              AND resolved.decision IS NOT NULL
                        ),
                        0
                      )
                    ORDER BY ah.id ASC
                    LIMIT 1
                 ),
                 approval_version = approval_version + 1
                 WHERE id = ?1",
                params![session_id],
            )?;
        }

        PersistCommand::ReviewCommentCreate {
            id,
            session_id,
            turn_id,
            file_path,
            line_start,
            line_end,
            body,
            tag,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO review_comments (id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'open', ?9)",
                params![id, session_id, turn_id, file_path, line_start, line_end, body, tag, now],
            )?;
        }

        PersistCommand::ReviewCommentUpdate {
            id,
            body,
            tag,
            status,
        } => {
            let now = chrono_now();
            let mut updates = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(b) = body {
                updates.push("body = ?");
                params_vec.push(Box::new(b));
            }
            if let Some(t) = tag {
                updates.push("tag = ?");
                params_vec.push(Box::new(t));
            }
            if let Some(s) = status {
                updates.push("status = ?");
                params_vec.push(Box::new(s));
            }

            if !updates.is_empty() {
                updates.push("updated_at = ?");
                params_vec.push(Box::new(now));

                let sql = format!(
                    "UPDATE review_comments SET {} WHERE id = ?",
                    updates.join(", ")
                );
                params_vec.push(Box::new(id));

                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|p| p.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
        }

        PersistCommand::ReviewCommentDelete { id } => {
            conn.execute("DELETE FROM review_comments WHERE id = ?1", params![id])?;
        }

        PersistCommand::SetIntegrationMode {
            session_id,
            codex_mode,
            claude_mode,
        } => {
            let mut updates = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(m) = codex_mode {
                updates.push("codex_integration_mode = ?");
                params_vec.push(Box::new(m));
            }
            if let Some(m) = claude_mode {
                updates.push("claude_integration_mode = ?");
                params_vec.push(Box::new(m));
            }

            if !updates.is_empty() {
                params_vec.push(Box::new(session_id));
                let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|p| p.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
        }

        PersistCommand::EnvironmentUpdate {
            session_id,
            cwd,
            git_branch,
            git_sha,
            repository_root,
            is_worktree,
        } => {
            let mut updates = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(ref c) = cwd {
                updates.push("current_cwd = ?");
                params_vec.push(Box::new(c.clone()));
            }
            if let Some(b) = git_branch {
                updates.push("git_branch = ?");
                params_vec.push(Box::new(b));
            }
            if let Some(s) = git_sha {
                updates.push("git_sha = ?");
                params_vec.push(Box::new(s));
            }
            if let Some(r) = repository_root {
                updates.push("repository_root = ?");
                params_vec.push(Box::new(r));
            }
            if let Some(w) = is_worktree {
                updates.push("is_worktree = ?");
                params_vec.push(Box::new(w as i32));

                // Auto-wire worktree_id: if this is a worktree, look up by cwd
                if w {
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
                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|p| p.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
        }

        PersistCommand::SetConfig { key, value } => {
            let stored_value = crate::crypto::encrypt(&value);
            conn.execute(
                "INSERT INTO config (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, stored_value],
            )?;
        }

        PersistCommand::SaveClaudeModels { models } => {
            conn.execute("DELETE FROM claude_models", [])?;
            let mut stmt = conn.prepare(
                "INSERT INTO claude_models (value, display_name, description, updated_at)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            let now = chrono_now();
            for m in models {
                stmt.execute(params![m.value, m.display_name, m.description, now])?;
            }
        }

        PersistCommand::UpsertClaudeModelIfAbsent {
            value,
            display_name,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO claude_models (value, display_name, description, updated_at)
                 VALUES (?1, ?2, '', ?3)
                 ON CONFLICT(value) DO NOTHING",
                params![value, display_name, now],
            )?;
        }

        PersistCommand::WorktreeCreate {
            id,
            repo_root,
            worktree_path,
            branch,
            base_branch,
            created_by,
        } => {
            conn.execute(
                "INSERT INTO worktrees (id, repo_root, worktree_path, branch, base_branch, created_by)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(worktree_path) DO UPDATE SET
                   status = 'active',
                   branch = excluded.branch,
                   base_branch = excluded.base_branch",
                params![id, repo_root, worktree_path, branch, base_branch, created_by],
            )?;
        }

        PersistCommand::WorktreeUpdateStatus {
            id,
            status,
            last_session_ended_at,
        } => {
            conn.execute(
                "UPDATE worktrees SET status = ?1, last_session_ended_at = COALESCE(?2, last_session_ended_at) WHERE id = ?3",
                params![status, last_session_ended_at, id],
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
    let db_path = crate::paths::db_path();

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

fn snapshot_kind_to_str(kind: TokenUsageSnapshotKind) -> &'static str {
    match kind {
        TokenUsageSnapshotKind::Unknown => "unknown",
        TokenUsageSnapshotKind::ContextTurn => "context_turn",
        TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
        TokenUsageSnapshotKind::MixedLegacy => "mixed_legacy",
        TokenUsageSnapshotKind::CompactionReset => "compaction_reset",
    }
}

fn snapshot_kind_from_str(kind: Option<&str>) -> TokenUsageSnapshotKind {
    match kind {
        Some("context_turn") => TokenUsageSnapshotKind::ContextTurn,
        Some("lifetime_totals") => TokenUsageSnapshotKind::LifetimeTotals,
        Some("mixed_legacy") => TokenUsageSnapshotKind::MixedLegacy,
        Some("compaction_reset") => TokenUsageSnapshotKind::CompactionReset,
        _ => TokenUsageSnapshotKind::Unknown,
    }
}

fn persist_usage_event(
    conn: &Connection,
    session_id: &str,
    usage: &TokenUsage,
    snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
    conn.execute(
        "INSERT INTO usage_events (
            session_id,
            observed_at,
            snapshot_kind,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            session_id,
            chrono_now(),
            snapshot_kind_to_str(snapshot_kind),
            usage.input_tokens as i64,
            usage.output_tokens as i64,
            usage.cached_tokens as i64,
            usage.context_window as i64,
        ],
    )?;
    Ok(())
}

fn upsert_usage_session_state(
    conn: &Connection,
    session_id: &str,
    usage: &TokenUsage,
    snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
    let session_meta: Option<(String, Option<String>, Option<String>)> = conn
        .query_row(
            "SELECT COALESCE(provider, 'claude'), codex_integration_mode, claude_integration_mode
             FROM sessions
             WHERE id = ?1",
            params![session_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let (provider, codex_mode, claude_mode) =
        session_meta.unwrap_or(("claude".to_string(), None, None));

    let existing: Option<(i64, i64, i64, i64, i64, i64)> = conn
        .query_row(
            "SELECT
                lifetime_input_tokens,
                lifetime_output_tokens,
                lifetime_cached_tokens,
                context_input_tokens,
                context_cached_tokens,
                context_window
             FROM usage_session_state
             WHERE session_id = ?1",
            params![session_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .optional()?;

    let usage_input = usage.input_tokens as i64;
    let usage_output = usage.output_tokens as i64;
    let usage_cached = usage.cached_tokens as i64;
    let usage_window = usage.context_window as i64;

    let (
        mut lifetime_input,
        mut lifetime_output,
        mut lifetime_cached,
        mut context_input,
        mut context_cached,
        mut context_window,
    ) = if let Some(values) = existing {
        values
    } else {
        (
            usage_input,
            usage_output,
            usage_cached,
            usage_input,
            usage_cached,
            usage_window,
        )
    };

    match snapshot_kind {
        TokenUsageSnapshotKind::Unknown => {}
        TokenUsageSnapshotKind::ContextTurn => {
            context_input = usage_input;
            context_cached = usage_cached;
            context_window = usage_window;
        }
        TokenUsageSnapshotKind::LifetimeTotals => {
            lifetime_input = usage_input;
            lifetime_output = usage_output;
            lifetime_cached = usage_cached;
            context_input = usage_input;
            context_cached = usage_cached;
            context_window = usage_window;
        }
        TokenUsageSnapshotKind::MixedLegacy => {
            context_input = usage_input;
            context_cached = usage_cached;
            context_window = usage_window;
            lifetime_output = lifetime_output.max(usage_output);
        }
        TokenUsageSnapshotKind::CompactionReset => {
            context_input = 0;
            context_cached = 0;
            context_window = usage_window;
            lifetime_output = lifetime_output.max(usage_output);
        }
    }

    conn.execute(
        "INSERT INTO usage_session_state (
            session_id,
            provider,
            codex_integration_mode,
            claude_integration_mode,
            snapshot_kind,
            snapshot_input_tokens,
            snapshot_output_tokens,
            snapshot_cached_tokens,
            snapshot_context_window,
            lifetime_input_tokens,
            lifetime_output_tokens,
            lifetime_cached_tokens,
            context_input_tokens,
            context_cached_tokens,
            context_window,
            updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        ON CONFLICT(session_id) DO UPDATE SET
            provider = excluded.provider,
            codex_integration_mode = excluded.codex_integration_mode,
            claude_integration_mode = excluded.claude_integration_mode,
            snapshot_kind = excluded.snapshot_kind,
            snapshot_input_tokens = excluded.snapshot_input_tokens,
            snapshot_output_tokens = excluded.snapshot_output_tokens,
            snapshot_cached_tokens = excluded.snapshot_cached_tokens,
            snapshot_context_window = excluded.snapshot_context_window,
            lifetime_input_tokens = excluded.lifetime_input_tokens,
            lifetime_output_tokens = excluded.lifetime_output_tokens,
            lifetime_cached_tokens = excluded.lifetime_cached_tokens,
            context_input_tokens = excluded.context_input_tokens,
            context_cached_tokens = excluded.context_cached_tokens,
            context_window = excluded.context_window,
            updated_at = excluded.updated_at",
        params![
            session_id,
            provider,
            codex_mode,
            claude_mode,
            snapshot_kind_to_str(snapshot_kind),
            usage_input,
            usage_output,
            usage_cached,
            usage_window,
            lifetime_input,
            lifetime_output,
            lifetime_cached,
            context_input,
            context_cached,
            context_window,
            chrono_now(),
        ],
    )?;

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn upsert_usage_turn_snapshot(
    conn: &Connection,
    session_id: &str,
    turn_id: &str,
    turn_seq: u64,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
    context_window: u64,
    snapshot_kind: TokenUsageSnapshotKind,
) -> Result<(), rusqlite::Error> {
    let previous_input: i64 = conn
        .query_row(
            "SELECT input_tokens
             FROM usage_turns
             WHERE session_id = ?1 AND turn_id != ?2
             ORDER BY turn_seq DESC, rowid DESC
             LIMIT 1",
            params![session_id, turn_id],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);

    let input_tokens_i64 = input_tokens as i64;
    let input_delta_tokens = (input_tokens_i64 - previous_input).max(0);

    conn.execute(
        "INSERT INTO usage_turns (
            session_id,
            turn_id,
            turn_seq,
            snapshot_kind,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            input_delta_tokens,
            created_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(session_id, turn_id) DO UPDATE SET
            turn_seq = excluded.turn_seq,
            snapshot_kind = excluded.snapshot_kind,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            cached_tokens = excluded.cached_tokens,
            context_window = excluded.context_window,
            input_delta_tokens = excluded.input_delta_tokens,
            created_at = excluded.created_at",
        params![
            session_id,
            turn_id,
            turn_seq as i64,
            snapshot_kind_to_str(snapshot_kind),
            input_tokens as i64,
            output_tokens as i64,
            cached_tokens as i64,
            context_window as i64,
            input_delta_tokens,
            chrono_now(),
        ],
    )?;

    Ok(())
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
    pub summary: Option<String>,
    pub codex_integration_mode: Option<String>,
    pub claude_integration_mode: Option<String>,
    pub codex_thread_id: Option<String>,
    pub claude_sdk_session_id: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cached_tokens: i64,
    pub context_window: i64,
    pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
    pub pending_tool_name: Option<String>,
    pub pending_tool_input: Option<String>,
    pub pending_question: Option<String>,
    pub pending_approval_id: Option<String>,
    pub messages: Vec<Message>,
    pub forked_from_session_id: Option<String>,
    pub current_diff: Option<String>,
    pub current_plan: Option<String>,
    pub turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)>, // (turn_id, diff, input_tokens, output_tokens, cached_tokens, context_window, snapshot_kind)
    pub git_branch: Option<String>,
    pub git_sha: Option<String>,
    pub current_cwd: Option<String>,
    pub first_prompt: Option<String>,
    pub last_message: Option<String>,
    pub end_reason: Option<String>,
    pub effort: Option<String>,
    pub terminal_session_id: Option<String>,
    pub terminal_app: Option<String>,
    pub approval_version: u64,
    pub unread_count: u64,
}

/// No longer backfills custom_name from first_prompt — the UI uses first_prompt
/// directly as a fallback display. Returns custom_name as-is.
fn resolve_custom_name_from_first_prompt(
    _conn: &Connection,
    _session_id: &str,
    custom_name: Option<String>,
    _first_prompt: Option<&str>,
) -> Result<Option<String>, rusqlite::Error> {
    Ok(custom_name)
}

fn load_messages_from_db(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<Message>, anyhow::Error> {
    let mut msg_stmt = conn.prepare(
        "SELECT id, type, content, timestamp, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json
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

            let duration_secs: Option<f64> = row.get(7)?;
            let is_error_int: i32 = row.get(8)?;
            let is_in_progress_int: i32 = row.get(9)?;
            let images_json: Option<String> = row.get(10)?;
            let images: Vec<orbitdock_protocol::ImageInput> = images_json
                .and_then(|j| serde_json::from_str(&j).ok())
                .unwrap_or_default();

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
                is_in_progress: is_in_progress_int != 0,
                images,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    Ok(messages)
}

fn load_latest_completed_conversation_message_from_db(
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
    images: Vec<orbitdock_protocol::ImageInput>,
}

fn role_to_message_type(role: &str) -> MessageType {
    if role == "user" {
        MessageType::User
    } else {
        MessageType::Assistant
    }
}

/// Extract individual content items from a content array.
/// Handles text, tool_use, tool_result, thinking, and image blocks.
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
                images: vec![],
            }];
        }
        return vec![];
    }

    let Some(array) = content.as_array() else {
        return vec![];
    };

    let mut items = Vec::new();
    let mut text_parts: Vec<String> = Vec::new();
    let mut images: Vec<orbitdock_protocol::ImageInput> = Vec::new();

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
            // Claude CLI: {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}
            "image" => {
                if let Some(source) = item.get("source") {
                    let source_type = source
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    if source_type == "base64" {
                        let media_type = source
                            .get("media_type")
                            .and_then(Value::as_str)
                            .unwrap_or("image/png");
                        if let Some(data) = source.get("data").and_then(Value::as_str) {
                            let data_uri = format!("data:{media_type};base64,{data}");
                            images.push(orbitdock_protocol::ImageInput {
                                input_type: "url".to_string(),
                                value: data_uri,
                            });
                        }
                    } else if source_type == "url" {
                        if let Some(url) = source.get("url").and_then(Value::as_str) {
                            images.push(orbitdock_protocol::ImageInput {
                                input_type: "url".to_string(),
                                value: url.to_string(),
                            });
                        }
                    }
                }
            }
            // Codex rollout: {"type": "input_image", "image_url": "data:..."}
            "input_image" => {
                if let Some(url) = item.get("image_url").and_then(Value::as_str) {
                    images.push(orbitdock_protocol::ImageInput {
                        input_type: "url".to_string(),
                        value: url.to_string(),
                    });
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
                            images: vec![],
                        });
                    }
                }
            }
            "tool_use" => {
                let name = item
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                let input = item.get("input").map(|v| v.to_string());
                let id = item.get("id").and_then(Value::as_str).map(String::from);
                items.push(ParsedItem {
                    message_type: MessageType::Tool,
                    content: String::new(),
                    tool_name: Some(name.to_string()),
                    tool_input: input,
                    tool_output: None,
                    tool_use_id: id,
                    images: vec![],
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
                    images: vec![],
                });
            }
            _ => {}
        }
    }

    // Flush accumulated text (+ any images) as a single user/assistant message
    if !text_parts.is_empty() || !images.is_empty() {
        items.insert(
            0,
            ParsedItem {
                message_type: role_to_message_type(role),
                content: text_parts.join("\n\n"),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                tool_use_id: None,
                images,
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
    let mut tool_use_index: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();

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

            let msg_id = format!("{session_id}:transcript:{msg_counter}");
            messages.push(Message {
                id: msg_id,
                session_id: session_id.to_string(),
                message_type: item.message_type,
                content: item.content,
                timestamp: timestamp.clone(),
                tool_name: item.tool_name,
                tool_input: item.tool_input,
                tool_output: item.tool_output,
                duration_ms: None,
                is_error: false,
                is_in_progress: false,
                images: item.images,
            });
            msg_counter += 1;
        }
    }

    Ok(messages)
}

/// Extract the AI-generated summary from a Claude JSONL transcript.
/// Claude writes `{"type":"summary","summary":"..."}` entries at session end.
/// Returns the last summary found (there may be multiple from branched conversations).
fn extract_summary_from_transcript(transcript_path: &str) -> Option<String> {
    let file = File::open(transcript_path).ok()?;
    let reader = BufReader::new(file);
    let mut last_summary: Option<String> = None;

    for line_result in reader.lines() {
        let line = match line_result {
            Ok(line) => line,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Quick check before full parse
        if !trimmed.contains("\"type\":\"summary\"") {
            continue;
        }

        let value: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => continue,
        };

        if value.get("type").and_then(Value::as_str) == Some("summary") {
            if let Some(summary) = value.get("summary").and_then(Value::as_str) {
                if !summary.is_empty() {
                    last_summary = Some(summary.to_string());
                }
            }
        }
    }

    last_summary
}

/// Extract summary from a transcript, async wrapper.
pub async fn extract_summary_from_transcript_path(transcript_path: &str) -> Option<String> {
    let path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || extract_summary_from_transcript(&path))
        .await
        .ok()
        .flatten()
}

fn value_to_u64(value: Option<&Value>) -> u64 {
    match value {
        Some(Value::Number(n)) => n
            .as_u64()
            .or_else(|| n.as_i64().map(|v| v.max(0) as u64))
            .unwrap_or(0),
        Some(Value::String(s)) => s.parse::<u64>().unwrap_or(0),
        _ => 0,
    }
}

fn load_token_usage_from_transcript(
    transcript_path: &str,
) -> Result<Option<TokenUsage>, anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok(None),
    };
    let reader = BufReader::new(file);

    let mut claude_usage = TokenUsage::default();
    let mut saw_claude_usage = false;
    let mut codex_usage: Option<TokenUsage> = None;

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

        let entry_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();

        // Claude transcript entries: use the last message's input/cached tokens (current context
        // fill) but accumulate output tokens across the session.
        if entry_type == "assistant" {
            if let Some(usage) = value
                .get("message")
                .and_then(|m| m.get("usage"))
                .and_then(Value::as_object)
            {
                saw_claude_usage = true;
                claude_usage.input_tokens = value_to_u64(usage.get("input_tokens"));
                claude_usage.output_tokens += value_to_u64(usage.get("output_tokens"));
                claude_usage.cached_tokens = value_to_u64(usage.get("cache_read_input_tokens"))
                    + value_to_u64(usage.get("cache_creation_input_tokens"));
            }
            continue;
        }

        // Codex rollout entries: token_count carries cumulative totals.
        if entry_type == "event_msg" {
            let payload = match value.get("payload").and_then(Value::as_object) {
                Some(payload) => payload,
                None => continue,
            };
            if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                continue;
            }

            let info = match payload.get("info").and_then(Value::as_object) {
                Some(info) => info,
                None => continue,
            };

            let usage_obj = info
                .get("last_token_usage")
                .or_else(|| info.get("total_token_usage"))
                .and_then(Value::as_object);

            if let Some(usage) = usage_obj {
                codex_usage = Some(TokenUsage {
                    input_tokens: value_to_u64(usage.get("input_tokens")),
                    output_tokens: value_to_u64(usage.get("output_tokens")),
                    cached_tokens: value_to_u64(usage.get("cached_input_tokens")),
                    context_window: value_to_u64(info.get("model_context_window")),
                });
            }
        }
    }

    if let Some(usage) = codex_usage {
        return Ok(Some(usage));
    }

    if saw_claude_usage {
        return Ok(Some(claude_usage));
    }

    Ok(None)
}

fn load_latest_codex_turn_context_settings_from_transcript(
    transcript_path: &str,
) -> Result<(Option<String>, Option<String>), anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok((None, None)),
    };
    let reader = BufReader::new(file);

    let mut model: Option<String> = None;
    let mut effort: Option<String> = None;

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

        if value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            != "turn_context"
        {
            continue;
        }

        let payload = match value.get("payload").and_then(Value::as_object) {
            Some(payload) => payload,
            None => continue,
        };

        if let Some(m) = payload
            .get("model")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            model = Some(m.to_string());
        }

        let effort_from_payload = payload
            .get("effort")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);

        let effort_from_collaboration_mode = payload
            .get("collaboration_mode")
            .and_then(|v| v.get("settings"))
            .and_then(|v| v.get("reasoning_effort"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);

        if let Some(e) = effort_from_payload.or(effort_from_collaboration_mode) {
            effort = Some(e);
        }
    }

    Ok((model, effort))
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

/// Load messages for a session directly from the database.
/// Used for lazy-loading messages when viewing closed sessions.
pub async fn load_messages_for_session(session_id: &str) -> Result<Vec<Message>, anyhow::Error> {
    let db_path = crate::paths::db_path();
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

pub async fn load_token_usage_from_transcript_path(
    transcript_path: &str,
) -> Result<Option<TokenUsage>, anyhow::Error> {
    let transcript_path_owned = transcript_path.to_string();
    tokio::task::spawn_blocking(move || load_token_usage_from_transcript(&transcript_path_owned))
        .await?
}

/// Capabilities extracted from a Claude transcript's init system message.
pub struct TranscriptCapabilities {
    pub slash_commands: Vec<String>,
    pub skills: Vec<String>,
    pub tools: Vec<String>,
}

/// Extract capabilities (skills, tools, slash_commands) from a Claude transcript's
/// init system message. Returns `None` if the transcript doesn't exist or has no
/// init message.
pub async fn load_capabilities_from_transcript_path(
    transcript_path: &str,
) -> Option<TranscriptCapabilities> {
    let path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || {
        let file = File::open(&path).ok()?;
        let reader = BufReader::new(file);

        for line_result in reader.lines() {
            let line = line_result.ok()?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(trimmed) {
                Ok(v) => v,
                Err(_) => continue,
            };

            // Look for the init system message
            if value.get("type").and_then(|v| v.as_str()) != Some("system")
                || value.get("subtype").and_then(|v| v.as_str()) != Some("init")
            {
                continue;
            }

            let parse_array = |key: &str| -> Vec<String> {
                value
                    .get(key)
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default()
            };

            return Some(TranscriptCapabilities {
                slash_commands: parse_array("slash_commands"),
                skills: parse_array("skills"),
                tools: parse_array("tools"),
            });
        }
        None
    })
    .await
    .ok()
    .flatten()
}

pub async fn load_latest_codex_turn_context_settings_from_transcript_path(
    transcript_path: &str,
) -> Result<(Option<String>, Option<String>), anyhow::Error> {
    let transcript_path_owned = transcript_path.to_string();
    tokio::task::spawn_blocking(move || {
        load_latest_codex_turn_context_settings_from_transcript(&transcript_path_owned)
    })
    .await?
}

/// Load recent sessions from the database for server restart recovery.
/// Includes ended sessions so UI history remains visible after app restart.
pub async fn load_sessions_for_startup() -> Result<Vec<RestoredSession>, anyhow::Error> {
    let db_path = crate::paths::db_path();

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
        // Exclude direct sessions — they manage state through the connector, not hooks.
        conn.execute(
            "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, 'startup_empty_shell')
             WHERE provider = 'claude'
               AND status = 'active'
               AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')
               AND COALESCE(prompt_count, 0) = 0
               AND COALESCE(tool_count, 0) = 0
               AND (first_prompt IS NULL OR trim(first_prompt) = '')
               AND (custom_name IS NULL OR trim(custom_name) = '')
               AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
            params![chrono_now()],
        )?;

        // Cleanup ghost direct Claude sessions that never initialized.
        // These have no SDK session ID, no first_prompt, and no messages —
        // meaning the CLI subprocess failed to start or was killed before init.
        conn.execute(
            "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, 'startup_ghost_direct')
             WHERE provider = 'claude'
               AND claude_integration_mode = 'direct'
               AND status = 'active'
               AND claude_sdk_session_id IS NULL
               AND (first_prompt IS NULL OR trim(first_prompt) = '')
               AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
            params![chrono_now()],
        )?;

        // Same for Codex direct sessions without a thread ID
        conn.execute(
            "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, 'startup_ghost_direct')
             WHERE provider = 'codex'
               AND codex_integration_mode = 'direct'
               AND status = 'active'
               AND codex_thread_id IS NULL
               AND (first_prompt IS NULL OR trim(first_prompt) = '')
               AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
            params![chrono_now()],
        )?;

        // Reset stale work_status for active direct sessions whose CLI process
        // died with the server. They'll reconnect via lazy connector on subscribe,
        // but until then the UI should show "reply" (awaiting prompt), not "working".
        conn.execute(
            "UPDATE sessions
             SET work_status = 'reply'
             WHERE status = 'active'
               AND work_status = 'working'
               AND ((provider = 'claude' AND claude_integration_mode = 'direct')
                 OR (provider = 'codex' AND codex_integration_mode = 'direct'))",
            [],
        )?;

        // Also reactivate Claude direct sessions that were previously ended by
        // server_shutdown (from older server versions). These should resume too.
        conn.execute(
            "UPDATE sessions
             SET status = 'active',
                 work_status = 'reply',
                 ended_at = NULL,
                 end_reason = NULL
             WHERE provider = 'claude'
               AND claude_integration_mode = 'direct'
               AND status = 'ended'
               AND end_reason = 'server_shutdown'",
            [],
        )?;

        // Restore recent sessions into runtime for active + history UI continuity.
        // Only load: active sessions, server-shutdown sessions (need resume), and recent 7-day history.
        let mut stmt = conn.prepare(
            "SELECT s.id, s.provider, s.status, s.work_status, s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.codex_integration_mode, s.codex_thread_id, s.started_at, s.last_activity_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                    s.pending_tool_name, s.pending_tool_input, s.pending_question,
                    COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                    COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                    COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                    COALESCE(uss.snapshot_context_window, s.context_window, 0),
                    COALESCE(uss.snapshot_kind, 'unknown')
             FROM sessions s
             LEFT JOIN usage_session_state uss ON uss.session_id = s.id
             WHERE s.status = 'active'
                OR (s.status = 'ended' AND s.end_reason = 'server_shutdown')
                OR datetime(COALESCE(s.last_activity_at, s.started_at)) > datetime('now', '-7 days')
             ORDER BY
               datetime(s.last_activity_at) DESC,
               datetime(s.started_at) DESC
             LIMIT 1000"
        )?;

        #[allow(clippy::type_complexity)]
        let session_rows: Vec<(
            String,
            String,
            String,
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
            String,
        )> = stmt
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
                    row.get(20)?,
                    row.get(21)?,
                    row.get(22)?,
                    row.get(23)?,
                    row.get(24)?,
                    row.get(25)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect();

        let mut sessions = Vec::new();

        for (
            id,
            provider,
            status,
            work_status,
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            first_prompt,
            _summary,
            codex_integration_mode,
            codex_thread_id,
            started_at,
            last_activity_at,
            approval_policy,
            sandbox_mode,
            permission_mode,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            token_usage_snapshot_kind_str,
        ) in session_rows
        {
            let token_usage_snapshot_kind =
                snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));

            // Skip message loading for ended history sessions (not server_shutdown).
            // Messages load lazily when a client subscribes.
            let end_reason_val: Option<String> = conn
                .query_row(
                    "SELECT end_reason FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);
            let is_ended_history = status == "ended"
                && !matches!(end_reason_val.as_deref(), Some("server_shutdown"));

            let messages = if is_ended_history {
                Vec::new()
            } else {
                let mut msgs = load_messages_from_db(&conn, &id)?;
                if msgs.is_empty() {
                    if let Some(path) = transcript_path.as_deref() {
                        msgs = load_messages_from_transcript(path, &id)?;
                    }
                }
                msgs
            };
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

            // Query diff/plan separately (column may not exist on old schemas)
            let (current_diff, current_plan): (Option<String>, Option<String>) = conn
                .query_row(
                    "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
                    params![id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap_or((None, None));

            // Load persisted turn diffs (table may not exist on old schemas)
            let turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)> =
                conn
                .prepare(
                    "SELECT td.turn_id,
                            td.diff,
                            COALESCE(ut.input_tokens, td.input_tokens, 0),
                            COALESCE(ut.output_tokens, td.output_tokens, 0),
                            COALESCE(ut.cached_tokens, td.cached_tokens, 0),
                            COALESCE(ut.context_window, td.context_window, 0),
                            COALESCE(ut.snapshot_kind, 'unknown')
                     FROM turn_diffs td
                     LEFT JOIN usage_turns ut
                       ON ut.session_id = td.session_id
                      AND ut.turn_id = td.turn_id
                     WHERE td.session_id = ?1
                     ORDER BY COALESCE(ut.turn_seq, td.rowid)"
                )
                .and_then(|mut stmt| {
                    let rows = stmt.query_map(params![id], |row| {
                        let snapshot_kind: String = row.get(6)?;
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, i64>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, i64>(4)?,
                            row.get::<_, i64>(5)?,
                            snapshot_kind_from_str(Some(snapshot_kind.as_str())),
                        ))
                    })?;
                    rows.collect::<Result<Vec<_>, _>>()
                })
                .unwrap_or_default();

            // Query environment fields (columns may not exist on old schemas)
            let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) = conn
                .query_row(
                    "SELECT git_branch, git_sha, current_cwd FROM sessions WHERE id = ?1",
                    params![id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .unwrap_or((None, None, None));

            // Query claude_integration_mode (column may not exist on old schemas)
            let claude_integration_mode: Option<String> = conn
                .query_row(
                    "SELECT claude_integration_mode FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            // Query claude_sdk_session_id (column may not exist on old schemas)
            let claude_sdk_session_id: Option<String> = conn
                .query_row(
                    "SELECT claude_sdk_session_id FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            // Query persisted session summary field (column may not exist on old schemas)
            let persisted_last_message: Option<String> = conn
                .query_row(
                    "SELECT last_message FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);
            let last_message = load_latest_completed_conversation_message_from_db(&conn, &id)
                .unwrap_or(None)
                .or(persisted_last_message);

            // Query effort (column may not exist on old schemas)
            let effort: Option<String> = conn
                .query_row(
                    "SELECT effort FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            // Query terminal info (columns exist in baseline schema)
            let (terminal_session_id, terminal_app): (Option<String>, Option<String>) = conn
                .query_row(
                    "SELECT terminal_session_id, terminal_app FROM sessions WHERE id = ?1",
                    params![id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap_or((None, None));

            // Query pending_approval_id (added in migration 005)
            let pending_approval_id: Option<String> = conn
                .query_row(
                    "SELECT pending_approval_id FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            // Query approval_version (added in migration 008)
            let approval_version: u64 = conn
                .query_row(
                    "SELECT approval_version FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get::<_, i64>(0).map(|v| v as u64),
                )
                .unwrap_or(0);

            // Recompute unread count from messages (migration 012)
            let unread_count: u64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
                    params![id],
                    |row| row.get::<_, i64>(0).map(|v| v as u64),
                )
                .unwrap_or(0);

            // end_reason already queried above for message-skip logic
            let end_reason = end_reason_val;

            // Query summary (column may not exist on old schemas)
            let mut summary: Option<String> = conn
                .query_row(
                    "SELECT summary FROM sessions WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            // If no summary in DB, try extracting from Claude transcript
            if summary.is_none() && provider == "claude" {
                if let Some(path) = transcript_path.as_deref() {
                    if let Some(extracted) = extract_summary_from_transcript(path) {
                        // Persist for next startup
                        let _ = conn.execute(
                            "UPDATE sessions SET summary = ? WHERE id = ?",
                            params![extracted, id],
                        );
                        summary = Some(extracted);
                    }
                }
            }

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
                summary,
                codex_integration_mode,
                claude_integration_mode,
                codex_thread_id,
                claude_sdk_session_id,
                started_at,
                last_activity_at,
                approval_policy,
                sandbox_mode,
                permission_mode,
                input_tokens,
                output_tokens,
                cached_tokens,
                context_window,
                token_usage_snapshot_kind,
                pending_tool_name,
                pending_tool_input,
                pending_question,
                pending_approval_id,
                messages,
                forked_from_session_id,
                current_diff,
                current_plan,
                turn_diffs,
                git_branch,
                git_sha,
                current_cwd,
                first_prompt,
                last_message,
                end_reason,
                effort,
                terminal_session_id,
                terminal_app,
                approval_version,
                unread_count,
            });
        }

        Ok(sessions)
    }).await??;

    Ok(sessions)
}

/// Load a specific session by ID (for resume — includes ended sessions)
pub async fn load_session_by_id(id: &str) -> Result<Option<RestoredSession>, anyhow::Error> {
    let db_path = crate::paths::db_path();
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
            "SELECT s.id, s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.started_at, s.last_activity_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                    s.pending_tool_name, s.pending_tool_input, s.pending_question,
                    COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                    COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                    COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                    COALESCE(uss.snapshot_context_window, s.context_window, 0),
                    s.provider, s.codex_integration_mode, s.claude_integration_mode,
                    s.claude_sdk_session_id, s.codex_thread_id, s.end_reason,
                    s.terminal_session_id, s.terminal_app,
                    COALESCE(uss.snapshot_kind, 'unknown')
             FROM sessions s
             LEFT JOIN usage_session_state uss ON uss.session_id = s.id
             WHERE s.id = ?1"
        )?;

        let row = stmt
            .query_row(params![&id_owned], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<String>>(10)?,
                    row.get::<_, Option<String>>(11)?,
                    row.get::<_, Option<String>>(12)?,
                    row.get::<_, Option<String>>(13)?,
                    row.get::<_, Option<String>>(14)?,
                    row.get::<_, Option<String>>(15)?,
                    row.get::<_, i64>(16)?,
                    row.get::<_, i64>(17)?,
                    row.get::<_, i64>(18)?,
                    row.get::<_, i64>(19)?,
                    row.get::<_, String>(20)?,
                    row.get::<_, Option<String>>(21)?,
                    row.get::<_, Option<String>>(22)?,
                    row.get::<_, Option<String>>(23)?,
                    row.get::<_, Option<String>>(24)?,
                    row.get::<_, Option<String>>(25)?,
                    row.get::<_, Option<String>>(26)?,
                    row.get::<_, Option<String>>(27)?,
                    row.get::<_, String>(28)?,
                ))
            })
            .optional()?;

        let Some((
            id,
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            first_prompt,
            summary,
            started_at,
            last_activity_at,
            approval_policy,
            sandbox_mode,
            permission_mode,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            provider,
            codex_integration_mode,
            claude_integration_mode,
            claude_sdk_session_id,
            codex_thread_id,
            end_reason,
            terminal_session_id,
            terminal_app,
            token_usage_snapshot_kind_str,
        )) = row else {
            return Ok(None);
        };

        let token_usage_snapshot_kind =
            snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));

        let messages = load_messages_from_db(&conn, &id)?;
        let custom_name =
            resolve_custom_name_from_first_prompt(&conn, &id, custom_name, first_prompt.as_deref())?;

        // Query diff/plan separately (column may not exist on old schemas)
        let (current_diff, current_plan): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
                params![&id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap_or((None, None));

        // Load persisted turn diffs (table may not exist on old schemas)
        let turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)> = conn
            .prepare(
                "SELECT td.turn_id,
                        td.diff,
                        COALESCE(ut.input_tokens, td.input_tokens, 0),
                        COALESCE(ut.output_tokens, td.output_tokens, 0),
                        COALESCE(ut.cached_tokens, td.cached_tokens, 0),
                        COALESCE(ut.context_window, td.context_window, 0),
                        COALESCE(ut.snapshot_kind, 'unknown')
                 FROM turn_diffs td
                 LEFT JOIN usage_turns ut
                   ON ut.session_id = td.session_id
                  AND ut.turn_id = td.turn_id
                 WHERE td.session_id = ?1
                 ORDER BY COALESCE(ut.turn_seq, td.rowid)"
            )
            .and_then(|mut stmt| {
                let rows = stmt.query_map(params![&id], |row| {
                    let snapshot_kind: String = row.get(6)?;
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        snapshot_kind_from_str(Some(snapshot_kind.as_str())),
                    ))
                })?;
                rows.collect::<Result<Vec<_>, _>>()
            })
            .unwrap_or_default();

        // Query environment fields (columns may not exist on old schemas)
        let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT git_branch, git_sha, current_cwd FROM sessions WHERE id = ?1",
                params![&id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap_or((None, None, None));

        // Query persisted session summary field (column may not exist on old schemas)
        let persisted_last_message: Option<String> = conn
            .query_row(
                "SELECT last_message FROM sessions WHERE id = ?1",
                params![&id],
                |row| row.get(0),
            )
            .unwrap_or(None);
        let last_message = load_latest_completed_conversation_message_from_db(&conn, &id)
            .unwrap_or(None)
            .or(persisted_last_message);

        // Query effort (column may not exist on old schemas)
        let effort: Option<String> = conn
            .query_row(
                "SELECT effort FROM sessions WHERE id = ?1",
                params![&id],
                |row| row.get(0),
            )
            .unwrap_or(None);

        // Query pending_approval_id (added in migration 005)
        let pending_approval_id: Option<String> = conn
            .query_row(
                "SELECT pending_approval_id FROM sessions WHERE id = ?1",
                params![&id],
                |row| row.get(0),
            )
            .unwrap_or(None);

        // Query approval_version (added in migration 008)
        let approval_version: u64 = conn
            .query_row(
                "SELECT approval_version FROM sessions WHERE id = ?1",
                params![&id],
                |row| row.get::<_, i64>(0).map(|v| v as u64),
            )
            .unwrap_or(0);

        // Recompute unread count from messages (migration 012)
        let unread_count: u64 = conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
                params![&id],
                |row| row.get::<_, i64>(0).map(|v| v as u64),
            )
            .unwrap_or(0);

        Ok(Some(RestoredSession {
            id,
            provider,
            status: "active".to_string(),
            work_status: "waiting".to_string(),
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            summary,
            codex_integration_mode,
            claude_integration_mode,
            codex_thread_id,
            claude_sdk_session_id,
            started_at,
            last_activity_at,
            approval_policy,
            sandbox_mode,
            permission_mode,
            input_tokens,
            output_tokens,
            cached_tokens,
            context_window,
            token_usage_snapshot_kind,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            pending_approval_id,
            messages,
            forked_from_session_id: None,
            current_diff,
            current_plan,
            turn_diffs,
            git_branch,
            git_sha,
            current_cwd,
            first_prompt,
            last_message,
            end_reason,
            effort,
            terminal_session_id,
            terminal_app,
            approval_version,
            unread_count,
        }))
    }).await??;

    Ok(result)
}

/// Load only the persisted Claude permission_mode for a session.
pub async fn load_session_permission_mode(id: &str) -> Result<Option<String>, anyhow::Error> {
    let db_path = crate::paths::db_path();
    let id_owned = id.to_string();

    let mode = tokio::task::spawn_blocking(move || -> Result<Option<String>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let mode = conn
            .query_row(
                "SELECT permission_mode FROM sessions WHERE id = ?1",
                params![&id_owned],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten();

        Ok(mode)
    })
    .await??;

    Ok(mode)
}

/// Create a sender for the persistence writer
pub fn create_persistence_channel() -> (mpsc::Sender<PersistCommand>, mpsc::Receiver<PersistCommand>)
{
    mpsc::channel(1000)
}

/// Clean up sessions where the DB has stale awaitingPermission/awaitingQuestion state
/// but the work_status has already moved on (e.g. Claude process crashed without a Stop hook).
///
/// This runs at server startup to repair any sessions left in an inconsistent state
/// from a previous run.
pub async fn cleanup_stale_permission_state() -> Result<u64, anyhow::Error> {
    let db_path = crate::paths::db_path();

    let (moved_on_count, orphaned_permission_count, orphaned_approval_count) =
        tokio::task::spawn_blocking(move || -> Result<(u64, u64, u64), anyhow::Error> {
        if !db_path.exists() {
            return Ok((0, 0, 0));
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let now = chrono_now();

        // Clear pending state for active sessions whose work_status is NOT permission/question
        // but whose hook-managed columns still claim an approval is pending. This happens when
        // Claude crashes without firing the Stop hook — the connector emits SessionUpdate
        // (work_status → waiting) but the hook columns stay stale.
        let moved_on_rows = conn.execute(
            "UPDATE sessions
             SET pending_tool_name = NULL,
                 pending_tool_input = NULL,
                 pending_question = NULL,
                 pending_approval_id = NULL,
                 attention_reason = CASE
                     WHEN attention_reason IN ('awaitingPermission', 'awaitingQuestion') THEN 'awaitingReply'
                     ELSE attention_reason
                 END
             WHERE status = 'active'
               AND work_status NOT IN ('permission', 'question')
               AND (
                   pending_tool_name IS NOT NULL
                   OR pending_question IS NOT NULL
                   OR attention_reason IN ('awaitingPermission', 'awaitingQuestion')
               )",
            [],
        )?;

        // Repair active sessions that are stuck in permission/question with no actionable
        // pending payload. This can happen if old hooks resolved/cleared pending IDs out of
        // order, leaving work_status pinned to permission indefinitely.
        let orphaned_approval_rows = conn.execute(
            "UPDATE approval_history
             SET decision = 'abort',
                 decided_at = COALESCE(decided_at, ?1)
             WHERE decision IS NULL
               AND session_id IN (
                   SELECT id
                   FROM sessions
                   WHERE status = 'active'
                     AND work_status IN ('permission', 'question')
                     AND pending_approval_id IS NULL
                     AND pending_tool_name IS NULL
                     AND pending_tool_input IS NULL
                     AND pending_question IS NULL
               )",
            params![now],
        )?;

        let orphaned_permission_rows = conn.execute(
            "UPDATE sessions
             SET work_status = 'waiting',
                 attention_reason = 'awaitingReply',
                 pending_tool_name = NULL,
                 pending_tool_input = NULL,
                 pending_question = NULL,
                 pending_approval_id = NULL
             WHERE status = 'active'
               AND work_status IN ('permission', 'question')
               AND pending_approval_id IS NULL
               AND pending_tool_name IS NULL
               AND pending_tool_input IS NULL
               AND pending_question IS NULL",
            [],
        )?;

        Ok((
            moved_on_rows as u64,
            orphaned_permission_rows as u64,
            orphaned_approval_rows as u64,
        ))
    })
    .await??;

    let count = moved_on_count + orphaned_permission_count;
    if count > 0 {
        info!(
            component = "startup",
            event = "startup.stale_permission_cleanup",
            sessions_fixed = count,
            moved_on_sessions_fixed = moved_on_count,
            orphaned_permission_sessions_fixed = orphaned_permission_count,
            orphaned_approval_rows_aborted = orphaned_approval_count,
            "Cleared stale pending permission/question state from prior crash"
        );
    }

    Ok(count)
}

/// Clean up tool messages stuck with is_in_progress = 1 from sessions that are no longer working.
/// This handles the case where the server crashed or restarted while tools were mid-execution.
///
/// Runs at server startup alongside `cleanup_stale_permission_state`.
pub async fn cleanup_dangling_in_progress_messages() -> Result<u64, anyhow::Error> {
    let db_path = crate::paths::db_path();

    let count = tokio::task::spawn_blocking(move || -> Result<u64, anyhow::Error> {
        if !db_path.exists() {
            return Ok(0);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let rows = conn.execute(
            "UPDATE messages SET is_in_progress = 0
             WHERE is_in_progress = 1
               AND session_id IN (SELECT id FROM sessions WHERE work_status != 'working')",
            [],
        )?;

        Ok(rows as u64)
    })
    .await??;

    if count > 0 {
        info!(
            component = "startup",
            event = "startup.dangling_in_progress_cleanup",
            messages_fixed = count,
            "Cleared dangling is_in_progress tool messages from prior crash"
        );
    }

    Ok(count)
}

/// List approval history, optionally scoped to a session
pub async fn list_approvals(
    session_id: Option<String>,
    limit: Option<u32>,
) -> Result<Vec<ApprovalHistoryItem>, anyhow::Error> {
    let db_path = crate::paths::db_path();
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
    let db_path = crate::paths::db_path();

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

/// List review comments for a session, optionally filtered by turn_id
pub async fn list_review_comments(
    session_id: &str,
    turn_id: Option<&str>,
) -> Result<Vec<orbitdock_protocol::ReviewComment>, anyhow::Error> {
    let session_id = session_id.to_string();
    let turn_id = turn_id.map(|s| s.to_string());
    let db_path = crate::paths::db_path();

    let comments = tokio::task::spawn_blocking(move || -> Result<Vec<orbitdock_protocol::ReviewComment>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(Vec::new());
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        // Check table exists
        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'review_comments'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(Vec::new());
        }

        let (sql, params_vec): (String, Vec<Box<dyn rusqlite::ToSql>>) = if let Some(ref tid) = turn_id {
            (
                "SELECT id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at, updated_at
                 FROM review_comments WHERE session_id = ?1 AND turn_id = ?2 ORDER BY created_at".to_string(),
                vec![Box::new(session_id.clone()) as Box<dyn rusqlite::ToSql>, Box::new(tid.clone())],
            )
        } else {
            (
                "SELECT id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at, updated_at
                 FROM review_comments WHERE session_id = ?1 ORDER BY created_at".to_string(),
                vec![Box::new(session_id.clone()) as Box<dyn rusqlite::ToSql>],
            )
        };

        let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(params_refs), |row| {
            let tag_str: Option<String> = row.get(7)?;
            let status_str: String = row.get(8)?;

            let tag = tag_str.and_then(|t| match t.as_str() {
                "clarity" => Some(orbitdock_protocol::ReviewCommentTag::Clarity),
                "scope" => Some(orbitdock_protocol::ReviewCommentTag::Scope),
                "risk" => Some(orbitdock_protocol::ReviewCommentTag::Risk),
                "nit" => Some(orbitdock_protocol::ReviewCommentTag::Nit),
                _ => None,
            });

            let status = match status_str.as_str() {
                "resolved" => orbitdock_protocol::ReviewCommentStatus::Resolved,
                _ => orbitdock_protocol::ReviewCommentStatus::Open,
            };

            Ok(orbitdock_protocol::ReviewComment {
                id: row.get(0)?,
                session_id: row.get(1)?,
                turn_id: row.get(2)?,
                file_path: row.get(3)?,
                line_start: row.get(4)?,
                line_end: row.get(5)?,
                body: row.get(6)?,
                tag,
                status,
                created_at: row.get(9)?,
                updated_at: row.get(10)?,
            })
        })?;

        let mut comments = Vec::new();
        for row in rows {
            comments.push(row?);
        }
        Ok(comments)
    })
    .await??;

    Ok(comments)
}

/// Load subagents for a session (for snapshot building)
pub async fn load_subagents_for_session(
    session_id: &str,
) -> Result<Vec<orbitdock_protocol::SubagentInfo>, anyhow::Error> {
    let session_id = session_id.to_string();
    let db_path = crate::paths::db_path();

    let subagents = tokio::task::spawn_blocking(move || -> Result<Vec<orbitdock_protocol::SubagentInfo>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(Vec::new());
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'subagents'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(Vec::new());
        }

        let mut stmt = conn.prepare(
            "SELECT id, agent_type, started_at, ended_at FROM subagents WHERE session_id = ?1 ORDER BY started_at",
        )?;
        let rows = stmt.query_map(params![session_id], |row| {
            Ok(orbitdock_protocol::SubagentInfo {
                id: row.get(0)?,
                agent_type: row.get(1)?,
                started_at: row.get(2)?,
                ended_at: row.get(3)?,
            })
        })?;

        let mut subagents = Vec::new();
        for row in rows {
            subagents.push(row?);
        }
        Ok(subagents)
    })
    .await??;

    Ok(subagents)
}

/// Load the transcript path for a specific subagent
pub async fn load_subagent_transcript_path(
    subagent_id: &str,
) -> Result<Option<String>, anyhow::Error> {
    let subagent_id = subagent_id.to_string();
    let db_path = crate::paths::db_path();

    let path = tokio::task::spawn_blocking(move || -> Result<Option<String>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'subagents'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(None);
        }

        let path: Option<String> = conn
            .query_row(
                "SELECT transcript_path FROM subagents WHERE id = ?1",
                params![subagent_id],
                |row| {
                    let val: Option<String> = row.get(0)?;
                    Ok(val)
                },
            )
            .optional()?
            .flatten();

        Ok(path)
    })
    .await??;

    Ok(path)
}

/// Read a config value from the database.
///
/// Transparently decrypts values with the `enc:` prefix.
/// Plaintext values pass through unchanged (no migration needed).
pub fn load_config_value(key: &str) -> Option<String> {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return None;
    }

    let conn = Connection::open(&db_path).ok()?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )
    .ok()?;

    let raw: String = conn
        .query_row(
            "SELECT value FROM config WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .ok()
        .flatten()?;

    crate::crypto::decrypt(&raw)
}

// ---------------------------------------------------------------------------
// Worktree read helpers
// ---------------------------------------------------------------------------

/// Minimal DB row for worktree lookups.
#[derive(Debug, Clone)]
pub struct WorktreeRow {
    pub id: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_branch: Option<String>,
    pub status: String,
}

fn open_readonly_conn(db_path: &PathBuf) -> Option<Connection> {
    if !db_path.exists() {
        return None;
    }
    let conn = Connection::open(db_path).ok()?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )
    .ok()?;
    Some(conn)
}

pub fn load_worktree_by_id(db_path: &PathBuf, worktree_id: &str) -> Option<WorktreeRow> {
    let conn = open_readonly_conn(db_path)?;
    conn.query_row(
        "SELECT id, repo_root, worktree_path, branch, base_branch, status FROM worktrees WHERE id = ?1",
        params![worktree_id],
        |row| {
            Ok(WorktreeRow {
                id: row.get(0)?,
                repo_root: row.get(1)?,
                worktree_path: row.get(2)?,
                branch: row.get(3)?,
                base_branch: row.get(4)?,
                status: row.get(5)?,
            })
        },
    )
    .optional()
    .ok()
    .flatten()
}

pub fn load_worktrees_by_repo(db_path: &PathBuf, repo_root: &str) -> Vec<WorktreeRow> {
    let Some(conn) = open_readonly_conn(db_path) else {
        return Vec::new();
    };
    let mut stmt = match conn.prepare(
        "SELECT id, repo_root, worktree_path, branch, base_branch, status FROM worktrees WHERE repo_root = ?1 AND status != 'removed'",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    stmt.query_map(params![repo_root], |row| {
        Ok(WorktreeRow {
            id: row.get(0)?,
            repo_root: row.get(1)?,
            worktree_path: row.get(2)?,
            branch: row.get(3)?,
            base_branch: row.get(4)?,
            status: row.get(5)?,
        })
    })
    .ok()
    .map(|rows| rows.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
}

/// Derive a human-readable display name from a Claude model string.
///
/// Handles both new-style (`claude-opus-4-6`) and legacy (`claude-3-5-sonnet-20241022`) formats.
/// Strips `claude-` prefix and date suffixes, then extracts the family name and version numbers.
/// Falls back to the raw string (minus `claude-` prefix) for unrecognized formats.
pub fn display_name_from_model_string(model: &str) -> String {
    let stripped = model.strip_prefix("claude-").unwrap_or(model);

    // Strip trailing date suffix (-YYYYMMDD)
    let without_date = if stripped.len() > 9 {
        let tail = &stripped[stripped.len() - 9..];
        if tail.starts_with('-') && tail[1..].chars().all(|c| c.is_ascii_digit()) && tail.len() == 9
        {
            &stripped[..stripped.len() - 9]
        } else {
            stripped
        }
    } else {
        stripped
    };

    let families = ["opus", "sonnet", "haiku"];
    let parts: Vec<&str> = without_date.split('-').collect();

    if let Some(family_idx) = parts
        .iter()
        .position(|p| families.contains(&p.to_lowercase().as_str()))
    {
        let family = capitalize_first(parts[family_idx]);
        let version_parts: Vec<&str> = parts
            .iter()
            .enumerate()
            .filter(|(i, p)| *i != family_idx && p.chars().all(|c| c.is_ascii_digit()))
            .map(|(_, p)| *p)
            .collect();

        if version_parts.is_empty() {
            family
        } else {
            format!("{} {}", family, version_parts.join("."))
        }
    } else {
        without_date.to_string()
    }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(c) => c.to_uppercase().to_string() + &chars.as_str().to_lowercase(),
    }
}

/// Backfill `claude_models` from distinct model values in the `sessions` table.
///
/// Only inserts models not already present — preserves richer direct connector data.
/// Called once at server startup to seed the table from historical hook sessions.
pub async fn backfill_claude_models_from_sessions() {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return;
    }

    let result = tokio::task::spawn_blocking(move || -> Result<usize, anyhow::Error> {
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let mut stmt = conn.prepare(
            "SELECT DISTINCT s.model
             FROM sessions s
             LEFT JOIN claude_models cm ON cm.value = s.model
             WHERE s.provider = 'claude'
               AND s.model IS NOT NULL
               AND s.model != ''
               AND cm.value IS NULL",
        )?;

        let models: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();

        if models.is_empty() {
            return Ok(0);
        }

        let now = chrono_now();
        let mut insert = conn.prepare(
            "INSERT INTO claude_models (value, display_name, description, updated_at)
             VALUES (?1, ?2, '', ?3)
             ON CONFLICT(value) DO NOTHING",
        )?;

        let mut count = 0;
        for model in &models {
            let dn = display_name_from_model_string(model);
            insert.execute(params![model, dn, now])?;
            count += 1;
        }

        Ok(count)
    })
    .await;

    match result {
        Ok(Ok(count)) if count > 0 => {
            info!(
                component = "startup",
                event = "claude_models.backfill",
                count,
                "Backfilled claude_models from session history"
            );
        }
        Ok(Err(e)) => {
            warn!(
                component = "startup",
                event = "claude_models.backfill_failed",
                error = %e,
                "Failed to backfill claude_models"
            );
        }
        Err(e) => {
            warn!(
                component = "startup",
                event = "claude_models.backfill_failed",
                error = %e,
                "Backfill task panicked"
            );
        }
        _ => {}
    }
}

/// Load cached Claude models from the database.
///
/// Opens its own connection like `load_config_value` — safe to call from any context.
pub fn load_cached_claude_models() -> Vec<orbitdock_protocol::ClaudeModelOption> {
    let db_path = crate::paths::db_path();
    if !db_path.exists() {
        return Vec::new();
    }

    let conn = match Connection::open(&db_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let _ = conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    );

    let mut stmt = match conn.prepare("SELECT value, display_name, description FROM claude_models")
    {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    stmt.query_map([], |row| {
        Ok(orbitdock_protocol::ClaudeModelOption {
            value: row.get(0)?,
            display_name: row.get(1)?,
            description: row.get(2)?,
        })
    })
    .map(|rows| rows.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
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

    struct DataDirGuard;

    impl Drop for DataDirGuard {
        fn drop(&mut self) {
            crate::paths::reset_data_dir();
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        TEST_ENV_LOCK.get_or_init(|| Mutex::new(()))
    }

    fn set_test_data_dir(home: &Path) -> DataDirGuard {
        crate::paths::init_data_dir(Some(&home.join(".orbitdock")));
        DataDirGuard
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
    }

    #[test]
    fn test_time_to_iso8601() {
        // 2024-01-15 12:30:45 UTC
        let result = time_to_iso8601(1705322445);
        assert!(result.starts_with("2024-01-15"));
    }

    #[test]
    fn message_update_sets_last_message_from_completed_conversation_messages_only() {
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "message-update-last-message".into(),
                provider: Provider::Codex,
                project_path: "/tmp/message-update-last-message".into(),
                project_name: Some("message-update-last-message".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("seed session");

        flush_batch(
            &db_path,
            vec![PersistCommand::MessageAppend {
                session_id: "message-update-last-message".into(),
                message: Message {
                    id: "assistant-stream".into(),
                    session_id: "message-update-last-message".into(),
                    message_type: MessageType::Assistant,
                    content: "I".into(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: "2026-02-28T00:00:00Z".into(),
                    duration_ms: None,
                    images: vec![],
                },
            }],
        )
        .expect("append in-progress assistant message");

        let conn = Connection::open(&db_path).expect("open db");
        let initial_last_message: Option<String> = conn
            .query_row(
                "SELECT last_message FROM sessions WHERE id = ?1",
                params!["message-update-last-message"],
                |row| row.get(0),
            )
            .expect("query initial last_message");
        assert!(initial_last_message.is_none());

        flush_batch(
            &db_path,
            vec![PersistCommand::MessageUpdate {
                session_id: "message-update-last-message".into(),
                message_id: "assistant-stream".into(),
                content: Some("Implemented both parts of the dashboard update".into()),
                tool_output: None,
                duration_ms: None,
                is_error: None,
                is_in_progress: Some(false),
            }],
        )
        .expect("finalize assistant message");

        let updated_last_message: Option<String> = conn
            .query_row(
                "SELECT last_message FROM sessions WHERE id = ?1",
                params!["message-update-last-message"],
                |row| row.get(0),
            )
            .expect("query updated last_message");
        assert_eq!(
            updated_last_message.as_deref(),
            Some("Implemented both parts of the dashboard update")
        );

        flush_batch(
            &db_path,
            vec![
                PersistCommand::MessageAppend {
                    session_id: "message-update-last-message".into(),
                    message: Message {
                        id: "tool-msg".into(),
                        session_id: "message-update-last-message".into(),
                        message_type: MessageType::Tool,
                        content: "echo hello".into(),
                        tool_name: Some("Bash".into()),
                        tool_input: Some("{\"command\":\"echo hello\"}".into()),
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: "2026-02-28T00:00:01Z".into(),
                        duration_ms: None,
                        images: vec![],
                    },
                },
                PersistCommand::MessageUpdate {
                    session_id: "message-update-last-message".into(),
                    message_id: "tool-msg".into(),
                    content: Some("echo hello && pwd".into()),
                    tool_output: None,
                    duration_ms: None,
                    is_error: None,
                    is_in_progress: Some(false),
                },
            ],
        )
        .expect("append and update tool message");

        let after_tool_last_message: Option<String> = conn
            .query_row(
                "SELECT last_message FROM sessions WHERE id = ?1",
                params!["message-update-last-message"],
                |row| row.get(0),
            )
            .expect("query last_message after tool update");
        assert_eq!(
            after_tool_last_message.as_deref(),
            Some("Implemented both parts of the dashboard update")
        );
    }

    #[test]
    fn approval_requested_upserts_existing_unresolved_row_for_same_request_id() {
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "approval-upsert-session".into(),
                provider: Provider::Codex,
                project_path: "/tmp/approval-upsert".into(),
                project_name: Some("approval-upsert".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("seed approval upsert session");

        flush_batch(
            &db_path,
            vec![
                PersistCommand::ApprovalRequested {
                    session_id: "approval-upsert-session".into(),
                    request_id: "req-1".into(),
                    approval_type: ApprovalType::Exec,
                    tool_name: Some("Bash".into()),
                    command: Some("echo first".into()),
                    file_path: None,
                    cwd: Some("/tmp/approval-upsert".into()),
                    proposed_amendment: None,
                },
                PersistCommand::ApprovalRequested {
                    session_id: "approval-upsert-session".into(),
                    request_id: "req-1".into(),
                    approval_type: ApprovalType::Exec,
                    tool_name: Some("Bash".into()),
                    command: Some("echo updated".into()),
                    file_path: None,
                    cwd: Some("/tmp/approval-upsert".into()),
                    proposed_amendment: None,
                },
            ],
        )
        .expect("persist approval requests");

        let conn = Connection::open(&db_path).expect("open db");
        let rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM approval_history WHERE session_id = ?1 AND request_id = ?2",
                params!["approval-upsert-session", "req-1"],
                |row| row.get(0),
            )
            .expect("count approval history rows");
        assert_eq!(rows, 1);

        let command: Option<String> = conn
            .query_row(
                "SELECT command FROM approval_history WHERE session_id = ?1 AND request_id = ?2",
                params!["approval-upsert-session", "req-1"],
                |row| row.get(0),
            )
            .expect("load updated command");
        assert_eq!(command.as_deref(), Some("echo updated"));
    }

    #[test]
    fn approval_decision_resolves_all_unresolved_duplicates_for_request_id() {
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "approval-resolution-session".into(),
                provider: Provider::Codex,
                project_path: "/tmp/approval-resolution".into(),
                project_name: Some("approval-resolution".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("seed approval resolution session");

        let conn = Connection::open(&db_path).expect("open db");
        let created_at = "2026-02-25T00:00:00Z";
        conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-1",
                "exec",
                "Bash",
                "echo one",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert first duplicate unresolved approval");
        conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-1",
                "exec",
                "Bash",
                "echo two",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert second duplicate unresolved approval");
        conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-2",
                "exec",
                "Bash",
                "echo next",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert next unresolved approval");
        conn.execute(
            "UPDATE sessions SET pending_approval_id = ?1 WHERE id = ?2",
            params!["req-1", "approval-resolution-session"],
        )
        .expect("seed stale queue head");

        flush_batch(
            &db_path,
            vec![PersistCommand::ApprovalDecision {
                session_id: "approval-resolution-session".into(),
                request_id: "req-1".into(),
                decision: "approved".into(),
            }],
        )
        .expect("persist approval decision");

        let unresolved_for_req_1: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM approval_history
                 WHERE session_id = ?1 AND request_id = ?2 AND decision IS NULL",
                params!["approval-resolution-session", "req-1"],
                |row| row.get(0),
            )
            .expect("count unresolved duplicates");
        assert_eq!(unresolved_for_req_1, 0);

        let pending_approval_id: Option<String> = conn
            .query_row(
                "SELECT pending_approval_id FROM sessions WHERE id = ?1",
                params!["approval-resolution-session"],
                |row| row.get(0),
            )
            .expect("load pending approval id");
        assert_eq!(pending_approval_id.as_deref(), Some("req-2"));
    }

    #[test]
    fn tokens_update_writes_usage_tables() {
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "usage-session".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/usage-session".into(),
                    project_name: Some("usage-session".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::TokensUpdate {
                    session_id: "usage-session".into(),
                    usage: TokenUsage {
                        input_tokens: 1200,
                        output_tokens: 300,
                        cached_tokens: 100,
                        context_window: 200_000,
                    },
                    snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                },
                PersistCommand::TurnDiffInsert {
                    session_id: "usage-session".into(),
                    turn_id: "turn-1".into(),
                    turn_seq: 1,
                    diff: "--- a/file\n+++ b/file\n@@\n-old\n+new".into(),
                    input_tokens: 1200,
                    output_tokens: 300,
                    cached_tokens: 100,
                    context_window: 200_000,
                    snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                },
            ],
        )
        .expect("flush usage writes");

        let conn = Connection::open(&db_path).expect("open db");

        let event_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE session_id = ?1",
                params!["usage-session"],
                |row| row.get(0),
            )
            .expect("count usage events");
        assert_eq!(event_count, 1);

        let (snapshot_kind, context_input, context_window): (String, i64, i64) = conn
            .query_row(
                "SELECT snapshot_kind, context_input_tokens, context_window
                 FROM usage_session_state
                 WHERE session_id = ?1",
                params!["usage-session"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load usage state");
        assert_eq!(snapshot_kind, "context_turn");
        assert_eq!(context_input, 1200);
        assert_eq!(context_window, 200_000);

        let (turn_seq, input_delta, turn_kind): (i64, i64, String) = conn
            .query_row(
                "SELECT turn_seq, input_delta_tokens, snapshot_kind
                 FROM usage_turns
                 WHERE session_id = ?1 AND turn_id = ?2",
                params!["usage-session", "turn-1"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("load usage turn");
        assert_eq!(turn_seq, 1);
        assert_eq!(input_delta, 1200);
        assert_eq!(turn_kind, "context_turn");
    }

    #[tokio::test]
    async fn startup_restore_prefers_usage_session_state_snapshot_values() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "usage-restore".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/usage-restore".into(),
                    project_name: Some("usage-restore".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::TokensUpdate {
                    session_id: "usage-restore".into(),
                    usage: TokenUsage {
                        input_tokens: 123,
                        output_tokens: 77,
                        cached_tokens: 19,
                        context_window: 200_000,
                    },
                    snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                },
            ],
        )
        .expect("seed usage restore session");

        let conn = Connection::open(&db_path).expect("open db");
        conn.execute(
            "UPDATE sessions
             SET input_tokens = 1,
                 output_tokens = 2,
                 cached_tokens = 3,
                 context_window = 4
             WHERE id = ?1",
            params!["usage-restore"],
        )
        .expect("mutate legacy token columns");

        let restored = load_sessions_for_startup()
            .await
            .expect("load sessions for startup");
        let session = restored
            .iter()
            .find(|s| s.id == "usage-restore")
            .expect("restored usage session");

        assert_eq!(session.input_tokens, 123);
        assert_eq!(session.output_tokens, 77);
        assert_eq!(session.cached_tokens, 19);
        assert_eq!(session.context_window, 200_000);
        assert_eq!(
            session.token_usage_snapshot_kind,
            TokenUsageSnapshotKind::ContextTurn
        );
    }

    #[tokio::test]
    async fn load_session_by_id_prefers_usage_turns_and_turn_seq_order() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "usage-turn-restore".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/usage-turn-restore".into(),
                    project_name: Some("usage-turn-restore".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::TokensUpdate {
                    session_id: "usage-turn-restore".into(),
                    usage: TokenUsage {
                        input_tokens: 1_000,
                        output_tokens: 200,
                        cached_tokens: 50,
                        context_window: 200_000,
                    },
                    snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
                },
                PersistCommand::TurnDiffInsert {
                    session_id: "usage-turn-restore".into(),
                    turn_id: "turn-2".into(),
                    turn_seq: 2,
                    diff: "two".into(),
                    input_tokens: 700,
                    output_tokens: 140,
                    cached_tokens: 30,
                    context_window: 200_000,
                    snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                },
                PersistCommand::TurnDiffInsert {
                    session_id: "usage-turn-restore".into(),
                    turn_id: "turn-1".into(),
                    turn_seq: 1,
                    diff: "one".into(),
                    input_tokens: 400,
                    output_tokens: 80,
                    cached_tokens: 20,
                    context_window: 200_000,
                    snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                },
            ],
        )
        .expect("seed turn restore session");

        let conn = Connection::open(&db_path).expect("open db");
        conn.execute(
            "UPDATE turn_diffs
             SET input_tokens = 9,
                 output_tokens = 9,
                 cached_tokens = 9,
                 context_window = 9
             WHERE session_id = ?1",
            params!["usage-turn-restore"],
        )
        .expect("mutate legacy turn token columns");

        let restored = load_session_by_id("usage-turn-restore")
            .await
            .expect("load session by id")
            .expect("session restored");

        assert_eq!(
            restored.token_usage_snapshot_kind,
            TokenUsageSnapshotKind::LifetimeTotals
        );
        assert_eq!(restored.turn_diffs.len(), 2);
        assert_eq!(restored.turn_diffs[0].0, "turn-1");
        assert_eq!(restored.turn_diffs[1].0, "turn-2");
        assert_eq!(restored.turn_diffs[0].2, 400);
        assert_eq!(restored.turn_diffs[1].2, 700);
        assert_eq!(
            restored.turn_diffs[0].6,
            TokenUsageSnapshotKind::ContextTurn
        );
        assert_eq!(
            restored.turn_diffs[1].6,
            TokenUsageSnapshotKind::ContextTurn
        );
    }

    #[tokio::test]
    async fn load_session_permission_mode_returns_persisted_value() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "claude-permission".into(),
                provider: Provider::Claude,
                project_path: "/tmp/claude-permission".into(),
                project_name: Some("claude-permission".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-6".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: Some("bypassPermissions".into()),
                forked_from_session_id: None,
            }],
        )
        .expect("seed session");

        let mode = load_session_permission_mode("claude-permission")
            .await
            .expect("load permission mode");
        assert_eq!(mode.as_deref(), Some("bypassPermissions"));

        let missing = load_session_permission_mode("missing-session")
            .await
            .expect("load missing permission mode");
        assert!(missing.is_none());
    }

    #[tokio::test]
    async fn startup_restore_includes_active_and_ended_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
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
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
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
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
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
    async fn startup_restore_prefers_messages_table_for_last_message_over_stale_session_column() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::SessionCreate {
                    id: "stale-last-message".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/stale-last-message".into(),
                    project_name: Some("stale-last-message".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::MessageAppend {
                    session_id: "stale-last-message".into(),
                    message: Message {
                        id: "assistant-final".into(),
                        session_id: "stale-last-message".into(),
                        message_type: MessageType::Assistant,
                        content: "Implemented both parts of the dashboard update".into(),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: "2026-02-28T00:00:00Z".into(),
                        duration_ms: None,
                        images: vec![],
                    },
                },
            ],
        )
        .expect("seed stale-last-message session");

        let conn = Connection::open(&db_path).expect("open db");
        conn.execute(
            "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
            params!["Yes", "stale-last-message"],
        )
        .expect("force stale session.last_message");
        drop(conn);

        let restored = load_sessions_for_startup().await.expect("load sessions");
        let startup_last_message = restored
            .iter()
            .find(|session| session.id == "stale-last-message")
            .and_then(|session| session.last_message.clone());
        assert_eq!(
            startup_last_message.as_deref(),
            Some("Implemented both parts of the dashboard update")
        );

        let by_id = load_session_by_id("stale-last-message")
            .await
            .expect("load session by id")
            .expect("expected restored session");
        assert_eq!(
            by_id.last_message.as_deref(),
            Some("Implemented both parts of the dashboard update")
        );
    }

    #[tokio::test]
    async fn startup_restore_keeps_recent_passive_active_and_ends_stale_passive() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
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
        let _dd_guard = set_test_data_dir(&home);
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
        let _dd_guard = set_test_data_dir(&home);
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
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-shell.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                    forked_from_session_id: None,
                    repository_root: None,
                    is_worktree: false,
                    git_sha: None,
                },
                // Real session: has first prompt and should remain active.
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-real".into(),
                    project_path: "/tmp/claude-real".into(),
                    project_name: Some("claude-real".into()),
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-real.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                    forked_from_session_id: None,
                    repository_root: None,
                    is_worktree: false,
                    git_sha: None,
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
        let _dd_guard = set_test_data_dir(&home);
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
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
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
        let _dd_guard = set_test_data_dir(&home);
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
    async fn startup_restores_first_prompt_for_claude_and_codex() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                PersistCommand::ClaudeSessionUpsert {
                    id: "claude-1".into(),
                    project_path: "/tmp/claude".into(),
                    project_name: Some("claude".into()),
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some("/tmp/claude-1.jsonl".into()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                    forked_from_session_id: None,
                    repository_root: None,
                    is_worktree: false,
                    git_sha: None,
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
                    branch: Some("main".into()),
                    model: Some("gpt-5-codex".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
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
            session.first_prompt.as_deref(),
            Some("Investigate flaky CI and propose fixes")
        );

        let codex_session = restored
            .iter()
            .find(|s| s.id == "codex-1")
            .expect("codex session restored");
        assert_eq!(
            codex_session.first_prompt.as_deref(),
            Some("Refactor flaky test setup")
        );
    }

    #[tokio::test]
    async fn startup_restore_hydrates_claude_messages_from_transcript_when_db_messages_missing() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
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
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-1".into()),
                    context_label: None,
                    transcript_path: Some(transcript_path.to_string_lossy().to_string()),
                    source: Some("startup".into()),
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                    forked_from_session_id: None,
                    repository_root: None,
                    is_worktree: false,
                    git_sha: None,
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
        let _dd_guard = set_test_data_dir(&home);
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

    #[tokio::test]
    async fn transcript_usage_parses_claude_message_usage() {
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-usage-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let transcript_path = tmp_dir.join("claude-usage.jsonl");

        std::fs::write(
            &transcript_path,
            r#"{"type":"assistant","timestamp":"2026-02-10T01:00:00Z","message":{"role":"assistant","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"content":[{"type":"text","text":"first"}]}}
{"type":"assistant","timestamp":"2026-02-10T01:00:02Z","message":{"role":"assistant","usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":4,"cache_creation_input_tokens":1},"content":[{"type":"text","text":"second"}]}}
"#,
        )
        .expect("write transcript");

        let usage =
            load_token_usage_from_transcript_path(transcript_path.to_string_lossy().as_ref())
                .await
                .expect("parse usage")
                .expect("usage present");

        // input_tokens and cached_tokens use the LAST message (current context fill)
        assert_eq!(usage.input_tokens, 50);
        assert_eq!(usage.output_tokens, 60);
        assert_eq!(usage.cached_tokens, 5); // 4 + 1 from last message
        assert_eq!(usage.context_window, 0);
    }

    #[tokio::test]
    async fn transcript_usage_parses_codex_token_count_total_usage() {
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-usage-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let transcript_path = tmp_dir.join("codex-usage.jsonl");

        std::fs::write(
            &transcript_path,
            r#"{"type":"event_msg","timestamp":"2026-02-10T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":321,"output_tokens":123,"cached_input_tokens":55},"last_token_usage":{"input_tokens":9,"output_tokens":4,"cached_input_tokens":1},"model_context_window":200000}}}
"#,
        )
        .expect("write transcript");

        let usage =
            load_token_usage_from_transcript_path(transcript_path.to_string_lossy().as_ref())
                .await
                .expect("parse usage")
                .expect("usage present");

        // Prefers last_token_usage (current context fill) over total
        assert_eq!(usage.input_tokens, 9);
        assert_eq!(usage.output_tokens, 4);
        assert_eq!(usage.cached_tokens, 1);
        assert_eq!(usage.context_window, 200_000);
    }

    #[tokio::test]
    async fn transcript_turn_context_settings_extract_latest_model_and_effort() {
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-turn-context-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let transcript_path = tmp_dir.join("codex-turn-context.jsonl");

        std::fs::write(
            &transcript_path,
            r#"{"type":"session_meta","payload":{"id":"s","cwd":"/tmp/repo","model_provider":"openai"}}
{"type":"turn_context","payload":{"model":"gpt-5.3-codex","effort":"xhigh"}}
{"type":"turn_context","payload":{"model":"gpt-5.4-codex","effort":"high"}}
"#,
        )
        .expect("write transcript");

        let (model, effort) = load_latest_codex_turn_context_settings_from_transcript_path(
            transcript_path.to_string_lossy().as_ref(),
        )
        .await
        .expect("load settings");

        assert_eq!(model.as_deref(), Some("gpt-5.4-codex"));
        assert_eq!(effort.as_deref(), Some("high"));
    }

    #[tokio::test]
    async fn transcript_turn_context_settings_falls_back_to_reasoning_effort() {
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-turn-context-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let transcript_path = tmp_dir.join("codex-turn-context-collab.jsonl");

        std::fs::write(
            &transcript_path,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.3-codex","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
"#,
        )
        .expect("write transcript");

        let (model, effort) = load_latest_codex_turn_context_settings_from_transcript_path(
            transcript_path.to_string_lossy().as_ref(),
        )
        .await
        .expect("load settings");

        assert_eq!(model.as_deref(), Some("gpt-5.3-codex"));
        assert_eq!(effort.as_deref(), Some("xhigh"));
    }

    #[tokio::test]
    async fn startup_ends_ghost_direct_claude_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                // Ghost: direct Claude session that never initialized (no SDK ID, no prompt, no messages)
                PersistCommand::SessionCreate {
                    id: "claude-ghost".into(),
                    provider: Provider::Claude,
                    project_path: "/tmp/ghost".into(),
                    project_name: Some("ghost".into()),
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-6".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                // Initialized: direct Claude session with SDK ID — should survive
                PersistCommand::SessionCreate {
                    id: "claude-alive".into(),
                    provider: Provider::Claude,
                    project_path: "/tmp/alive".into(),
                    project_name: Some("alive".into()),
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-6".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::SetClaudeSdkSessionId {
                    session_id: "claude-alive".into(),
                    claude_sdk_session_id: "sdk-abc-123".into(),
                },
                // Has messages but no SDK ID — should survive (messages prove it was real)
                PersistCommand::SessionCreate {
                    id: "claude-has-msgs".into(),
                    provider: Provider::Claude,
                    project_path: "/tmp/has-msgs".into(),
                    project_name: Some("has-msgs".into()),
                    branch: Some("main".into()),
                    model: Some("claude-opus-4-6".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::MessageAppend {
                    session_id: "claude-has-msgs".into(),
                    message: Message {
                        id: "msg-1".into(),
                        session_id: "claude-has-msgs".into(),
                        message_type: MessageType::User,
                        content: "hello".into(),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: "2026-02-22T00:00:00Z".into(),
                        duration_ms: None,
                        images: vec![],
                    },
                },
            ],
        )
        .expect("flush batch");

        let _ = load_sessions_for_startup().await.expect("load sessions");

        let conn = Connection::open(&db_path).expect("open db");

        // Ghost should be ended
        let ghost: (String, String, Option<String>) = conn
            .query_row(
                "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
                params!["claude-ghost"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("query ghost");
        assert_eq!(ghost.0, "ended");
        assert_eq!(ghost.1, "ended");
        assert_eq!(ghost.2.as_deref(), Some("startup_ghost_direct"));

        // Initialized session should remain active
        let alive: String = conn
            .query_row(
                "SELECT status FROM sessions WHERE id = ?1",
                params!["claude-alive"],
                |row| row.get(0),
            )
            .expect("query alive");
        assert_eq!(alive, "active");

        // Session with messages should remain active
        let has_msgs: String = conn
            .query_row(
                "SELECT status FROM sessions WHERE id = ?1",
                params!["claude-has-msgs"],
                |row| row.get(0),
            )
            .expect("query has-msgs");
        assert_eq!(has_msgs, "active");
    }

    #[tokio::test]
    async fn startup_ends_ghost_direct_codex_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![
                // Ghost: direct Codex session with no thread_id
                PersistCommand::SessionCreate {
                    id: "codex-ghost".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/codex-ghost".into(),
                    project_name: Some("codex-ghost".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                // Initialized: direct Codex session with thread_id — should survive
                PersistCommand::SessionCreate {
                    id: "codex-alive".into(),
                    provider: Provider::Codex,
                    project_path: "/tmp/codex-alive".into(),
                    project_name: Some("codex-alive".into()),
                    branch: Some("main".into()),
                    model: Some("gpt-5".into()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    forked_from_session_id: None,
                },
                PersistCommand::SetThreadId {
                    session_id: "codex-alive".into(),
                    thread_id: "thread-abc-123".into(),
                },
            ],
        )
        .expect("flush batch");

        let _ = load_sessions_for_startup().await.expect("load sessions");

        let conn = Connection::open(&db_path).expect("open db");

        // Ghost should be ended
        let ghost: (String, String, Option<String>) = conn
            .query_row(
                "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
                params!["codex-ghost"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .expect("query ghost");
        assert_eq!(ghost.0, "ended");
        assert_eq!(ghost.1, "ended");
        assert_eq!(ghost.2.as_deref(), Some("startup_ghost_direct"));

        // Initialized session should remain active
        let alive: String = conn
            .query_row(
                "SELECT status FROM sessions WHERE id = ?1",
                params!["codex-alive"],
                |row| row.get(0),
            )
            .expect("query alive");
        assert_eq!(alive, "active");
    }

    #[tokio::test]
    async fn cleanup_stale_permission_state_repairs_orphaned_permission_sessions() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "orphaned-permission".into(),
                provider: Provider::Claude,
                project_path: "/tmp/orphaned".into(),
                project_name: Some("orphaned".into()),
                branch: Some("main".into()),
                model: Some("claude-sonnet-4-6".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("seed orphaned session");

        let conn = Connection::open(&db_path).expect("open db");
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )
        .expect("set pragmas");
        conn.execute(
            "UPDATE sessions
             SET work_status = 'permission',
                 attention_reason = 'awaitingPermission',
                 pending_tool_name = NULL,
                 pending_tool_input = NULL,
                 pending_question = NULL,
                 pending_approval_id = NULL
             WHERE id = ?1",
            params!["orphaned-permission"],
        )
        .expect("mark orphaned permission state");
        conn.execute(
            "INSERT INTO approval_history (
                 session_id, request_id, approval_type, tool_name, command, file_path, cwd,
                 decision, proposed_amendment, created_at, decided_at
             ) VALUES (?1, ?2, 'exec', 'Bash', 'echo hello', NULL, '/tmp', NULL, NULL, ?3, NULL)",
            params![
                "orphaned-permission",
                "orphaned-request-1",
                "2026-02-28T00:00:00Z"
            ],
        )
        .expect("seed unresolved approval row");
        drop(conn);

        let fixed = cleanup_stale_permission_state().await.expect("run cleanup");
        assert_eq!(fixed, 1, "expected one orphaned session to be repaired");

        let conn = Connection::open(&db_path).expect("reopen db");
        let repaired: (String, String, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT work_status, attention_reason, pending_approval_id, pending_tool_name
                 FROM sessions WHERE id = ?1",
                params!["orphaned-permission"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("query repaired session");
        assert_eq!(repaired.0, "waiting");
        assert_eq!(repaired.1, "awaitingReply");
        assert!(repaired.2.is_none());
        assert!(repaired.3.is_none());

        let decision: Option<String> = conn
            .query_row(
                "SELECT decision FROM approval_history
                 WHERE session_id = ?1 AND request_id = ?2",
                params!["orphaned-permission", "orphaned-request-1"],
                |row| row.get(0),
            )
            .expect("query repaired approval decision");
        assert_eq!(decision.as_deref(), Some("abort"));
    }

    #[test]
    fn display_name_new_style() {
        assert_eq!(
            display_name_from_model_string("claude-opus-4-6"),
            "Opus 4.6"
        );
        assert_eq!(
            display_name_from_model_string("claude-sonnet-4-5"),
            "Sonnet 4.5"
        );
        assert_eq!(
            display_name_from_model_string("claude-haiku-3-5"),
            "Haiku 3.5"
        );
        assert_eq!(
            display_name_from_model_string("claude-sonnet-4-6"),
            "Sonnet 4.6"
        );
    }

    #[test]
    fn display_name_with_date_suffix() {
        assert_eq!(
            display_name_from_model_string("claude-sonnet-4-5-20250514"),
            "Sonnet 4.5"
        );
        assert_eq!(
            display_name_from_model_string("claude-opus-4-6-20260101"),
            "Opus 4.6"
        );
    }

    #[test]
    fn display_name_legacy_format() {
        assert_eq!(
            display_name_from_model_string("claude-3-opus-20240229"),
            "Opus 3"
        );
        assert_eq!(
            display_name_from_model_string("claude-3-5-sonnet-20241022"),
            "Sonnet 3.5"
        );
        assert_eq!(
            display_name_from_model_string("claude-3-5-haiku-20241022"),
            "Haiku 3.5"
        );
    }

    #[test]
    fn display_name_unknown_format() {
        assert_eq!(
            display_name_from_model_string("custom-model"),
            "custom-model"
        );
        assert_eq!(display_name_from_model_string("claude-unknown"), "unknown");
        assert_eq!(display_name_from_model_string("gpt-4o"), "gpt-4o");
    }

    #[test]
    fn display_name_family_only() {
        assert_eq!(display_name_from_model_string("claude-opus"), "Opus");
        assert_eq!(display_name_from_model_string("claude-sonnet"), "Sonnet");
        assert_eq!(display_name_from_model_string("claude-haiku"), "Haiku");
    }
}
