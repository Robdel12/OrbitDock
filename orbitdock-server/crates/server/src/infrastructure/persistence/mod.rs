//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::collections::HashSet;
use std::path::PathBuf;

mod approvals;
mod commands;
mod config;
mod config_writes;
mod connector_writes;
mod messages;
pub(crate) mod mission_control;
mod mission_writes;
mod review_comments;
mod review_writes;
mod session_reads;
mod session_writes;
mod startup_cleanup;
mod subagent_writes;
mod subagents;
mod sync;
mod sync_outbox;
mod sync_writer;
mod transcripts;
mod usage;
mod workspace_sync;
mod workspaces;
mod worktree_writes;
mod worktrees;
mod writer;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use orbitdock_protocol::conversation_contracts::{ConversationRow, TurnStatus};
use orbitdock_protocol::{
  ApprovalHistoryItem, ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, Provider, TokenUsage,
  TokenUsageSnapshotKind,
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
  load_direct_claude_owner_by_sdk_session_id, load_direct_codex_owner_by_thread_id,
  load_session_by_id, load_session_metadata_by_id, load_session_permission_mode,
  load_sessions_for_startup, RestoredSession,
};
pub(crate) use startup_cleanup::{
  cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
};
pub(crate) use subagents::{load_subagent_transcript_path, load_subagents_for_session};
#[cfg(test)]
pub(crate) use sync::SyncSessionCreateParams;
pub(crate) use sync::{SyncBatchRequest, SyncCommand, SyncEnvelope};
pub(crate) use sync_outbox::{
  acknowledge_sync_outbox, append_sync_outbox_commands, current_sync_acked_through,
  load_pending_sync_envelopes,
};
pub(crate) use sync_writer::{create_sync_shutdown_channel, SyncWriter, SyncWriterConfig};
#[allow(unused_imports)]
pub(crate) use transcripts::{
  extract_summary_from_transcript, extract_summary_from_transcript_path,
  load_capabilities_from_transcript_path,
  load_latest_codex_turn_context_settings_from_transcript_path, load_messages_from_transcript_path,
  load_token_usage_from_transcript_path, TranscriptCapabilities,
};
use usage::{
  persist_usage_event, recompute_usage_ledger_for_session, upsert_usage_session_state,
  upsert_usage_turn_snapshot, TurnSnapshotRow,
};
pub(crate) use usage::{repair_usage_accounting_if_needed, snapshot_kind_from_str};
pub(crate) use workspace_sync::{
  apply_workspace_sync_batch, resolve_workspace_sync_target, update_workspace_heartbeat,
};
pub(crate) use workspaces::{
  insert_workspace_record, load_workspace_record, update_workspace_record, WorkspaceRecord,
  WorkspaceRecordInsert, WorkspaceRecordUpdate,
};
#[allow(unused_imports)]
pub(crate) use worktrees::WorktreeRow;
pub(crate) use worktrees::{
  load_all_worktrees, load_removed_worktree_paths, load_worktree_by_id, load_worktrees_by_repo,
};
#[cfg(test)]
pub(crate) use writer::flush_batch_for_test;
pub(crate) use writer::{create_persistence_channel, PersistenceWriter};

fn claude_shadow_is_owned_by_direct_session(
  conn: &Connection,
  session_id: &str,
) -> Result<bool, rusqlite::Error> {
  let exists: i64 = conn.query_row(
    "SELECT EXISTS(
            SELECT 1
            FROM sessions direct
            WHERE direct.provider = 'claude'
              AND direct.claude_sdk_session_id = ?1
              AND COALESCE(direct.control_mode, CASE
                    WHEN direct.provider = 'claude'
                         AND direct.claude_integration_mode = 'direct'
                        THEN 'direct'
                    ELSE 'passive'
                  END) = 'direct'
        )",
    params![session_id],
    |row| row.get(0),
  )?;

  Ok(exists == 1)
}

