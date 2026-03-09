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
            crate::infrastructure::paths::reset_data_dir();
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        TEST_ENV_LOCK.get_or_init(|| Mutex::new(()))
    }

    fn set_test_data_dir(home: &Path) -> DataDirGuard {
        crate::infrastructure::paths::init_data_dir(Some(&home.join(".orbitdock")));
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
                    sequence: None,
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
                        sequence: None,
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
                    tool_input: Some(r#"{"command":"echo first"}"#.into()),
                    command: Some("echo first".into()),
                    file_path: None,
                    diff: None,
                    question: None,
                    question_prompts: vec![],
                    preview: None,
                    cwd: Some("/tmp/approval-upsert".into()),
                    proposed_amendment: None,
                    permission_suggestions: None,
                },
                PersistCommand::ApprovalRequested {
                    session_id: "approval-upsert-session".into(),
                    request_id: "req-1".into(),
                    approval_type: ApprovalType::Exec,
                    tool_name: Some("Bash".into()),
                    tool_input: Some(r#"{"command":"echo updated"}"#.into()),
                    command: Some("echo updated".into()),
                    file_path: None,
                    diff: None,
                    question: None,
                    question_prompts: vec![],
                    preview: None,
                    cwd: Some("/tmp/approval-upsert".into()),
                    proposed_amendment: None,
                    permission_suggestions: None,
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

    #[tokio::test]
    async fn approval_requested_persists_rich_payload_and_list_approvals_decodes_it() {
        let home = create_test_home();
        let _dd_guard = set_test_data_dir(&home);
        let db_path = home.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        flush_batch(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: "approval-rich-session".into(),
                provider: Provider::Claude,
                project_path: "/tmp/approval-rich".into(),
                project_name: Some("approval-rich".into()),
                branch: Some("main".into()),
                model: Some("claude-opus".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: Some("plan".into()),
                forked_from_session_id: None,
            }],
        )
        .expect("seed approval rich session");

        flush_batch(
            &db_path,
            vec![PersistCommand::ApprovalRequested {
                session_id: "approval-rich-session".into(),
                request_id: "req-rich-1".into(),
                approval_type: ApprovalType::Exec,
                tool_name: Some("ExitPlanMode".into()),
                tool_input: Some(
                    r##"{"plan":"# Plan\n1. Simplify toolbar ordering UX","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}]}"##
                        .into(),
                ),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                question_prompts: vec![],
                preview: Some(ApprovalPreview {
                    preview_type: orbitdock_protocol::ApprovalPreviewType::Prompt,
                    value: "# Plan\n1. Simplify toolbar ordering UX".into(),
                    shell_segments: vec![],
                    compact: Some("Plan".into()),
                    decision_scope: Some("approve/deny applies to this full tool action.".into()),
                    risk_level: Some(orbitdock_protocol::ApprovalRiskLevel::Normal),
                    risk_findings: vec![],
                    manifest: Some("manifest".into()),
                }),
                cwd: Some("/tmp/approval-rich".into()),
                proposed_amendment: Some(vec!["run tests".into()]),
                permission_suggestions: Some(serde_json::json!([
                    {
                        "type": "addRules",
                        "behavior": "allow",
                        "destination": "session"
                    }
                ])),
            }],
        )
        .expect("persist approval request");

        let approvals = list_approvals(Some("approval-rich-session".into()), Some(10))
            .await
            .expect("list approvals");
        assert_eq!(approvals.len(), 1);

        let approval = &approvals[0];
        assert_eq!(approval.request_id, "req-rich-1");
        assert_eq!(approval.tool_name.as_deref(), Some("ExitPlanMode"));
        assert_eq!(
            approval.tool_input.as_deref(),
            Some(
                r##"{"plan":"# Plan\n1. Simplify toolbar ordering UX","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}]}"##
            )
        );
        assert_eq!(
            approval
                .preview
                .as_ref()
                .map(|preview| preview.value.as_str()),
            Some("# Plan\n1. Simplify toolbar ordering UX")
        );
        assert_eq!(
            approval.proposed_amendment.as_ref(),
            Some(&vec!["run tests".to_string()])
        );
        assert!(approval.permission_suggestions.is_some());
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
                        sequence: None,
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
                        sequence: None,
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
