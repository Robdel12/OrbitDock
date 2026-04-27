use serde_json::Value;

use super::{
  build_session_list_json_response, session_json_overview_from_state, stream_turn_should_exit,
};
use orbitdock_protocol::{
  Provider, SessionControlMode, SessionLifecycleState, SessionListItem, SessionListStatus,
  SessionState, SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

fn sample_state() -> SessionState {
  SessionState {
    id: "od-session-123".to_string(),
    provider: Provider::Claude,
    project_path: "/tmp/orbitdock".to_string(),
    transcript_path: None,
    project_name: Some("OrbitDock".to_string()),
    model: Some("claude-opus-4-6".to_string()),
    custom_name: None,
    summary: Some("CLI output formatter".to_string()),
    first_prompt: Some("Make the CLI easier to read for people and LLMs".to_string()),
    last_message: Some("Session output is looking much better now.".to_string()),
    status: SessionStatus::Active,
    work_status: WorkStatus::Waiting,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    accepts_user_input: true,
    steerable: true,
    connector_attached: true,
    can_interrupt: false,
    pending_approval: None,
    permission_mode: Some("acceptEdits".to_string()),
    allow_bypass_permissions: false,
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
    pending_tool_name: Some("apply_patch".to_string()),
    pending_tool_input: None,
    pending_question: Some("Should the IDs stay fully visible?".to_string()),
    pending_approval_id: None,
    token_usage: TokenUsage {
      input_tokens: 1200,
      output_tokens: 300,
      cached_tokens: 600,
      context_window: 10_000,
    },
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Mixed,
    current_diff: None,
    cumulative_diff: None,
    current_plan: None,
    codex_integration_mode: None,
    claude_integration_mode: None,
    approval_policy: Some("on-request".to_string()),
    approval_policy_details: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    started_at: Some("2026-03-26T14:51:01Z".to_string()),
    last_activity_at: Some("2026-03-26T15:08:29Z".to_string()),
    last_progress_at: Some("2026-03-26T15:08:29Z".to_string()),
    forked_from_session_id: None,
    revision: Some(383),
    current_turn_id: None,
    turn_count: 2,
    turn_diffs: vec![],
    git_branch: Some("main".to_string()),
    git_sha: Some("e6b1b46a79b2".to_string()),
    current_cwd: None,
    subagents: vec![],
    effort: Some("medium".to_string()),
    terminal_session_id: None,
    terminal_app: None,
    approval_version: Some(0),
    repository_root: Some("/tmp/orbitdock".to_string()),
    is_worktree: false,
    worktree_id: None,
    unread_count: 0,
    mission_id: None,
    issue_identifier: None,
    rows: vec![],
    total_row_count: 0,
    has_more_before: false,
    oldest_sequence: None,
    newest_sequence: None,
  }
}

#[test]
fn stream_turn_waiting_requires_real_turn_activity() {
  assert!(!stream_turn_should_exit(&WorkStatus::Waiting, false));
  assert!(stream_turn_should_exit(&WorkStatus::Waiting, true));
}

#[test]
fn stream_turn_exit_rules_match_user_visible_completion() {
  assert!(!stream_turn_should_exit(&WorkStatus::Working, true));
  assert!(stream_turn_should_exit(&WorkStatus::Permission, true));
  assert!(stream_turn_should_exit(&WorkStatus::Reply, true));
  assert!(stream_turn_should_exit(&WorkStatus::Ended, true));
}

#[test]
fn session_json_overview_from_state_derives_compact_high_signal_fields() {
  let overview = session_json_overview_from_state(&sample_state());
  let value = serde_json::to_value(&overview).expect("serialize overview");

  assert_eq!(
    value["project_label"],
    Value::String("OrbitDock".to_string())
  );
  assert_eq!(
    value["title"],
    Value::String("CLI output formatter".to_string())
  );
  assert_eq!(
    value["context_line"],
    Value::String("Session output is looking much better now.".to_string())
  );
  assert_eq!(value["context_fill_percent"], Value::from(12.0));
  assert_eq!(
    value["token_usage_snapshot_kind"],
    Value::String("mixed".to_string())
  );
  assert_eq!(value["cache_hit_percent"], Value::from(50.0));
}

#[test]
fn session_list_json_response_includes_count_and_summaries() {
  let response = build_session_list_json_response(vec![SessionListItem {
    id: "od-session-123".to_string(),
    provider: Provider::Claude,
    project_path: "/tmp/orbitdock".to_string(),
    project_name: Some("OrbitDock".to_string()),
    git_branch: Some("main".to_string()),
    model: Some("claude-opus-4-6".to_string()),
    status: SessionStatus::Active,
    work_status: WorkStatus::Waiting,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    steerable: true,
    codex_integration_mode: None,
    claude_integration_mode: None,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    unread_count: 0,
    has_turn_diff: false,
    pending_tool_name: None,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    total_tokens: 1500,
    total_cost_usd: 0.0,
    input_tokens: 1200,
    output_tokens: 300,
    cached_tokens: 600,
    display_title: "CLI output formatter".to_string(),
    context_line: Some("Session output is looking much better now.".to_string()),
    list_status: SessionListStatus::Working,
    effort: Some("medium".to_string()),
    summary_revision: 0,
    active_worker_count: 0,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: None,
    issue_identifier: None,
  }]);
  let value = serde_json::to_value(&response).expect("serialize response");

  assert_eq!(value["kind"], Value::String("session_list".to_string()));
  assert_eq!(value["count"], Value::from(1));
  assert_eq!(
    value["summaries"][0]["title"],
    Value::String("CLI output formatter".to_string())
  );
  assert_eq!(
    value["summaries"][0]["context_line"],
    Value::String("Session output is looking much better now.".to_string())
  );
  assert!(value["summaries"][0].get("cache_hit_percent").is_none());
}

#[test]
fn session_summary_context_line_is_compacted_for_json_overview() {
  let response = build_session_list_json_response(vec![SessionListItem {
    id: "od-session-456".to_string(),
    provider: Provider::Claude,
    project_path: "/tmp/orbitdock".to_string(),
    project_name: Some("OrbitDock".to_string()),
    git_branch: Some("main".to_string()),
    model: Some("claude-opus-4-6".to_string()),
    status: SessionStatus::Active,
    work_status: WorkStatus::Waiting,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    steerable: true,
    codex_integration_mode: None,
    claude_integration_mode: None,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    unread_count: 0,
    has_turn_diff: false,
    pending_tool_name: None,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    total_tokens: 10,
    total_cost_usd: 0.0,
    input_tokens: 5,
    output_tokens: 5,
    cached_tokens: 0,
    display_title: "CLI output formatter".to_string(),
    context_line: Some("First line\n\nSecond line with extra spacing".to_string()),
    list_status: SessionListStatus::Working,
    effort: Some("medium".to_string()),
    summary_revision: 0,
    active_worker_count: 0,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: None,
    issue_identifier: None,
  }]);
  let value = serde_json::to_value(&response).expect("serialize response");

  assert_eq!(
    value["summaries"][0]["context_line"],
    Value::String("First line Second line with extra spacing".to_string())
  );
}
