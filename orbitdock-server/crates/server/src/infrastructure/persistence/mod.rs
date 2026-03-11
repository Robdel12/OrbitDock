//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::collections::HashSet;
use std::path::PathBuf;

mod approvals;
mod commands;
mod config;
mod messages;
mod review_comments;
mod session_reads;
mod startup_cleanup;
mod subagents;
mod transcripts;
mod usage;
mod worktrees;
mod writer;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use tracing::{info, warn};

use orbitdock_protocol::{
    ApprovalHistoryItem, ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, Message,
    MessageType, Provider, SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

pub(crate) use approvals::{delete_approval, list_approvals};
pub(crate) use commands::PersistCommand;
pub(crate) use config::{
    backfill_claude_models_from_sessions, display_name_from_model_string,
    load_cached_claude_models, load_config_value,
};
pub(crate) use messages::{load_message_page_for_session, load_messages_for_session};
pub(crate) use review_comments::{list_review_comments, load_review_comment_by_id};
pub(crate) use session_reads::{
    load_session_by_id, load_session_permission_mode, load_sessions_for_startup, RestoredSession,
};
pub(crate) use startup_cleanup::{
    cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
};
pub(crate) use subagents::{load_subagent_transcript_path, load_subagents_for_session};
#[allow(unused_imports)]
pub(crate) use transcripts::{
    extract_summary_from_transcript, extract_summary_from_transcript_path,
    load_capabilities_from_transcript_path,
    load_latest_codex_turn_context_settings_from_transcript_path,
    load_messages_from_transcript_path, load_token_usage_from_transcript_path,
    TranscriptCapabilities,
};
use usage::{persist_usage_event, upsert_usage_session_state, upsert_usage_turn_snapshot};
#[allow(unused_imports)]
pub(crate) use worktrees::WorktreeRow;
pub(crate) use worktrees::{
    load_removed_worktree_paths, load_worktree_by_id, load_worktrees_by_repo,
};
pub(crate) use writer::{create_persistence_channel, PersistenceWriter};
#[cfg(test)]
pub(crate) use writer::{flush_batch, flush_batch_for_test};

/// Execute a single persist command
pub(super) fn execute_command(
    conn: &Connection,
    cmd: PersistCommand,
) -> Result<(), rusqlite::Error> {
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

            let seq: i64 = match message
                .sequence
                .and_then(|sequence| i64::try_from(sequence).ok())
            {
                Some(sequence) => sequence,
                None => conn.query_row(
                    "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE session_id = ?",
                    params![session_id],
                    |row| row.get(0),
                )?,
            };

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
                "INSERT INTO subagents (
                    id,
                    session_id,
                    agent_type,
                    provider,
                    label,
                    status,
                    started_at,
                    last_activity_at
                 )
                 VALUES (?1, ?2, ?3, 'claude', ?4, 'running', ?5, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                   session_id = excluded.session_id,
                   agent_type = excluded.agent_type,
                   provider = excluded.provider,
                   label = excluded.label,
                   status = excluded.status,
                   started_at = excluded.started_at,
                   last_activity_at = excluded.last_activity_at",
                params![id, session_id, agent_type, agent_type, now],
            )?;
        }

        PersistCommand::ClaudeSubagentEnd {
            id,
            transcript_path,
        } => {
            let now = chrono_now();
            conn.execute(
                "UPDATE subagents
                 SET ended_at = ?1,
                     transcript_path = ?2,
                     status = 'completed',
                     last_activity_at = ?1
                 WHERE id = ?3",
                params![now, transcript_path, id],
            )?;
        }

        PersistCommand::UpsertSubagent { session_id, info } => {
            conn.execute(
                "INSERT INTO subagents (
                    id,
                    session_id,
                    agent_type,
                    transcript_path,
                    started_at,
                    ended_at,
                    provider,
                    label,
                    status,
                    task_summary,
                    result_summary,
                    error_summary,
                    parent_subagent_id,
                    model,
                    last_activity_at
                 )
                 VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                 ON CONFLICT(id) DO UPDATE SET
                    session_id = excluded.session_id,
                    agent_type = excluded.agent_type,
                    ended_at = CASE
                        WHEN subagents.status = 'completed'
                             AND excluded.status != 'completed'
                            THEN subagents.ended_at
                        WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                             AND excluded.status IN ('pending', 'running')
                            THEN subagents.ended_at
                        WHEN subagents.status IN ('failed', 'cancelled', 'not_found')
                             AND excluded.status = 'shutdown'
                            THEN subagents.ended_at
                        ELSE COALESCE(excluded.ended_at, subagents.ended_at)
                    END,
                    provider = COALESCE(excluded.provider, subagents.provider),
                    label = COALESCE(excluded.label, subagents.label),
                    status = CASE
                        WHEN subagents.status = 'completed'
                             AND excluded.status != 'completed'
                            THEN subagents.status
                        WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                             AND excluded.status IN ('pending', 'running')
                            THEN subagents.status
                        WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                             AND excluded.status = 'shutdown'
                            THEN subagents.status
                        ELSE excluded.status
                    END,
                    task_summary = COALESCE(excluded.task_summary, subagents.task_summary),
                    result_summary = CASE
                        WHEN subagents.status = 'completed'
                             AND excluded.status != 'completed'
                            THEN subagents.result_summary
                        WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                             AND excluded.status IN ('pending', 'running')
                            THEN subagents.result_summary
                        WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                             AND excluded.status = 'shutdown'
                            THEN subagents.result_summary
                        ELSE COALESCE(excluded.result_summary, subagents.result_summary)
                    END,
                    error_summary = CASE
                        WHEN subagents.status = 'completed'
                             AND excluded.status != 'completed'
                            THEN subagents.error_summary
                        WHEN subagents.status IN ('failed', 'cancelled', 'shutdown', 'not_found')
                             AND excluded.status IN ('pending', 'running')
                            THEN subagents.error_summary
                        WHEN subagents.status IN ('completed', 'failed', 'cancelled', 'not_found')
                             AND excluded.status = 'shutdown'
                            THEN subagents.error_summary
                        ELSE COALESCE(excluded.error_summary, subagents.error_summary)
                    END,
                    parent_subagent_id = COALESCE(excluded.parent_subagent_id, subagents.parent_subagent_id),
                    model = COALESCE(excluded.model, subagents.model),
                    last_activity_at = excluded.last_activity_at",
                params![
                    info.id,
                    session_id,
                    info.agent_type,
                    info.started_at,
                    info.ended_at,
                    info.provider.map(|provider| match provider {
                        Provider::Claude => "claude",
                        Provider::Codex => "codex",
                    }),
                    info.label,
                    match info.status {
                        orbitdock_protocol::SubagentStatus::Pending => "pending",
                        orbitdock_protocol::SubagentStatus::Running => "running",
                        orbitdock_protocol::SubagentStatus::Completed => "completed",
                        orbitdock_protocol::SubagentStatus::Failed => "failed",
                        orbitdock_protocol::SubagentStatus::Cancelled => "cancelled",
                        orbitdock_protocol::SubagentStatus::Shutdown => "shutdown",
                        orbitdock_protocol::SubagentStatus::NotFound => "not_found",
                    },
                    info.task_summary,
                    info.result_summary,
                    info.error_summary,
                    info.parent_subagent_id,
                    info.model,
                    info.last_activity_at,
                ],
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
            tool_input,
            command,
            file_path,
            diff,
            question,
            question_prompts,
            preview,
            cwd,
            proposed_amendment,
            permission_suggestions,
        } => approvals::persist_approval_requested(
            conn,
            approvals::ApprovalRequestedRecord {
                session_id,
                request_id,
                approval_type,
                tool_name,
                tool_input,
                command,
                file_path,
                diff,
                question,
                question_prompts,
                preview,
                cwd,
                proposed_amendment,
                permission_suggestions,
            },
        )?,

        PersistCommand::ApprovalDecision {
            session_id,
            request_id,
            decision,
        } => approvals::persist_approval_decision(conn, session_id, request_id, decision)?,

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
            let stored_value = crate::infrastructure::crypto::encrypt(&value)
                .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?;
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
    let db_path = crate::infrastructure::paths::db_path();

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

#[cfg(test)]
mod tests;
