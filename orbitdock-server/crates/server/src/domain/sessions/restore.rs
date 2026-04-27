use std::borrow::ToOwned;
use std::sync::Arc;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
  SessionControlMode, SessionLifecycleState, SessionStatus, TokenUsage, TokenUsageSnapshotKind,
  TurnDiff, WorkStatus,
};

use super::diff_preview::{build_dashboard_diff_preview, has_turn_diff};
use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use super::session::{steerable_from_parts, SessionSnapshot};

/// Inputs needed to rebuild a restored session snapshot from persisted state.
#[derive(Debug, Clone, Copy)]
pub struct SessionRestoreSnapshotInput<'a> {
  pub identity: &'a SessionIdentity,
  pub config: &'a SessionConfig,
  pub display: &'a SessionDisplay,
  pub environment: &'a SessionEnvironment,
  pub timestamps: &'a SessionTimestamps,
  pub status: SessionStatus,
  pub work_status: WorkStatus,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub permission_mode: Option<&'a str>,
  pub token_usage: &'a TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub rows: &'a [ConversationRowEntry],
  pub current_diff: Option<&'a str>,
  pub current_plan: Option<&'a str>,
  pub turn_diffs: &'a [TurnDiff],
  pub pending_tool_name: Option<&'a str>,
  pub pending_tool_input: Option<&'a str>,
  pub pending_question: Option<&'a str>,
  pub pending_approval_id: Option<&'a str>,
  pub terminal_session_id: Option<&'a str>,
  pub terminal_app: Option<&'a str>,
  pub approval_version: u64,
  pub unread_count: u64,
}

/// Returns `true` when a restored session still has any pending approval
/// markers that should be reflected in the snapshot.
pub fn restored_has_pending_approval(
  pending_tool_name: Option<&str>,
  pending_question: Option<&str>,
  pending_approval_id: Option<&str>,
) -> bool {
  pending_tool_name.is_some() || pending_question.is_some() || pending_approval_id.is_some()
}

/// Returns the row count represented by persisted conversation rows.
pub fn restored_message_count(rows: &[ConversationRowEntry]) -> usize {
  rows.len()
}

/// Build the restored transport snapshot that seeds a rehydrated session.
pub fn build_restored_session_snapshot(input: SessionRestoreSnapshotInput<'_>) -> SessionSnapshot {
  SessionSnapshot {
    id: input.identity.id.clone(),
    provider: input.identity.provider,
    status: input.status,
    work_status: input.work_status,
    control_mode: input.control_mode,
    lifecycle_state: input.lifecycle_state,
    steerable: steerable_from_parts(
      input.status,
      input.work_status,
      input.control_mode,
      input.lifecycle_state,
    ),
    project_path: input.identity.project_path.clone(),
    project_name: input.identity.project_name.clone(),
    transcript_path: input.identity.transcript_path.clone(),
    custom_name: input.display.custom_name.clone(),
    summary: input.display.summary.clone(),
    first_prompt: input.display.first_prompt.clone(),
    last_message: input.display.last_message.clone(),
    model: input.config.model.clone(),
    codex_integration_mode: None,
    claude_integration_mode: None,
    approval_policy: input.config.approval_policy.clone(),
    approval_policy_details: input.config.approval_policy_details.clone(),
    sandbox_mode: input.config.sandbox_mode.clone(),
    sandbox_policy_details: input.config.sandbox_policy_details.clone(),
    permission_mode: input.permission_mode.map(ToOwned::to_owned),
    collaboration_mode: input.config.collaboration_mode.clone(),
    multi_agent: input.config.multi_agent,
    personality: input.config.personality.clone(),
    service_tier: input.config.service_tier.clone(),
    developer_instructions: input.config.developer_instructions.clone(),
    codex_config_mode: input.config.codex_config_mode,
    codex_config_profile: input.config.codex_config_profile.clone(),
    codex_model_provider: input.config.codex_model_provider.clone(),
    codex_config_source: input.config.codex_config_source,
    codex_config_overrides: input.config.codex_config_overrides.clone(),
    has_pending_approval: restored_has_pending_approval(
      input.pending_tool_name,
      input.pending_question,
      input.pending_approval_id,
    ),
    pending_tool_name: input.pending_tool_name.map(ToOwned::to_owned),
    pending_tool_input: input.pending_tool_input.map(ToOwned::to_owned),
    pending_question: input.pending_question.map(ToOwned::to_owned),
    pending_approval_id: input.pending_approval_id.map(ToOwned::to_owned),
    message_count: restored_message_count(input.rows),
    active_worker_count: 0,
    tool_count: 0,
    token_usage: input.token_usage.clone(),
    token_usage_snapshot_kind: input.token_usage_snapshot_kind,
    started_at: input.timestamps.started_at.clone(),
    last_activity_at: input.timestamps.last_activity_at.clone(),
    last_progress_at: input.timestamps.last_progress_at.clone(),
    revision: 0,
    current_plan: input.current_plan.map(Arc::from),
    current_diff: input.current_diff.map(Arc::from),
    git_branch: input.environment.git_branch.clone(),
    git_sha: input.environment.git_sha.clone(),
    current_cwd: input.environment.current_cwd.clone(),
    effort: input.config.effort.clone(),
    terminal_session_id: input.terminal_session_id.map(ToOwned::to_owned),
    terminal_app: input.terminal_app.map(ToOwned::to_owned),
    approval_version: input.approval_version,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    has_turn_diff: has_turn_diff(input.current_diff, input.turn_diffs),
    diff_preview: build_dashboard_diff_preview(input.current_diff, input.turn_diffs),
    subscriber_count: 0,
    unread_count: input.unread_count,
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
    newest_synced_row_id: None,
  }
}

#[cfg(test)]
#[path = "restore_tests.rs"]
mod restore_tests;
