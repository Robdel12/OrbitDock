//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;

mod approvals;
mod commands;
mod config;
mod messages;
pub(crate) mod mission_control;
mod review_comments;
mod session_reads;
mod startup_cleanup;
mod subagents;
mod sync;
mod sync_writer;
mod transcripts;
mod usage;
mod workspace_sync;
mod worktrees;
mod writer;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use orbitdock_connector_codex::rollout_parser::PersistedFileState;
use orbitdock_protocol::conversation_contracts::{ConversationRow, TurnStatus};
use orbitdock_protocol::{
    ApprovalHistoryItem, ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, Provider,
    SessionControlMode, SessionLifecycleState, SessionStatus, TokenUsage, TokenUsageSnapshotKind,
    WorkStatus,
};

pub(crate) use approvals::{delete_approval, list_approvals};
pub(crate) use commands::{ApprovalRequestedParams, PersistCommand, SessionCreateParams};
pub(crate) use config::load_config_value;
pub(crate) use messages::{
    load_message_page_for_session, load_messages_for_session, load_row_by_id_async,
};
#[allow(unused_imports)]
pub(crate) use mission_control::{
    load_all_active_mission_issues, load_mission_by_id, load_mission_cleanup_candidates,
    load_mission_issues, load_mission_tracker_key, load_missions, load_missions_with_counts,
    MissionIssueRow, MissionRow,
};
pub(crate) use review_comments::{list_review_comments, load_review_comment_by_id};
pub(crate) use session_reads::{
    load_direct_claude_owner_by_sdk_session_id, load_session_by_id, load_session_permission_mode,
    load_sessions_for_startup, RestoredSession,
};
pub(crate) use startup_cleanup::{
    cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
};
pub(crate) use subagents::{load_subagent_transcript_path, load_subagents_for_session};
#[cfg(test)]
pub(crate) use sync::SyncSessionCreateParams;
pub(crate) use sync::{SyncBatchRequest, SyncCommand, SyncEnvelope};
pub(crate) use sync_writer::{
    create_sync_channel, create_sync_shutdown_channel, SyncWriter, SyncWriterConfig,
};
#[allow(unused_imports)]
pub(crate) use transcripts::{
    extract_summary_from_transcript, extract_summary_from_transcript_path,
    load_capabilities_from_transcript_path,
    load_latest_codex_turn_context_settings_from_transcript_path,
    load_messages_from_transcript_path, load_token_usage_from_transcript_path,
    TranscriptCapabilities,
};
use usage::{
    persist_usage_event, upsert_usage_session_state, upsert_usage_turn_snapshot, TurnSnapshotRow,
};
pub(crate) use workspace_sync::{
    apply_workspace_sync_batch, resolve_workspace_sync_target, update_workspace_heartbeat,
};
#[allow(unused_imports)]
pub(crate) use worktrees::WorktreeRow;
pub(crate) use worktrees::{
    load_all_worktrees, load_removed_worktree_paths, load_worktree_by_id, load_worktrees_by_repo,
};
#[cfg(test)]
pub(crate) use writer::flush_batch_for_test;
pub(crate) use writer::{create_persistence_channel, PersistenceWriter};

fn persist_subagent_upsert(
    conn: &Connection,
    session_id: &str,
    info: &orbitdock_protocol::SubagentInfo,
) -> Result<(), rusqlite::Error> {
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
                orbitdock_protocol::SubagentStatus::Interrupted => "interrupted",
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
    Ok(())
}

