//! Persistence layer - batched SQLite writes
//!
//! Uses `spawn_blocking` for async-safe SQLite access.
//! Batches writes for better performance under high event volume.

use std::collections::HashSet;
use std::path::PathBuf;

mod approvals;
mod claude_shadow;
mod commands;
mod config;
mod config_writes;
mod connector_writes;
mod messages;
pub(crate) mod mission_control;
mod mission_writes;
mod recent_projects;
mod review_comments;
mod review_writes;
mod row_turn_codecs;
mod rows_turn_status_writes;
mod session_accounting_writes;
mod session_reads;
mod session_writes;
mod startup_cleanup;
mod subagent_writes;
mod subagents;
mod sync;
mod sync_outbox;
mod sync_writer;
mod timestamps;
mod transcripts;
mod usage;
mod workspace_sync;
mod workspaces;
mod worktree_writes;
mod worktrees;
mod writer;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use orbitdock_protocol::{
  ApprovalHistoryItem, ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, TokenUsage,
  TokenUsageSnapshotKind,
};

pub(crate) use approvals::{delete_approval, list_approvals};
pub(crate) use claude_shadow::preserve_direct_owned_claude_shadow;
pub(crate) use commands::{ApprovalRequestedParams, PersistCommand, SessionCreateParams};
pub(crate) use config::load_config_value;
pub(crate) use messages::{
  load_message_page_for_session, load_messages_for_session, load_row_by_id_async,
};
pub(crate) use mission_control::{
  load_mission_by_id, load_mission_cleanup_candidates, load_mission_issues,
  load_mission_tracker_key, load_missions_with_counts, MissionIssueRow, MissionRow,
};
pub(crate) use recent_projects::load_recent_projects_from_sessions;
pub(crate) use review_comments::{list_review_comments, load_review_comment_by_id};
pub(crate) use row_turn_codecs::{extract_row_content, row_type_str, turn_status_str};
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
pub(crate) use timestamps::chrono_now;
pub(crate) use transcripts::{
  extract_summary_from_transcript_path, load_capabilities_from_transcript_path,
  load_latest_codex_turn_context_settings_from_transcript_path, load_messages_from_transcript_path,
  load_token_usage_from_transcript_path,
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
pub(crate) use worktrees::{
  load_all_worktrees, load_removed_worktree_paths, load_worktree_by_id,
  load_worktree_session_stats, load_worktrees_by_repo, WorktreeRow,
};
#[cfg(test)]
pub(crate) use writer::flush_batch_for_test;
pub(crate) use writer::{create_persistence_channel, PersistenceWriter};

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
    } => session_accounting_writes::persist_row_append(
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
    } => session_accounting_writes::persist_row_upsert(
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
    } => session_accounting_writes::persist_tokens_update(conn, session_id, usage, snapshot_kind)?,
    PersistCommand::TurnStateUpdate {
      session_id,
      diff,
      plan,
    } => session_accounting_writes::persist_turn_state_update(conn, session_id, diff, plan)?,
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
    } => session_accounting_writes::persist_turn_diff_insert(
      conn,
      session_accounting_writes::TurnDiffInsertRecord {
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
    } => session_accounting_writes::persist_mark_session_read(conn, session_id, up_to_sequence)?,
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
    PersistCommand::DeleteConfig { key } => config_writes::persist_delete_config(conn, key)?,
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
      rows_turn_status_writes::persist_rows_turn_status_update(conn, session_id, row_ids, status)?
    }
    PersistCommand::Flush { .. } => {}
  }

  Ok(())
}

#[cfg(test)]
mod tests;
