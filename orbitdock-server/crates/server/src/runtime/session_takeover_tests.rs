use orbitdock_protocol::{
  CodexApprovalsReviewer, CodexSessionOverrides, Provider, SessionControlMode,
  SessionLifecycleState, SessionListStatus, SessionStatus, SessionSummary, TokenUsage,
  TokenUsageSnapshotKind, WorkStatus,
};

use super::codex_runtime_overrides_from_summary;

#[test]
fn codex_takeover_preserves_approvals_reviewer_from_overrides() {
  let summary = SessionSummary {
    id: "sess-1".to_string(),
    provider: Provider::Codex,
    project_path: "/tmp/project".to_string(),
    transcript_path: None,
    project_name: None,
    model: None,
    custom_name: None,
    summary: None,
    first_prompt: None,
    last_message: None,
    status: SessionStatus::Active,
    work_status: WorkStatus::Working,
    control_mode: SessionControlMode::Passive,
    lifecycle_state: SessionLifecycleState::Open,
    accepts_user_input: true,
    steerable: true,
    token_usage: TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::default(),
    has_pending_approval: false,
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    permission_mode: None,
    allow_bypass_permissions: false,
    collaboration_mode: Some("delegate".to_string()),
    multi_agent: Some(true),
    personality: Some("balanced".to_string()),
    service_tier: Some("priority".to_string()),
    developer_instructions: Some("Keep approvals safe".to_string()),
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    codex_config_overrides: Some(CodexSessionOverrides {
      approvals_reviewer: Some(CodexApprovalsReviewer::GuardianSubagent),
      ..Default::default()
    }),
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    pending_approval_id: None,
    codex_integration_mode: None,
    claude_integration_mode: None,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    effort: None,
    approval_version: None,
    summary_revision: 0,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    unread_count: 0,
    has_turn_diff: false,
    display_title: "Session".to_string(),
    context_line: None,
    list_status: SessionListStatus::Working,
    active_worker_count: 0,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: None,
    issue_identifier: None,
  };

  let runtime_overrides = codex_runtime_overrides_from_summary(&summary);

  assert_eq!(
    runtime_overrides.approvals_reviewer.as_deref(),
    Some("guardian_subagent")
  );
  assert_eq!(
    runtime_overrides.collaboration_mode.as_deref(),
    Some("delegate")
  );
  assert_eq!(runtime_overrides.multi_agent, Some(true));
}
