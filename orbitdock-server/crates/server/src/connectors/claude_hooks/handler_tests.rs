use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState,
  SessionStatus, SessionSummary, SubagentInfo, SubagentStatus, TokenUsage, TokenUsageSnapshotKind,
  WorkStatus,
};
use serde_json::json;

use super::approval::{
  classify_permission_request, extract_plan_from_tool_input, extract_question_from_tool_input,
};
use super::session_materialization::is_codex_rollout_payload;
use super::subagent_updates::{apply_claude_subagent_update, ClaudeSubagentUpdate};
use crate::connectors::claude_hooks::session_materialization::most_recent_claude_session_id;
use crate::support::session_time::chrono_now;

fn session_summary(
  id: &str,
  provider: Provider,
  project_path: &str,
  last_activity_at: Option<&str>,
) -> SessionSummary {
  let display_title =
    SessionSummary::display_title_from_parts(None, None, None, Some("Project"), project_path);
  SessionSummary {
    id: id.to_string(),
    provider,
    project_path: project_path.to_string(),
    transcript_path: None,
    project_name: Some("Project".to_string()),
    model: None,
    custom_name: None,
    summary: None,
    first_prompt: None,
    last_message: None,
    status: SessionStatus::Active,
    work_status: WorkStatus::Waiting,
    control_mode: SessionControlMode::Passive,
    lifecycle_state: SessionLifecycleState::Open,
    accepts_user_input: false,
    steerable: false,
    token_usage: TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::default(),
    has_pending_approval: false,
    codex_integration_mode: Some(CodexIntegrationMode::Passive),
    claude_integration_mode: Some(ClaudeIntegrationMode::Passive),
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    permission_mode: None,
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
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    pending_approval_id: None,
    started_at: Some(chrono_now()),
    last_activity_at: last_activity_at.map(str::to_string),
    last_progress_at: last_activity_at.map(str::to_string),
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    effort: None,
    approval_version: Some(0),
    summary_revision: 0,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    unread_count: 0,
    has_turn_diff: false,
    display_title,
    context_line: None,
    list_status: orbitdock_protocol::SessionListStatus::Reply,
    active_worker_count: 0,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  }
}

#[test]
fn permission_requests_map_to_expected_approval_and_attention_state() {
  let question = classify_permission_request("AskUserQuestion");
  let patch = classify_permission_request("Edit");
  let exec = classify_permission_request("Bash");

  assert_eq!(question.0, orbitdock_protocol::ApprovalType::Question);
  assert_eq!(question.1, WorkStatus::Question);

  assert_eq!(patch.0, orbitdock_protocol::ApprovalType::Patch);
  assert_eq!(patch.1, WorkStatus::Permission);

  assert_eq!(exec.0, orbitdock_protocol::ApprovalType::Exec);
  assert_eq!(exec.1, WorkStatus::Permission);
}

#[test]
fn question_extraction_prefers_direct_question_then_nested_questions() {
  let direct = json!({ "question": "Ship it?" });
  let nested = json!({ "questions": [{ "question": "Need approval?" }] });
  let empty = json!({ "questions": [{ "label": "missing" }] });

  assert_eq!(
    extract_question_from_tool_input(Some(&direct)),
    Some("Ship it?".to_string())
  );
  assert_eq!(
    extract_question_from_tool_input(Some(&nested)),
    Some("Need approval?".to_string())
  );
  assert_eq!(extract_question_from_tool_input(Some(&empty)), None);
}

#[test]
fn plan_extraction_prefers_plan_and_trims_whitespace() {
  let direct = json!({ "plan": "  First do the safe thing.  " });
  let fallback = json!({ "current_plan": "Use the fallback plan" });
  let blank = json!({ "plan": "   " });

  assert_eq!(
    extract_plan_from_tool_input(Some(&direct)),
    Some("First do the safe thing.".to_string())
  );
  assert_eq!(
    extract_plan_from_tool_input(Some(&fallback)),
    Some("Use the fallback plan".to_string())
  );
  assert_eq!(extract_plan_from_tool_input(Some(&blank)), None);
}

#[test]
fn codex_rollout_detection_uses_transcript_path_or_model_hint() {
  assert!(is_codex_rollout_payload(
    Some("/tmp/.codex/sessions/abc/rollout.jsonl"),
    None
  ));
  assert!(is_codex_rollout_payload(None, Some("codex-mini-latest")));
  assert!(is_codex_rollout_payload(None, Some("gpt-5")));
  assert!(!is_codex_rollout_payload(
    Some("/tmp/.claude/projects/demo/transcript.jsonl"),
    Some("claude-sonnet")
  ));
}

#[test]
fn most_recent_claude_session_selector_ignores_other_projects_and_current_session() {
  let summaries = [
    session_summary(
      "current",
      Provider::Claude,
      "/repo",
      Some("2026-03-09T01:00:00Z"),
    ),
    session_summary(
      "older",
      Provider::Claude,
      "/repo",
      Some("2026-03-09T02:00:00Z"),
    ),
    session_summary(
      "latest",
      Provider::Claude,
      "/repo",
      Some("2026-03-09T03:00:00Z"),
    ),
    session_summary(
      "codex",
      Provider::Codex,
      "/repo",
      Some("2026-03-09T04:00:00Z"),
    ),
    session_summary(
      "other-project",
      Provider::Claude,
      "/else",
      Some("2026-03-09T05:00:00Z"),
    ),
  ];

  assert_eq!(
    most_recent_claude_session_id("current", "/repo", summaries.iter()),
    Some("latest".to_string())
  );
}

#[test]
fn claude_subagent_start_creates_or_reactivates_running_worker() {
  let subagents = vec![SubagentInfo {
    id: "worker-1".to_string(),
    agent_type: AgentType::BackgroundTask,
    started_at: "2026-03-12T09:00:00Z".to_string(),
    ended_at: Some("2026-03-12T09:05:00Z".to_string()),
    provider: Some(Provider::Claude),
    label: Some("Existing".to_string()),
    status: SubagentStatus::Completed,
    task_summary: None,
    result_summary: Some("done".to_string()),
    error_summary: None,
    parent_subagent_id: None,
    model: None,
    last_activity_at: Some("2026-03-12T09:05:00Z".to_string()),
  }];

  let updated = apply_claude_subagent_update(
    subagents,
    ClaudeSubagentUpdate::Started {
      agent_id: "worker-1".to_string(),
      agent_type: AgentType::Explore,
    },
  );

  assert_eq!(updated.len(), 1);
  assert_eq!(updated[0].agent_type, AgentType::Explore);
  assert_eq!(updated[0].status, SubagentStatus::Running);
  assert_eq!(updated[0].provider, Some(Provider::Claude));
  assert_eq!(updated[0].ended_at, None);
  assert!(updated[0].last_activity_at.is_some());
}

#[test]
fn claude_subagent_stop_marks_worker_completed_even_if_start_was_missed() {
  let updated = apply_claude_subagent_update(
    vec![],
    ClaudeSubagentUpdate::Stopped {
      agent_id: "worker-2".to_string(),
    },
  );

  assert_eq!(updated.len(), 1);
  assert_eq!(updated[0].id, "worker-2");
  assert_eq!(updated[0].status, SubagentStatus::Completed);
  assert_eq!(updated[0].provider, Some(Provider::Claude));
  assert_eq!(updated[0].agent_type, AgentType::BackgroundTask);
  assert!(updated[0].ended_at.is_some());
}
