use orbitdock_protocol::{
  DashboardConversationItem, Provider, SessionControlMode, SessionLifecycleState,
  SessionListStatus, SessionStatus, WorkStatus,
};

use super::dedupe_conversations_by_session_id;

#[test]
fn dedupe_conversations_keeps_first_item_for_duplicate_session_id() {
  let first = dashboard_item("dup", "Most Recent", Some("2026-04-08T12:00:00Z"));
  let duplicate = dashboard_item("dup", "Older Duplicate", Some("2026-04-08T11:00:00Z"));
  let distinct = dashboard_item("other", "Other Session", Some("2026-04-08T10:00:00Z"));

  let deduped =
    dedupe_conversations_by_session_id(vec![first.clone(), duplicate, distinct.clone()]);

  assert_eq!(deduped.len(), 2);
  assert_eq!(deduped[0].session_id, "dup");
  assert_eq!(deduped[0].display_title, first.display_title);
  assert_eq!(deduped[1].session_id, "other");
  assert_eq!(deduped[1].display_title, distinct.display_title);
}

fn dashboard_item(
  session_id: &str,
  display_title: &str,
  last_activity_at: Option<&str>,
) -> DashboardConversationItem {
  DashboardConversationItem {
    session_id: session_id.to_string(),
    provider: Provider::Codex,
    project_path: "/tmp/orbitdock".to_string(),
    grouping_path: Some("/tmp/orbitdock".to_string()),
    grouping_name: Some("orbitdock".to_string()),
    project_name: Some("orbitdock".to_string()),
    repository_root: Some("/tmp/orbitdock".to_string()),
    git_branch: Some("main".to_string()),
    is_worktree: false,
    worktree_id: None,
    model: Some("gpt-5.4".to_string()),
    codex_integration_mode: None,
    claude_integration_mode: None,
    status: SessionStatus::Active,
    work_status: WorkStatus::Working,
    control_mode: SessionControlMode::Passive,
    lifecycle_state: SessionLifecycleState::Open,
    list_status: SessionListStatus::Working,
    display_title: display_title.to_string(),
    context_line: None,
    last_message: None,
    preview_text: None,
    activity_summary: None,
    alert_context: None,
    started_at: Some("2026-04-08T09:00:00Z".to_string()),
    last_activity_at: last_activity_at.map(ToString::to_string),
    unread_count: 0,
    has_turn_diff: false,
    diff_preview: None,
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    tool_count: 0,
    active_worker_count: 0,
    issue_identifier: None,
    effort: None,
  }
}
