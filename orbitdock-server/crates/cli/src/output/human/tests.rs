use orbitdock_protocol::{
  Provider, SessionControlMode, SessionLifecycleState, SessionListItem, SessionListStatus,
  SessionStatus, WorkStatus,
};

use super::render_sessions_table;

#[test]
fn session_table_preserves_full_session_ids() {
  let session_id = "od-f90e8471-777c-4db5-9de5-9dd90ca0c55c";
  let table = render_sessions_table(&[SessionListItem {
    id: session_id.to_string(),
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
    total_tokens: 0,
    total_cost_usd: 0.0,
    input_tokens: 0,
    output_tokens: 0,
    cached_tokens: 0,
    display_title: "CLI Session Output Formatter".to_string(),
    context_line: None,
    list_status: SessionListStatus::Working,
    effort: None,
    summary_revision: 0,
    active_worker_count: 0,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: None,
    issue_identifier: None,
  }]);

  assert!(table.contains(session_id));
  assert!(!table.contains("od-f90e8471-777..."));
  assert!(table.contains("Updated"));
  assert!(table.contains("Unread"));
}
