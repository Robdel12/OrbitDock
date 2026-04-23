use std::borrow::ToOwned;
use std::sync::Arc;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
  SessionControlMode, SessionLifecycleState, SessionStatus, TokenUsage, TokenUsageSnapshotKind,
  TurnDiff, WorkStatus,
};

#[cfg(test)]
use orbitdock_protocol::{CodexConfigMode, CodexConfigSource, Provider};

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
mod tests {
  use super::*;

  fn identity() -> SessionIdentity {
    SessionIdentity {
      id: "session-restore".to_string(),
      provider: Provider::Codex,
      project_path: "/tmp/project".to_string(),
      transcript_path: Some("/tmp/transcript.jsonl".to_string()),
      project_name: Some("Project".to_string()),
    }
  }

  fn config() -> SessionConfig {
    SessionConfig {
      model: Some("codex-model".to_string()),
      approval_policy: Some("never".to_string()),
      approval_policy_details: None,
      sandbox_mode: Some("workspace-write".to_string()),
      sandbox_policy_details: None,
      collaboration_mode: Some("collab".to_string()),
      multi_agent: Some(true),
      personality: Some("calm".to_string()),
      service_tier: Some("standard".to_string()),
      developer_instructions: Some("be clear".to_string()),
      codex_config_mode: Some(CodexConfigMode::Custom),
      codex_config_profile: Some("profile".to_string()),
      codex_model_provider: Some("openai".to_string()),
      codex_config_source: Some(CodexConfigSource::Orbitdock),
      codex_config_overrides: None,
      effort: Some("high".to_string()),
    }
  }

  fn display() -> SessionDisplay {
    SessionDisplay {
      custom_name: Some("Restored".to_string()),
      summary: Some("Summary".to_string()),
      first_prompt: Some("Prompt".to_string()),
      last_message: Some("Last".to_string()),
    }
  }

  fn environment() -> SessionEnvironment {
    SessionEnvironment {
      git_branch: Some("main".to_string()),
      git_sha: Some("abc123".to_string()),
      current_cwd: Some("/tmp/project".to_string()),
      repository_root: Some("/tmp".to_string()),
      is_worktree: true,
      worktree_id: Some("wt-1".to_string()),
    }
  }

  fn timestamps() -> SessionTimestamps {
    SessionTimestamps {
      started_at: Some("2026-04-09T00:00:00Z".to_string()),
      last_activity_at: Some("2026-04-09T00:01:00Z".to_string()),
      last_progress_at: Some("2026-04-09T00:02:00Z".to_string()),
    }
  }

  #[test]
  fn build_restored_session_snapshot_uses_restored_defaults() {
    let rows: Vec<ConversationRowEntry> = vec![];
    let turn_diffs = vec![TurnDiff {
      turn_id: "turn-1".to_string(),
      diff: "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -1,1 +1,2 @@\n-old\n+new\n+extra".to_string(),
      token_usage: None,
      snapshot_kind: None,
    }];

    let snapshot = build_restored_session_snapshot(SessionRestoreSnapshotInput {
      identity: &identity(),
      config: &config(),
      display: &display(),
      environment: &environment(),
      timestamps: &timestamps(),
      status: SessionStatus::Active,
      work_status: WorkStatus::Working,
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      permission_mode: Some("acceptEdits"),
      token_usage: &TokenUsage::default(),
      token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
      rows: &rows,
      current_diff: None,
      current_plan: Some("plan"),
      turn_diffs: &turn_diffs,
      pending_tool_name: Some("Bash"),
      pending_tool_input: Some("ls"),
      pending_question: None,
      pending_approval_id: Some("approval-1"),
      terminal_session_id: Some("terminal-1"),
      terminal_app: Some("Terminal"),
      approval_version: 12,
      unread_count: 3,
    });

    assert_eq!(snapshot.message_count, 0);
    assert!(snapshot.has_turn_diff);
    assert_eq!(
      snapshot.diff_preview.as_ref().map(|preview| (
        preview.file_count,
        preview.additions,
        preview.deletions
      )),
      Some((1, 2, 1))
    );
    assert!(snapshot.has_pending_approval);
    assert_eq!(snapshot.repository_root, None);
    assert!(!snapshot.is_worktree);
    assert_eq!(snapshot.worktree_id, None);
    assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
    assert_eq!(snapshot.current_plan.as_deref(), Some("plan"));
    assert_eq!(snapshot.current_diff.as_deref(), None);
    assert_eq!(snapshot.terminal_session_id.as_deref(), Some("terminal-1"));
    assert_eq!(snapshot.terminal_app.as_deref(), Some("Terminal"));
    assert_eq!(snapshot.approval_version, 12);
    assert_eq!(snapshot.unread_count, 3);
  }

  #[test]
  fn restored_predicates_are_simple_and_pure() {
    assert!(restored_has_pending_approval(Some("tool"), None, None));
    assert!(restored_has_pending_approval(None, Some("question"), None));
    assert!(restored_has_pending_approval(None, None, Some("approval")));
    assert!(!restored_has_pending_approval(None, None, None));

    let turn_diffs: Vec<TurnDiff> = vec![];
    assert!(has_turn_diff(Some("diff"), &turn_diffs));
    assert!(!has_turn_diff(None, &turn_diffs));
  }
}