fn preserve_direct_owned_claude_shadow(
  conn: &Connection,
  session_id: &str,
  reason: &str,
) -> Result<bool, rusqlite::Error> {
  if !claude_shadow_is_owned_by_direct_session(conn, session_id)? {
    return Ok(false);
  }

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
                 pending_approval_id = NULL,
                 active_subagent_id = NULL,
                 active_subagent_type = NULL
             WHERE id = ?3
               AND provider = 'claude'
               AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')",
    params![now, reason, session_id],
  )?;

  Ok(true)
}

#[allow(dead_code)]
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
            info.agent_type.as_str(),
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

/// Execute a single persist command.
///
/// Keep this as the single writer entrypoint, but fan out to write families so
/// persistence ownership is explicit instead of one monolithic match arm.
pub(super) fn execute_command(
  conn: &Connection,
  cmd: PersistCommand,
) -> Result<(), rusqlite::Error> {
  execute_command_by_family(conn, cmd)
}

fn execute_command_by_family(
  conn: &Connection,
  cmd: PersistCommand,
) -> Result<(), rusqlite::Error> {
  match cmd {
    PersistCommand::SessionCreate(params) => session_writes::persist_session_create(conn, *params)?,
    PersistCommand::SessionUpdate {
      id,
      status,
      work_status,
      control_mode,
      lifecycle_state,
      last_activity_at,
      last_progress_at,
    } => session_writes::persist_session_update(
      conn,
      session_writes::SessionUpdateRecord {
        id,
        status,
        work_status,
        control_mode,
        lifecycle_state,
        last_activity_at,
        last_progress_at,
      },
    )?,
    PersistCommand::SessionEnd { id, reason } => {
      session_writes::persist_session_end(conn, id, reason)?
    }
    PersistCommand::RowAppend {
      session_id,
      entry,
      viewer_present,
      assigned_sequence,
      sequence_tx,
    } => session_writes::persist_row_append(
      conn,
      session_id,
      entry,
      viewer_present,
      assigned_sequence,
      sequence_tx,
    )?,
    PersistCommand::RowUpsert {
      session_id,
      entry,
      viewer_present,
      assigned_sequence,
      sequence_tx,
    } => session_writes::persist_row_upsert(
      conn,
      session_id,
      entry,
      viewer_present,
      assigned_sequence,
      sequence_tx,
    )?,
    PersistCommand::TokensUpdate {
      session_id,
      usage,
      snapshot_kind,
    } => session_writes::persist_tokens_update(conn, session_id, usage, snapshot_kind)?,
    PersistCommand::TurnStateUpdate {
      session_id,
      diff,
      plan,
    } => session_writes::persist_turn_state_update(conn, session_id, diff, plan)?,
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
    } => session_writes::persist_turn_diff_insert(
      conn,
      session_writes::TurnDiffInsertRecord {
        session_id,
        turn_id,
        turn_seq,
        diff,
        input_tokens,
        output_tokens,
        cached_tokens,
        context_window,
        snapshot_kind,
      },
    )?,
    PersistCommand::SetThreadId {
      session_id,
      thread_id,
    } => session_writes::persist_set_thread_id(conn, session_id, thread_id)?,
    PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
      session_writes::persist_cleanup_thread_shadow_session(conn, thread_id, reason)?
    }
    PersistCommand::SetClaudeSdkSessionId {
      session_id,
      claude_sdk_session_id,
    } => {
      session_writes::persist_set_claude_sdk_session_id(conn, session_id, claude_sdk_session_id)?
    }
    PersistCommand::CleanupClaudeShadowSession {
      claude_sdk_session_id,
      reason,
    } => {
      session_writes::persist_cleanup_claude_shadow_session(conn, claude_sdk_session_id, reason)?
    }
    PersistCommand::SetCustomName {
      session_id,
      custom_name,
    } => session_writes::persist_set_custom_name(conn, session_id, custom_name)?,
    PersistCommand::SetSummary {
      session_id,
      summary,
    } => session_writes::persist_set_summary(conn, session_id, summary)?,
    PersistCommand::SetTranscriptPath {
      session_id,
      transcript_path,
    } => session_writes::persist_set_transcript_path(conn, session_id, transcript_path)?,
    PersistCommand::SessionAttentionUpdate {
      session_id,
      attention_reason,
      last_tool,
      last_tool_at,
      pending_tool_name,
      pending_tool_input,
      pending_question,
    } => session_writes::persist_session_attention_update(
      conn,
      session_writes::SessionAttentionUpdateRecord {
        session_id,
        attention_reason,
        last_tool,
        last_tool_at,
        pending_tool_name,
        pending_tool_input,
        pending_question,
      },
    )?,
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
    } => session_writes::persist_set_session_config(
      conn,
      session_writes::SessionConfigRecord {
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
        codex_config_mode: codex_config_mode.map(Some),
        codex_config_profile: codex_config_profile.map(Some),
        codex_model_provider: codex_model_provider.map(Some),
        codex_config_source: codex_config_source.map(Some),
        codex_config_overrides_json: codex_config_overrides_json.map(Some),
      },
    )?,
    PersistCommand::MarkSessionRead {
      session_id,
      up_to_sequence,
    } => session_writes::persist_mark_session_read(conn, session_id, up_to_sequence)?,
    PersistCommand::ReactivateSession { id } => {
      session_writes::persist_reactivate_session(conn, id)?
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
    } => connector_writes::persist_claude_session_upsert(
      conn,
      connector_writes::ClaudeSessionUpsertRecord {
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
      },
    )?,
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
    } => connector_writes::persist_claude_session_update(
      conn,
      connector_writes::ClaudeSessionUpdateRecord {
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
      },
    )?,
    PersistCommand::ClaudeSessionEnd { id, reason } => {
      connector_writes::persist_claude_session_end(conn, id, reason)?
    }
    PersistCommand::ClaudePromptIncrement { id, first_prompt } => {
      connector_writes::persist_claude_prompt_increment(conn, id, first_prompt)?
    }
    PersistCommand::ClaudeToolIncrement { id } => {
      connector_writes::persist_claude_tool_increment(conn, id)?
    }
    PersistCommand::ToolCountIncrement { session_id } => {
      connector_writes::persist_tool_count_increment(conn, session_id)?
    }
    PersistCommand::ModelUpdate { session_id, model } => {
      session_writes::persist_model_update(conn, session_id, model)?
    }
    PersistCommand::EffortUpdate { session_id, effort } => {
      session_writes::persist_effort_update(conn, session_id, effort)?
    }
    PersistCommand::ClaudeSubagentStart {
      id,
      session_id,
      agent_type,
    } => subagent_writes::persist_claude_subagent_start(conn, id, session_id, agent_type)?,
    PersistCommand::ClaudeSubagentEnd {
      id,
      transcript_path,
    } => subagent_writes::persist_claude_subagent_end(conn, id, transcript_path)?,
    PersistCommand::UpsertSubagent { session_id, info } => {
      subagent_writes::persist_upsert_subagent(conn, session_id, info)?
    }
    PersistCommand::UpsertSubagents { session_id, infos } => {
      subagent_writes::persist_upsert_subagents(conn, session_id, infos)?
    }
    PersistCommand::CodexPromptIncrement { id, first_prompt } => {
      connector_writes::persist_codex_prompt_increment(conn, id, first_prompt)?
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
    } => review_writes::persist_review_comment_create(
      conn,
      review_writes::ReviewCommentCreateRecord {
        id,
        session_id,
        turn_id,
        file_path,
        line_start: Some(line_start as i64),
        line_end: line_end.map(|value| value as i64),
        body,
        tag,
      },
    )?,
    PersistCommand::ReviewCommentUpdate {
      id,
      body,
      tag,
      status,
    } => review_writes::persist_review_comment_update(conn, id, body, tag, status)?,
    PersistCommand::ReviewCommentDelete { id } => {
      review_writes::persist_review_comment_delete(conn, id)?
    }
    PersistCommand::SetIntegrationMode {
      session_id,
      codex_mode,
      claude_mode,
    } => session_writes::persist_set_integration_mode(conn, session_id, codex_mode, claude_mode)?,
    PersistCommand::EnvironmentUpdate {
      session_id,
      cwd,
      git_branch,
      git_sha,
      repository_root,
      is_worktree,
    } => session_writes::persist_environment_update(
      conn,
      session_id,
      cwd,
      git_branch,
      git_sha,
      repository_root,
      is_worktree,
    )?,
    PersistCommand::SetConfig { key, value } => {
      config_writes::persist_set_config(conn, key, value)?
    }
    PersistCommand::WorktreeCreate {
      id,
      repo_root,
      worktree_path,
      branch,
      base_branch,
      created_by,
    } => worktree_writes::persist_worktree_create(
      conn,
      id,
      repo_root,
      worktree_path,
      branch,
      base_branch,
      Some(created_by),
    )?,
    PersistCommand::WorktreeUpdateStatus {
      id,
      status,
      last_session_ended_at,
    } => worktree_writes::persist_worktree_update_status(conn, id, status, last_session_ended_at)?,
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
    } => mission_writes::persist_mission_create(
      conn,
      mission_writes::MissionCreateRecord {
        id,
        name,
        repo_root,
        tracker_kind,
        provider,
        config_json,
        prompt_template,
        mission_file_path,
        tracker_api_key,
      },
    )?,
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
    } => mission_writes::persist_mission_update(
      conn,
      mission_writes::MissionUpdateRecord {
        id,
        name,
        enabled,
        paused,
        tracker_kind,
        config_json,
        prompt_template,
        parse_error,
        mission_file_path,
      },
    )?,
    PersistCommand::MissionSetTrackerKey { mission_id, key } => {
      mission_writes::persist_mission_set_tracker_key(conn, mission_id, key)?
    }
    PersistCommand::MissionDelete { id } => mission_writes::persist_mission_delete(conn, id)?,
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
    } => mission_writes::persist_mission_issue_upsert(
      conn,
      mission_writes::MissionIssueUpsertRecord {
        id,
        mission_id,
        issue_id,
        issue_identifier,
        issue_title,
        issue_state,
        orchestration_state,
        provider,
        url,
      },
    )?,
    PersistCommand::MissionIssueUpdateState {
      mission_id,
      issue_id,
      orchestration_state,
      session_id,
      workspace_id,
      attempt,
      last_error,
      retry_due_at,
      started_at,
      completed_at,
    } => mission_writes::persist_mission_issue_update_state(
      conn,
      mission_writes::MissionIssueStateUpdate {
        mission_id,
        issue_id,
        orchestration_state,
        session_id: session_id.map(Some),
        workspace_id: workspace_id.map(Some),
        attempt: attempt.map(Some),
        last_error: last_error.map(Some),
        retry_due_at: retry_due_at.map(Some),
        started_at: started_at.map(Some),
        completed_at: completed_at.map(Some),
      },
    )?,
    PersistCommand::MissionIssueSetPrUrl {
      mission_id,
      issue_id,
      pr_url,
    } => mission_writes::persist_mission_issue_set_pr_url(conn, mission_id, issue_id, pr_url)?,
    PersistCommand::RowsTurnStatusUpdate {
      session_id,
      row_ids,
      status,
    } => {
      if row_ids.is_empty() {
        return Ok(());
      }
      let placeholders = std::iter::repeat_n("?", row_ids.len())
        .collect::<Vec<_>>()
        .join(", ");
      let sql = format!(
        "UPDATE messages
             SET turn_status = ?1
           WHERE session_id = ?2
             AND id IN ({placeholders})"
      );
      let mut params_vec: Vec<Box<dyn rusqlite::ToSql>> = Vec::with_capacity(row_ids.len() + 2);
      params_vec.push(Box::new(turn_status_str(status).to_string()));
      params_vec.push(Box::new(session_id));
      for row_id in row_ids {
        params_vec.push(Box::new(row_id));
      }
      let params_refs: Vec<&dyn rusqlite::ToSql> =
        params_vec.iter().map(|value| value.as_ref()).collect();
      conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;
    }
    PersistCommand::Flush { .. } => {}
  }

  Ok(())
}

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

fn is_leap_year(year: i64) -> bool {
  (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}

#[cfg(test)]
mod tests;
