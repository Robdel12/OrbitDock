use super::*;
use orbitdock_protocol::{CodexConfigMode, CodexConfigSource, Provider};

fn identity() -> SessionIdentity {
  SessionIdentity {
    id: "session-1".to_string(),
    provider: Provider::Claude,
    project_path: "/tmp/project".to_string(),
    transcript_path: Some("/tmp/transcript.jsonl".to_string()),
    project_name: Some("Project".to_string()),
  }
}

fn config() -> SessionConfig {
  SessionConfig {
    model: Some("claude-sonnet".to_string()),
    approval_policy: Some("on-request".to_string()),
    approval_policy_details: None,
    sandbox_mode: Some("workspace-write".to_string()),
    sandbox_policy_details: None,
    collaboration_mode: Some("plan".to_string()),
    multi_agent: Some(true),
    personality: Some("direct".to_string()),
    service_tier: Some("standard".to_string()),
    developer_instructions: Some("be careful".to_string()),
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
    custom_name: Some("Alpha".to_string()),
    summary: Some("Summary".to_string()),
    first_prompt: Some("Prompt".to_string()),
    last_message: Some("Last message".to_string()),
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
fn build_session_snapshot_projects_live_state() {
  let pending_tool_name = "Bash";
  let pending_tool_input = "ls";
  let pending_approval_id = "approval-1";
  let mission_id = "mission-1";
  let issue_identifier = "ISSUE-1";
  let newest_synced_row_id = "row-1";
  let repository_root = "/tmp";
  let worktree_id = "wt-1";
  let turn_diffs: Vec<TurnDiff> = vec![];

  let snapshot = build_session_snapshot(SessionSnapshotInput {
    identity: &identity(),
    config: &config(),
    display: &display(),
    environment: &environment(),
    timestamps: &timestamps(),
    status: SessionStatus::Active,
    work_status: WorkStatus::Working,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    steerable: true,
    codex_integration_mode: None,
    claude_integration_mode: None,
    pending_approval: None,
    pending_tool_name: Some(pending_tool_name),
    pending_tool_input: Some(pending_tool_input),
    pending_question: None,
    pending_approval_id: Some(pending_approval_id),
    permission_mode: Some("acceptEdits"),
    active_worker_count: 2,
    tool_count: 11,
    token_usage: &TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
    revision: 42,
    current_plan: Some("plan"),
    current_diff: Some("diff"),
    approval_version: 3,
    repository_root: Some(repository_root),
    is_worktree: true,
    worktree_id: Some(worktree_id),
    turn_diffs: &turn_diffs,
    subscriber_count: 5,
    unread_count: 9,
    mission_id: Some(mission_id),
    issue_identifier: Some(issue_identifier),
    allow_bypass_permissions: true,
    newest_synced_row_id: Some(newest_synced_row_id),
  });

  assert_eq!(snapshot.id, "session-1");
  assert_eq!(snapshot.active_worker_count, 2);
  assert_eq!(snapshot.tool_count, 11);
  assert_eq!(snapshot.current_plan.as_deref(), Some("plan"));
  assert_eq!(snapshot.pending_approval_id.as_deref(), Some("approval-1"));
  assert_eq!(snapshot.permission_mode.as_deref(), Some("acceptEdits"));
  assert_eq!(snapshot.repository_root.as_deref(), Some("/tmp"));
  assert!(snapshot.is_worktree);
  assert_eq!(snapshot.worktree_id.as_deref(), Some("wt-1"));
  assert!(snapshot.has_turn_diff);
  assert_eq!(snapshot.subscriber_count, 5);
  assert_eq!(snapshot.mission_id.as_deref(), Some("mission-1"));
  assert_eq!(snapshot.issue_identifier.as_deref(), Some("ISSUE-1"));
  assert!(snapshot.allow_bypass_permissions);
  assert_eq!(snapshot.newest_synced_row_id.as_deref(), Some("row-1"));
}

#[test]
fn pending_approval_detection_is_field_based() {
  assert!(has_pending_approval(None, Some("tool"), None, None));
  assert!(has_pending_approval(None, None, Some("question"), None));
  assert!(has_pending_approval(None, None, None, Some("approval-1")));
  assert!(!has_pending_approval(None, None, None, None));
}

#[test]
fn pending_approval_id_prefers_explicit_value() {
  let approval = ApprovalRequest {
    id: "approval-request-id".to_string(),
    session_id: "session-1".to_string(),
    approval_type: orbitdock_protocol::ApprovalType::Exec,
    tool_name: None,
    tool_input: None,
    command: None,
    file_path: None,
    diff: None,
    question: None,
    question_prompts: vec![],
    preview: None,
    permission_reason: None,
    requested_permissions: None,
    granted_permissions: None,
    proposed_amendment: None,
    permission_suggestions: None,
    elicitation_mode: None,
    elicitation_schema: None,
    elicitation_url: None,
    elicitation_message: None,
    mcp_server_name: None,
    network_host: None,
    network_protocol: None,
  };

  assert_eq!(
    resolve_pending_approval_id(Some("explicit-id"), Some(&approval)).as_deref(),
    Some("explicit-id")
  );
  assert_eq!(
    resolve_pending_approval_id(None, Some(&approval)).as_deref(),
    Some("approval-request-id")
  );
}
