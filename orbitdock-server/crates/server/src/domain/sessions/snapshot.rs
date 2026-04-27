use std::borrow::ToOwned;
use std::sync::Arc;

use orbitdock_protocol::{
  ApprovalRequest, ClaudeIntegrationMode, CodexIntegrationMode, SessionControlMode,
  SessionLifecycleState, SessionStatus, TokenUsage, TokenUsageSnapshotKind, TurnDiff, WorkStatus,
};

use super::diff_preview::{build_dashboard_diff_preview, has_turn_diff};
use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use super::session::SessionSnapshot;

/// Inputs needed to project a live session into a transport snapshot.
///
/// Keep this type pure and boring: it should only carry the data needed to
/// build a `SessionSnapshot`, with no runtime or actor concerns.
#[derive(Debug, Clone, Copy)]
pub struct SessionSnapshotInput<'a> {
  pub identity: &'a SessionIdentity,
  pub config: &'a SessionConfig,
  pub display: &'a SessionDisplay,
  pub environment: &'a SessionEnvironment,
  pub timestamps: &'a SessionTimestamps,
  pub status: SessionStatus,
  pub work_status: WorkStatus,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub steerable: bool,
  pub codex_integration_mode: Option<CodexIntegrationMode>,
  pub claude_integration_mode: Option<ClaudeIntegrationMode>,
  pub pending_approval: Option<&'a ApprovalRequest>,
  pub pending_tool_name: Option<&'a str>,
  pub pending_tool_input: Option<&'a str>,
  pub pending_question: Option<&'a str>,
  pub pending_approval_id: Option<&'a str>,
  pub permission_mode: Option<&'a str>,
  pub message_count: usize,
  pub active_worker_count: u32,
  pub tool_count: u64,
  pub token_usage: &'a TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub revision: u64,
  pub current_plan: Option<&'a str>,
  pub current_diff: Option<&'a str>,
  pub approval_version: u64,
  pub terminal_session_id: Option<&'a str>,
  pub terminal_app: Option<&'a str>,
  pub repository_root: Option<&'a str>,
  pub is_worktree: bool,
  pub worktree_id: Option<&'a str>,
  pub turn_diffs: &'a [TurnDiff],
  pub subscriber_count: usize,
  pub unread_count: u64,
  pub mission_id: Option<&'a str>,
  pub issue_identifier: Option<&'a str>,
  pub allow_bypass_permissions: bool,
  pub newest_synced_row_id: Option<&'a str>,
}

/// Returns `true` when any pending-approval field is present.
pub fn has_pending_approval(
  pending_approval: Option<&ApprovalRequest>,
  pending_tool_name: Option<&str>,
  pending_question: Option<&str>,
  pending_approval_id: Option<&str>,
) -> bool {
  pending_approval.is_some()
    || pending_tool_name.is_some()
    || pending_question.is_some()
    || pending_approval_id.is_some()
}

/// Resolve the pending approval identifier, preferring the persisted ID and
/// falling back to the in-memory approval request when needed.
pub fn resolve_pending_approval_id(
  pending_approval_id: Option<&str>,
  pending_approval: Option<&ApprovalRequest>,
) -> Option<String> {
  pending_approval_id
    .map(ToOwned::to_owned)
    .or_else(|| pending_approval.map(|approval| approval.id.clone()))
}

/// Build a `SessionSnapshot` from already-shaped live session inputs.
pub fn build_session_snapshot(input: SessionSnapshotInput<'_>) -> SessionSnapshot {
  SessionSnapshot {
    id: input.identity.id.clone(),
    provider: input.identity.provider,
    status: input.status,
    work_status: input.work_status,
    control_mode: input.control_mode,
    lifecycle_state: input.lifecycle_state,
    steerable: input.steerable,
    project_path: input.identity.project_path.clone(),
    project_name: input.identity.project_name.clone(),
    transcript_path: input.identity.transcript_path.clone(),
    custom_name: input.display.custom_name.clone(),
    summary: input.display.summary.clone(),
    first_prompt: input.display.first_prompt.clone(),
    last_message: input.display.last_message.clone(),
    model: input.config.model.clone(),
    codex_integration_mode: input.codex_integration_mode,
    claude_integration_mode: input.claude_integration_mode,
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
    has_pending_approval: has_pending_approval(
      input.pending_approval,
      input.pending_tool_name,
      input.pending_question,
      input.pending_approval_id,
    ),
    pending_tool_name: input.pending_tool_name.map(ToOwned::to_owned),
    pending_tool_input: input.pending_tool_input.map(ToOwned::to_owned),
    pending_question: input.pending_question.map(ToOwned::to_owned),
    pending_approval_id: resolve_pending_approval_id(
      input.pending_approval_id,
      input.pending_approval,
    ),
    message_count: input.message_count,
    active_worker_count: input.active_worker_count,
    tool_count: input.tool_count,
    token_usage: input.token_usage.clone(),
    token_usage_snapshot_kind: input.token_usage_snapshot_kind,
    started_at: input.timestamps.started_at.clone(),
    last_activity_at: input.timestamps.last_activity_at.clone(),
    last_progress_at: input.timestamps.last_progress_at.clone(),
    revision: input.revision,
    current_plan: input.current_plan.map(Arc::from),
    current_diff: input.current_diff.map(Arc::from),
    git_branch: input.environment.git_branch.clone(),
    git_sha: input.environment.git_sha.clone(),
    current_cwd: input.environment.current_cwd.clone(),
    effort: input.config.effort.clone(),
    terminal_session_id: input.terminal_session_id.map(ToOwned::to_owned),
    terminal_app: input.terminal_app.map(ToOwned::to_owned),
    approval_version: input.approval_version,
    repository_root: input.repository_root.map(ToOwned::to_owned),
    is_worktree: input.is_worktree,
    worktree_id: input.worktree_id.map(ToOwned::to_owned),
    has_turn_diff: has_turn_diff(input.current_diff, input.turn_diffs),
    diff_preview: build_dashboard_diff_preview(input.current_diff, input.turn_diffs),
    subscriber_count: input.subscriber_count,
    unread_count: input.unread_count,
    mission_id: input.mission_id.map(ToOwned::to_owned),
    issue_identifier: input.issue_identifier.map(ToOwned::to_owned),
    allow_bypass_permissions: input.allow_bypass_permissions,
    newest_synced_row_id: input.newest_synced_row_id.map(ToOwned::to_owned),
  }
}

#[cfg(test)]
#[path = "snapshot_tests.rs"]
mod snapshot_tests;