/// Execute a single persist command
pub(super) fn execute_command(
    conn: &Connection,
    cmd: PersistCommand,
) -> Result<(), rusqlite::Error> {
    match cmd {
        PersistCommand::SessionCreate(params) => {
            let SessionCreateParams {
                id,
                provider,
                project_path,
                project_name,
                branch,
                model,
                approval_policy,
                sandbox_mode,
                permission_mode,
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
                codex_config_mode,
                codex_config_profile,
                codex_model_provider,
                codex_config_source,
                codex_config_overrides_json,
                forked_from_session_id,
                mission_id,
                issue_identifier,
                allow_bypass_permissions,
                worktree_id,
                control_mode,
            } = *params;
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
            let control_mode = match control_mode {
                SessionControlMode::Direct => "direct",
                SessionControlMode::Passive => "passive",
            };
            let codex_config_source = codex_config_source.map(|source| match source {
                orbitdock_protocol::CodexConfigSource::Orbitdock => "orbitdock",
                orbitdock_protocol::CodexConfigSource::User => "user",
            });
            let codex_config_mode = codex_config_mode.map(|mode| match mode {
                orbitdock_protocol::CodexConfigMode::Inherit => "inherit",
                orbitdock_protocol::CodexConfigMode::Profile => "profile",
                orbitdock_protocol::CodexConfigMode::Custom => "custom",
            });

            conn.execute(
                "INSERT INTO sessions (id, project_path, project_name, branch, model, provider, status, work_status, lifecycle_state, control_mode, codex_integration_mode, claude_integration_mode, approval_policy, sandbox_mode, permission_mode, collaboration_mode, multi_agent, personality, service_tier, developer_instructions, codex_config_mode, codex_config_profile, codex_model_provider, codex_config_source, codex_config_overrides_json, started_at, last_activity_at, last_progress_at, forked_from_session_id, mission_id, issue_identifier, allow_bypass_permissions, worktree_id, is_worktree)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', 'waiting', 'open', ?8, ?9, ?13, ?10, ?11, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?7, ?7, ?7, ?12, ?24, ?25, ?26, ?27, ?28, ?29)
                 ON CONFLICT(id) DO UPDATE SET
                   project_name = COALESCE(?3, project_name),
                   branch = COALESCE(?4, branch),
                   model = COALESCE(?5, model),
                   control_mode = COALESCE(sessions.control_mode, excluded.control_mode),
                   lifecycle_state = COALESCE(sessions.lifecycle_state, excluded.lifecycle_state),
                   last_activity_at = ?7,
                   last_progress_at = ?7",
                params![id, project_path, project_name, branch, model, provider_str, now, control_mode, codex_integration_mode, approval_policy, sandbox_mode, forked_from_session_id, claude_integration_mode, permission_mode, collaboration_mode, multi_agent, personality, service_tier, developer_instructions, codex_config_mode, codex_config_profile, codex_model_provider, codex_config_source, codex_config_overrides_json, mission_id, issue_identifier, allow_bypass_permissions, worktree_id, worktree_id.is_some()],
            )?;
        }

        PersistCommand::SessionUpdate {
            id,
            status,
            work_status,
            control_mode,
            lifecycle_state,
            last_activity_at,
            last_progress_at,
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
            if let Some(mode) = control_mode {
                updates.push("control_mode = ?");
                params_vec.push(match mode {
                    SessionControlMode::Direct => &"direct",
                    SessionControlMode::Passive => &"passive",
                });
            }
            if let Some(lifecycle_state) = lifecycle_state {
                updates.push(match lifecycle_state {
                    SessionLifecycleState::Open => "lifecycle_state = 'open'",
                    SessionLifecycleState::Resumable => "lifecycle_state = 'resumable'",
                    SessionLifecycleState::Ended => "lifecycle_state = 'ended'",
                });
            } else if matches!(status, Some(SessionStatus::Ended))
                || matches!(work_status, Some(WorkStatus::Ended))
            {
                updates.push("lifecycle_state = 'ended'");
            } else {
                updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')");
            }
            if let Some(ref la) = last_activity_at {
                updates.push("last_activity_at = ?");
                params_vec.push(la);
            }
            if let Some(ref lp) = last_progress_at {
                updates.push("last_progress_at = ?");
                params_vec.push(lp);
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
                "UPDATE sessions SET status = 'ended', work_status = 'ended', lifecycle_state = 'ended', ended_at = ?1, end_reason = ?2, last_activity_at = ?1 WHERE id = ?3",
                params![now, reason, id],
            )?;
        }

        PersistCommand::RowAppend {
            session_id,
            entry,
            viewer_present,
            assigned_sequence,
            sequence_tx,
        } => {
            let row_id = entry.id().to_string();
            let row_type = row_type_str(&entry.row);
            let row_data = serde_json::to_string(&entry.row).unwrap_or_else(|_| "{}".to_string());
            let now = chrono_now();

            // Extract content for last_message updates
            let content_text = extract_row_content(&entry.row);
            let is_user = entry.row.is_user_input();

            // DB computes sequence as MAX(sequence)+1 — single source of truth.
            // ON CONFLICT(id) DO NOTHING deduplicates by PK only — FK violations
            // on session_id still bubble up (unlike INSERT OR IGNORE which swallows all).
            conn.execute(
                "INSERT INTO messages (id, session_id, type, content, timestamp, sequence, row_data, turn_status)
                 VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6,
                   (SELECT MAX(sequence) + 1 FROM messages WHERE session_id = ?2), 0),
                   ?7, ?8)
                 ON CONFLICT(id) DO NOTHING",
                params![
                    row_id,
                    session_id,
                    row_type,
                    content_text.as_deref().unwrap_or(""),
                    now.clone(),
                    assigned_sequence.map(|sequence| sequence as i64),
                    row_data,
                    turn_status_str(entry.turn_status),
                ],
            )?;

            // Read back DB-assigned sequence and send to caller if requested.
            if let Some(tx) = sequence_tx {
                let db_seq: i64 = conn.query_row(
                    "SELECT sequence FROM messages WHERE id = ?1",
                    params![row_id],
                    |row| row.get(0),
                )?;
                let _ = tx.send(db_seq as u64);
            }

            // Update last_message for dashboard context lines (user + assistant only)
            if matches!(
                &entry.row,
                ConversationRow::User(_)
                    | ConversationRow::Steer(_)
                    | ConversationRow::Assistant(_)
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
        }

        PersistCommand::RowUpsert {
            session_id,
            entry,
            viewer_present,
            assigned_sequence,
            sequence_tx,
        } => {
            let row_id = entry.id().to_string();
            let row_type = row_type_str(&entry.row);
            let row_data = serde_json::to_string(&entry.row).unwrap_or_else(|_| "{}".to_string());
            let content_text = extract_row_content(&entry.row);
            let is_user = entry.row.is_user_input();
            let now = chrono_now();

            // DB computes sequence on insert; ON CONFLICT preserves original ordering.
            conn.execute(
                "INSERT INTO messages (id, session_id, type, content, timestamp, sequence, row_data, turn_status)
                 VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6,
                   (SELECT MAX(sequence) + 1 FROM messages WHERE session_id = ?2), 0),
                   ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                   type = excluded.type,
                   content = excluded.content,
                   row_data = excluded.row_data,
                   turn_status = excluded.turn_status",
                params![
                    row_id,
                    session_id,
                    row_type,
                    content_text.as_deref().unwrap_or(""),
                    now.clone(),
                    assigned_sequence.map(|sequence| sequence as i64),
                    row_data,
                    turn_status_str(entry.turn_status),
                ],
            )?;

            // Read back DB-assigned sequence and send to caller if requested.
            if let Some(tx) = sequence_tx {
                let db_seq: i64 = conn.query_row(
                    "SELECT sequence FROM messages WHERE id = ?1",
                    params![row_id],
                    |row| row.get(0),
                )?;
                let _ = tx.send(db_seq as u64);
            }

            // Update last_message for completed user/assistant rows
            if matches!(
                &entry.row,
                ConversationRow::User(_)
                    | ConversationRow::Steer(_)
                    | ConversationRow::Assistant(_)
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

            // Clear current_diff now that the turn diff has been archived
            conn.execute(
                "UPDATE sessions SET current_diff = NULL WHERE id = ?1",
                params![session_id],
            )?;

            upsert_usage_turn_snapshot(
                conn,
                &TurnSnapshotRow {
                    session_id: &session_id,
                    turn_id: &turn_id,
                    turn_seq,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    snapshot_kind,
                },
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
                     lifecycle_state = 'ended',
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
                     lifecycle_state = 'ended',
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
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            model,
            effort,
            codex_config_mode,
            codex_config_profile,
            codex_model_provider,
            codex_config_source,
            codex_config_overrides_json,
        } => {
            let codex_config_source = codex_config_source.map(|source| match source {
                orbitdock_protocol::CodexConfigSource::Orbitdock => "orbitdock",
                orbitdock_protocol::CodexConfigSource::User => "user",
            });
            let codex_config_mode = codex_config_mode.map(|mode| match mode {
                orbitdock_protocol::CodexConfigMode::Inherit => "inherit",
                orbitdock_protocol::CodexConfigMode::Profile => "profile",
                orbitdock_protocol::CodexConfigMode::Custom => "custom",
            });
            let mut updates: Vec<String> = Vec::new();
            let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

            if let Some(value) = approval_policy {
                updates.push("approval_policy = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = sandbox_mode {
                updates.push("sandbox_mode = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = permission_mode {
                updates.push("permission_mode = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = collaboration_mode {
                updates.push("collaboration_mode = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = multi_agent {
                updates.push("multi_agent = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = personality {
                updates.push("personality = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = service_tier {
                updates.push("service_tier = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = developer_instructions {
                updates.push("developer_instructions = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = model {
                updates.push("model = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = effort {
                updates.push("effort = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = codex_config_mode {
                updates.push("codex_config_mode = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = codex_config_profile {
                updates.push("codex_config_profile = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = codex_model_provider {
                updates.push("codex_model_provider = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = codex_config_source {
                updates.push("codex_config_source = ?".to_string());
                params_vec.push(Box::new(value));
            }
            if let Some(value) = codex_config_overrides_json {
                updates.push("codex_config_overrides_json = ?".to_string());
                params_vec.push(Box::new(value));
            }

            if !updates.is_empty() {
                updates.push("last_activity_at = ?".to_string());
                params_vec.push(Box::new(chrono_now()));
                let sql = format!("UPDATE sessions SET {} WHERE id = ?", updates.join(", "));
                params_vec.push(Box::new(session_id));
                let params_refs: Vec<&dyn rusqlite::ToSql> =
                    params_vec.iter().map(|value| value.as_ref()).collect();
                conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
            }
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
            conn.execute(
                "UPDATE sessions
                 SET status = 'active',
                     work_status = 'waiting',
                     lifecycle_state = 'open',
                     ended_at = NULL,
                     end_reason = NULL
                 WHERE id = ?1",
                params![id],
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
                    control_mode, claude_integration_mode, terminal_session_id, terminal_app,
                    started_at, last_activity_at, last_progress_at, forked_from_session_id,
                    repository_root, is_worktree, git_sha
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'claude', 'active', 'waiting', ?8, ?9, ?10, 'passive', 'passive', ?11, ?12, ?13, ?13, ?13, ?14, ?15, ?16, ?17)
                 ON CONFLICT(id) DO UPDATE SET
                    project_path = excluded.project_path,
                    project_name = COALESCE(excluded.project_name, sessions.project_name),
                    branch = COALESCE(excluded.branch, sessions.branch),
                    model = COALESCE(excluded.model, sessions.model),
                    context_label = COALESCE(excluded.context_label, sessions.context_label),
                    transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path),
                    provider = 'claude',
                    codex_integration_mode = NULL,
                    claude_integration_mode = 'passive',
                    control_mode = CASE
                        WHEN sessions.control_mode = 'direct' THEN sessions.control_mode
                        ELSE 'passive'
                    END,
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
                    last_activity_at = excluded.last_activity_at,
                    last_progress_at = excluded.last_progress_at",
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
            let lifecycle_state_is_ended = matches!(work_status.as_deref(), Some("ended"));

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

                if lifecycle_state_is_ended {
                    updates.push("lifecycle_state = 'ended'".to_string());
                } else {
                    updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')".to_string());
                }

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
                     lifecycle_state = 'ended',
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
            persist_subagent_upsert(conn, &session_id, &info)?;
        }

        PersistCommand::UpsertSubagents { session_id, infos } => {
            for info in &infos {
                persist_subagent_upsert(conn, &session_id, info)?;
            }
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
                    provider, status, work_status, control_mode, codex_integration_mode, codex_thread_id,
                    started_at, last_activity_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'codex', 'active', 'waiting', 'passive', 'passive', ?8, ?9, ?10)
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
                    control_mode = CASE
                        WHEN sessions.control_mode = 'direct' THEN sessions.control_mode
                        ELSE 'passive'
                    END,
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

            let lifecycle_state_is_ended = matches!(status, Some(SessionStatus::Ended))
                || matches!(work_status, Some(WorkStatus::Ended));
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

                if lifecycle_state_is_ended {
                    updates.push("lifecycle_state = 'ended'".to_string());
                } else {
                    updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')".to_string());
                }

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

        PersistCommand::UpsertRolloutCheckpoint {
            path,
            offset,
            session_id,
            project_path,
            model_provider,
            ignore_existing,
        } => {
            let now = chrono_now();
            conn.execute(
                "INSERT INTO rollout_checkpoints (
                    path,
                    offset,
                    session_id,
                    project_path,
                    model_provider,
                    ignore_existing,
                    updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(path) DO UPDATE SET
                    offset = excluded.offset,
                    session_id = excluded.session_id,
                    project_path = excluded.project_path,
                    model_provider = excluded.model_provider,
                    ignore_existing = excluded.ignore_existing,
                    updated_at = excluded.updated_at",
                params![
                    path,
                    offset as i64,
                    session_id,
                    project_path,
                    model_provider,
                    ignore_existing as i32,
                    now,
                ],
            )?;
        }

        PersistCommand::DeleteRolloutCheckpoint { path } => {
            conn.execute(
                "DELETE FROM rollout_checkpoints WHERE path = ?1",
                params![path],
            )?;
        }

        PersistCommand::ApprovalRequested(params) => {
            approvals::persist_approval_requested(conn, *params)?
        }

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
            let control_mode = match (codex_mode.as_deref(), claude_mode.as_deref()) {
                (Some("direct"), _) | (_, Some("direct")) => "direct",
                _ => "passive",
            };

            if let Some(m) = codex_mode {
                updates.push("codex_integration_mode = ?");
                params_vec.push(Box::new(m));
            }
            if let Some(m) = claude_mode {
                updates.push("claude_integration_mode = ?");
                params_vec.push(Box::new(m));
            }

            if !updates.is_empty() {
                updates.push("control_mode = ?");
                params_vec.push(Box::new(control_mode.to_string()));
                updates.push("lifecycle_state = COALESCE(lifecycle_state, 'open')");
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

        PersistCommand::MissionCreate {
            id,
            name,
            repo_root,
            tracker_kind,
            provider,
            config_json,
            prompt_template,
            mission_file_path,
            tracker_api_key,
        } => {
            let encrypted_key = tracker_api_key.as_deref().and_then(|k| {
                crate::infrastructure::crypto::encrypt(k)
                    .map_err(|e| tracing::warn!("Failed to encrypt tracker key: {e}"))
                    .ok()
            });
            conn.execute(
                "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, config_json, prompt_template, mission_file_path, tracker_api_key)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![id, name, repo_root, tracker_kind, provider, config_json, prompt_template, mission_file_path, encrypted_key],
            )?;
        }
        PersistCommand::MissionUpdate {
            id,
            name,
            enabled,
            paused,
            tracker_kind,
            config_json,
            prompt_template,
            parse_error,
            mission_file_path,
        } => {
            if let Some(ref name) = name {
                conn.execute(
                    "UPDATE missions SET name = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![name, id],
                )?;
            }
            if let Some(enabled) = enabled {
                conn.execute(
                    "UPDATE missions SET enabled = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![enabled as i64, id],
                )?;
            }
            if let Some(paused) = paused {
                conn.execute(
                    "UPDATE missions SET paused = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![paused as i64, id],
                )?;
            }
            if let Some(ref tracker_kind) = tracker_kind {
                conn.execute(
                    "UPDATE missions SET tracker_kind = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![tracker_kind, id],
                )?;
            }
            if let Some(ref config_json) = config_json {
                conn.execute(
                    "UPDATE missions SET config_json = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![config_json, id],
                )?;
            }
            if let Some(ref prompt_template) = prompt_template {
                conn.execute(
                    "UPDATE missions SET prompt_template = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![prompt_template, id],
                )?;
            }
            if let Some(ref parse_error) = parse_error {
                conn.execute(
                    "UPDATE missions SET parse_error = ?1, last_parsed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![parse_error, id],
                )?;
            }
            if let Some(ref mission_file_path) = mission_file_path {
                conn.execute(
                    "UPDATE missions SET mission_file_path = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                    params![mission_file_path, id],
                )?;
            }
        }
        PersistCommand::MissionSetTrackerKey { mission_id, key } => {
            let stored = match key {
                Some(ref plaintext) => crate::infrastructure::crypto::encrypt(plaintext)
                    .map_err(|e| {
                        tracing::warn!("Failed to encrypt mission tracker key: {e}");
                        rusqlite::Error::ToSqlConversionFailure(Box::new(e))
                    })?
                    .into(),
                None => None,
            };
            conn.execute(
                "UPDATE missions SET tracker_api_key = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?2",
                params![stored, mission_id],
            )?;
        }
        PersistCommand::MissionDelete { id } => {
            conn.execute(
                "DELETE FROM mission_issues WHERE mission_id = ?1",
                params![id],
            )?;
            conn.execute("DELETE FROM missions WHERE id = ?1", params![id])?;
        }
        PersistCommand::MissionIssueUpsert {
            id,
            mission_id,
            issue_id,
            issue_identifier,
            issue_title,
            issue_state,
            orchestration_state,
            provider,
            url,
        } => {
            conn.execute(
                "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, issue_title, issue_state, orchestration_state, provider, url)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(mission_id, issue_id) DO UPDATE SET
                   issue_title = excluded.issue_title,
                   issue_state = excluded.issue_state,
                   url = excluded.url,
                   updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
                params![id, mission_id, issue_id, issue_identifier, issue_title, issue_state, orchestration_state, provider, url],
            )?;
        }
        PersistCommand::MissionIssueUpdateState {
            mission_id,
            issue_id,
            orchestration_state,
            session_id,
            attempt,
            last_error,
            retry_due_at,
            started_at,
            completed_at,
        } => {
            let mut sets = vec![
                "orchestration_state = ?1".to_string(),
                "updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')".to_string(),
            ];
            let mut param_values: Vec<rusqlite::types::Value> = vec![orchestration_state.into()];

            let mut idx = 1u32; // ?1 = orchestration_state
            if let Some(ref val) = session_id {
                idx += 1;
                sets.push(format!("session_id = ?{idx}"));
                param_values.push(val.clone().into());
            }
            if let Some(val) = attempt {
                idx += 1;
                sets.push(format!("attempt = ?{idx}"));
                param_values.push((val as i64).into());
            }
            if let Some(ref val) = last_error {
                idx += 1;
                sets.push(format!("last_error = ?{idx}"));
                param_values.push(
                    val.clone()
                        .map_or(rusqlite::types::Value::Null, |v| v.into()),
                );
            }
            if let Some(ref val) = retry_due_at {
                idx += 1;
                sets.push(format!("retry_due_at = ?{idx}"));
                param_values.push(
                    val.clone()
                        .map_or(rusqlite::types::Value::Null, |v| v.into()),
                );
            }
            if let Some(ref val) = started_at {
                idx += 1;
                sets.push(format!("started_at = ?{idx}"));
                param_values.push(
                    val.clone()
                        .map_or(rusqlite::types::Value::Null, |v| v.into()),
                );
            }
            if let Some(ref val) = completed_at {
                idx += 1;
                sets.push(format!("completed_at = ?{idx}"));
                param_values.push(
                    val.clone()
                        .map_or(rusqlite::types::Value::Null, |v| v.into()),
                );
            }

            // WHERE clause params
            let mid_idx = idx + 1;
            let iid_idx = idx + 2;
            param_values.push(mission_id.into());
            param_values.push(issue_id.into());

            let sql = format!(
                "UPDATE mission_issues SET {} WHERE mission_id = ?{mid_idx} AND issue_id = ?{iid_idx}",
                sets.join(", ")
            );
            let param_refs: Vec<&dyn rusqlite::types::ToSql> = param_values
                .iter()
                .map(|v| v as &dyn rusqlite::types::ToSql)
                .collect();
            conn.execute(&sql, param_refs.as_slice())?;
        }

        PersistCommand::MissionIssueSetPrUrl {
            mission_id,
            issue_id,
            pr_url,
        } => {
            conn.execute(
                "UPDATE mission_issues SET pr_url = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE mission_id = ?2 AND issue_id = ?3",
                rusqlite::params![pr_url, mission_id, issue_id],
            )?;
        }
        PersistCommand::RowsTurnStatusUpdate {
            session_id,
            row_ids,
            status,
        } => {
            let status_str = turn_status_str(status);
            for row_id in &row_ids {
                conn.execute(
                    "UPDATE messages SET turn_status = ?1 WHERE session_id = ?2 AND id = ?3",
                    rusqlite::params![status_str, session_id, row_id],
                )?;
            }
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

pub fn load_rollout_checkpoints(
    db_path: &Path,
) -> anyhow::Result<HashMap<String, PersistedFileState>> {
    if !db_path.exists() {
        return Ok(HashMap::new());
    }

    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )?;

    let mut stmt = conn.prepare(
        "SELECT path, offset, session_id, project_path, model_provider, ignore_existing
         FROM rollout_checkpoints",
    )?;
    let rows = stmt.query_map([], |row| {
        let path: String = row.get(0)?;
        let offset: i64 = row.get(1)?;
        let session_id: Option<String> = row.get(2)?;
        let project_path: Option<String> = row.get(3)?;
        let model_provider: Option<String> = row.get(4)?;
        let ignore_existing: i64 = row.get(5)?;

        Ok((
            path,
            PersistedFileState {
                offset: offset.max(0) as u64,
                session_id,
                project_path,
                model_provider,
                ignore_existing: Some(ignore_existing != 0),
            },
        ))
    })?;

    let mut checkpoints = HashMap::new();
    for row in rows {
        let (path, state) = row?;
        checkpoints.insert(path, state);
    }

    Ok(checkpoints)
}

/// Get current time as ISO 8601 string
fn row_type_str(row: &ConversationRow) -> &'static str {
    match row {
        ConversationRow::User(_) => "user",
        ConversationRow::Steer(_) => "steer",
        ConversationRow::Assistant(_) => "assistant",
        ConversationRow::Thinking(_) => "thinking",
        ConversationRow::Context(_) => "context",
        ConversationRow::Notice(_) => "notice",
        ConversationRow::ShellCommand(_) => "shell_command",
        ConversationRow::Task(_) => "task",
        ConversationRow::Tool(_) => "tool",
        ConversationRow::ActivityGroup(_) => "activity_group",
        ConversationRow::Question(_) => "question",
        ConversationRow::Approval(_) => "approval",
        ConversationRow::Worker(_) => "worker",
        ConversationRow::Plan(_) => "plan",
        ConversationRow::Hook(_) => "hook",
        ConversationRow::Handoff(_) => "handoff",
        ConversationRow::System(_) => "system",
    }
}

fn turn_status_str(status: TurnStatus) -> &'static str {
    match status {
        TurnStatus::Active => "active",
        TurnStatus::Undone => "undone",
        TurnStatus::RolledBack => "rolled_back",
    }
}

fn extract_row_content(row: &ConversationRow) -> Option<String> {
    match row {
        ConversationRow::User(m)
        | ConversationRow::Steer(m)
        | ConversationRow::Assistant(m)
        | ConversationRow::Thinking(m)
        | ConversationRow::System(m) => Some(m.content.clone()),
        ConversationRow::Context(c) => Some(c.summary.clone().unwrap_or_else(|| c.title.clone())),
        ConversationRow::Notice(n) => Some(n.summary.clone().unwrap_or_else(|| n.title.clone())),
        ConversationRow::ShellCommand(s) => Some(
            s.summary
                .clone()
                .or_else(|| s.command.clone())
                .unwrap_or_else(|| s.title.clone()),
        ),
        ConversationRow::Task(t) => Some(t.summary.clone().unwrap_or_else(|| t.title.clone())),
        ConversationRow::Tool(t) => Some(t.title.clone()),
        ConversationRow::Plan(p) => Some(p.title.clone()),
        ConversationRow::Hook(h) => Some(h.title.clone()),
        ConversationRow::Handoff(h) => Some(h.title.clone()),
        ConversationRow::Worker(w) => Some(w.title.clone()),
        ConversationRow::Approval(a) => Some(a.id.clone()),
        ConversationRow::Question(q) => Some(q.id.clone()),
        ConversationRow::ActivityGroup(g) => Some(g.title.clone()),
    }
}

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

#[cfg(test)]
mod rollout_checkpoint_tests {
    use super::{execute_command, load_rollout_checkpoints};
    use crate::infrastructure::migration_runner::run_migrations;
    use crate::infrastructure::persistence::PersistCommand;
    use rusqlite::Connection;

    #[test]
    fn rollout_checkpoint_upsert_and_load_round_trip() {
        let db_path = std::env::temp_dir().join(format!(
            "orbitdock-rollout-checkpoint-test-{}-a.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&db_path);
        let mut conn = Connection::open(&db_path).expect("open db");
        run_migrations(&mut conn).expect("run migrations");

        execute_command(
            &conn,
            PersistCommand::UpsertRolloutCheckpoint {
                path: "/tmp/rollout-a.jsonl".to_string(),
                offset: 42,
                session_id: Some("session-1".to_string()),
                project_path: Some("/tmp/project".to_string()),
                model_provider: Some("codex".to_string()),
                ignore_existing: true,
            },
        )
        .expect("persist checkpoint");

        let checkpoints = load_rollout_checkpoints(&db_path).expect("load checkpoints");
        let checkpoint = checkpoints
            .get("/tmp/rollout-a.jsonl")
            .expect("checkpoint stored");
        assert_eq!(checkpoint.offset, 42);
        assert_eq!(checkpoint.session_id.as_deref(), Some("session-1"));
        assert_eq!(checkpoint.project_path.as_deref(), Some("/tmp/project"));
        assert_eq!(checkpoint.model_provider.as_deref(), Some("codex"));
        assert_eq!(checkpoint.ignore_existing, Some(true));

        let _ = std::fs::remove_file(db_path);
    }

    #[test]
    fn rollout_checkpoint_delete_removes_row() {
        let db_path = std::env::temp_dir().join(format!(
            "orbitdock-rollout-checkpoint-test-{}-b.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&db_path);
        let mut conn = Connection::open(&db_path).expect("open db");
        run_migrations(&mut conn).expect("run migrations");

        execute_command(
            &conn,
            PersistCommand::UpsertRolloutCheckpoint {
                path: "/tmp/rollout-b.jsonl".to_string(),
                offset: 7,
                session_id: None,
                project_path: None,
                model_provider: None,
                ignore_existing: false,
            },
        )
        .expect("persist checkpoint");

        execute_command(
            &conn,
            PersistCommand::DeleteRolloutCheckpoint {
                path: "/tmp/rollout-b.jsonl".to_string(),
            },
        )
        .expect("delete checkpoint");

        let remaining: i64 = conn
            .query_row("SELECT COUNT(*) FROM rollout_checkpoints", [], |row| {
                row.get(0)
            })
            .expect("count checkpoints");
        assert_eq!(remaining, 0);

        let _ = std::fs::remove_file(db_path);
    }
}

fn is_leap_year(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

#[cfg(test)]
mod tests;
