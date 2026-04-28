use super::*;
use orbitdock_protocol::{SessionControlMode, SessionLifecycleState, TokenUsageSnapshotKind};

#[test]
fn parse_provider_accepts_known_values_and_falls_back_for_unknowns() {
  let cases = [
    ("claude", Provider::Claude),
    ("Claude", Provider::Claude),
    ("CLAUDE", Provider::Claude),
    ("codex", Provider::Codex),
    ("Codex", Provider::Codex),
    ("CODEX", Provider::Codex),
    ("", Provider::Claude),
    ("gpt4", Provider::Claude),
    ("unknown", Provider::Claude),
    ("  codex  ", Provider::Claude),
  ];
  for (raw, expected) in cases {
    assert_eq!(parse_provider(raw), expected, "raw input: {raw:?}");
  }
}

#[test]
fn restored_state_sets_turn_count_from_persisted_turn_diffs() {
  let mut restored = fixture_restored_session();
  restored.turn_diffs = vec![
    (
      "turn-1".to_string(),
      "diff 1".to_string(),
      1,
      2,
      3,
      4,
      TokenUsageSnapshotKind::ContextTurn,
    ),
    (
      "turn-2".to_string(),
      "diff 2".to_string(),
      5,
      6,
      7,
      8,
      TokenUsageSnapshotKind::LifetimeTotals,
    ),
  ];

  let state = restored_session_to_state(restored);
  assert_eq!(state.turn_count, 2);
  assert_eq!(state.turn_diffs.len(), 2);
}

#[test]
fn restored_state_preserves_usage_only_turn_count() {
  let mut restored = fixture_restored_session();
  restored.turn_count = 7;
  restored.turn_diffs = vec![(
    "turn-1".to_string(),
    "diff 1".to_string(),
    1,
    2,
    3,
    4,
    TokenUsageSnapshotKind::LifetimeTotals,
  )];

  let state = restored_session_to_state(restored);

  assert_eq!(state.turn_count, 7);
  assert_eq!(state.turn_diffs.len(), 1);
}

#[test]
fn restored_state_marks_ended_sessions_ended() {
  let mut restored = fixture_restored_session();
  restored.status = "active".to_string();
  restored.work_status = "working".to_string();
  restored.end_reason = Some("completed".to_string());

  let state = restored_session_to_state(restored);

  assert_eq!(state.status, orbitdock_protocol::SessionStatus::Ended);
  assert_eq!(state.work_status, orbitdock_protocol::WorkStatus::Ended);
}

fn fixture_restored_session() -> RestoredSession {
  RestoredSession {
    id: "session-1".to_string(),
    provider: "codex".to_string(),
    status: "active".to_string(),
    work_status: "waiting".to_string(),
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    project_path: "/tmp/project".to_string(),
    transcript_path: None,
    project_name: None,
    model: None,
    custom_name: None,
    summary: None,
    codex_thread_id: None,
    claude_sdk_session_id: None,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    approval_policy: None,
    sandbox_mode: None,
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
    input_tokens: 0,
    output_tokens: 0,
    cached_tokens: 0,
    context_window: 0,
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    pending_approval_id: None,
    rows: Vec::new(),
    forked_from_session_id: None,
    current_diff: None,
    current_plan: None,
    turn_count: 0,
    turn_diffs: Vec::new(),
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    first_prompt: None,
    last_message: None,
    end_reason: None,
    effort: None,
    terminal_session_id: None,
    terminal_app: None,
    approval_version: 0,
    unread_count: 0,
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  }
}
