use std::sync::Arc;

use orbitdock_protocol::{
  Provider, SessionLifecycleState, SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

use super::{permission_request_matches_snapshot, PermissionRequestSnapshotMatch};
use crate::domain::sessions::session::SessionSnapshot;

fn snapshot() -> SessionSnapshot {
  SessionSnapshot {
    id: "session-1".to_string(),
    provider: Provider::Claude,
    status: SessionStatus::Active,
    work_status: WorkStatus::Permission,
    control_mode: orbitdock_protocol::SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    steerable: false,
    project_path: "/repo".to_string(),
    project_name: None,
    transcript_path: None,
    custom_name: None,
    summary: None,
    first_prompt: None,
    last_message: None,
    model: None,
    codex_integration_mode: None,
    claude_integration_mode: None,
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    permission_mode: Some("default".to_string()),
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    codex_config_overrides: None,
    has_pending_approval: true,
    pending_tool_name: Some("Bash".to_string()),
    pending_tool_input: Some("{\"command\":\"ls\"}".to_string()),
    pending_question: None,
    pending_approval_id: Some("claude-perm-tooluse-1".to_string()),
    message_count: 0,
    active_worker_count: 0,
    tool_count: 0,
    token_usage: TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    revision: 0,
    current_plan: Some(Arc::from("Inspect files")),
    current_diff: None,
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    effort: None,
    terminal_session_id: None,
    terminal_app: None,
    approval_version: 1,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    has_turn_diff: false,
    diff_preview: None,
    subscriber_count: 0,
    unread_count: 0,
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
    newest_synced_row_id: None,
  }
}

#[test]
fn duplicate_permission_request_matches_snapshot_state() {
  let snapshot = snapshot();

  assert!(permission_request_matches_snapshot(
    &snapshot,
    &PermissionRequestSnapshotMatch {
      request_id: "claude-perm-tooluse-1",
      tool_name: "Bash",
      tool_input: Some("{\"command\":\"ls\"}"),
      question: None,
      work_status: WorkStatus::Permission,
      permission_mode: Some("default"),
      plan_text: Some("Inspect files"),
    }
  ));
}

#[test]
fn changed_plan_or_permission_mode_breaks_duplicate_match() {
  let snapshot = snapshot();

  assert!(!permission_request_matches_snapshot(
    &snapshot,
    &PermissionRequestSnapshotMatch {
      request_id: "claude-perm-tooluse-1",
      tool_name: "Bash",
      tool_input: Some("{\"command\":\"ls\"}"),
      question: None,
      work_status: WorkStatus::Permission,
      permission_mode: Some("workspace-write"),
      plan_text: Some("Inspect files"),
    }
  ));
  assert!(!permission_request_matches_snapshot(
    &snapshot,
    &PermissionRequestSnapshotMatch {
      request_id: "claude-perm-tooluse-1",
      tool_name: "Bash",
      tool_input: Some("{\"command\":\"ls\"}"),
      question: None,
      work_status: WorkStatus::Permission,
      permission_mode: Some("default"),
      plan_text: Some("Run tests"),
    }
  ));
}
