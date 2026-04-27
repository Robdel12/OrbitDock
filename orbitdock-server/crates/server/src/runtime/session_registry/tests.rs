use super::SessionRegistry;
use crate::domain::sessions::session::SessionHandle;
use crate::support::test_support::ensure_server_test_data_dir;
use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::{
  CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState, SessionStatus,
  SubagentInfo, SubagentStatus, WorkStatus,
};
use tokio::sync::mpsc;

#[test]
fn registry_clears_primary_claims_by_connection() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  registry.set_client_primary_claim(1, "client-a".into(), "MacBook Pro".into(), true);
  assert!(registry.clear_client_primary_claim(1));
  assert!(registry.active_client_primary_claims().is_empty());
  assert!(!registry.clear_client_primary_claim(1));
}

#[tokio::test]
async fn dashboard_conversations_only_include_active_sessions() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut active = SessionHandle::new(
    "active-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-active".to_string(),
  );
  active.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
  active.set_work_status(WorkStatus::Waiting);
  active.refresh_snapshot();
  registry.add_session(active);

  let mut ended = SessionHandle::new(
    "ended-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-ended".to_string(),
  );
  ended.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
  ended.set_status(SessionStatus::Ended);
  ended.set_work_status(WorkStatus::Ended);
  ended.refresh_snapshot();
  registry.add_session(ended);

  let conversations =
    crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
  assert_eq!(conversations.len(), 1);
  assert_eq!(conversations[0].session_id, "active-session");
}

#[tokio::test]
async fn dashboard_conversations_include_server_owned_summary_fields() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut session = SessionHandle::new(
    "summary-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-summary".to_string(),
  );
  session.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
  session.set_project_name(Some("orbitdock".to_string()));
  session.set_worktree_info(Some("/tmp/orbitdock".to_string()), false, None);
  session.set_first_prompt(Some("Check the latest output".to_string()));
  session.set_last_message(Some("## Heading with `code`".to_string()));
  session.set_pending_attention(
    Some("Bash".to_string()),
    Some(r#"{"command":"ls -la"}"#.to_string()),
    None,
  );
  session.set_work_status(WorkStatus::Waiting);
  session.refresh_snapshot();
  registry.add_session(session);

  let conversations =
    crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
  assert_eq!(conversations.len(), 1);

  let conversation = &conversations[0];
  assert_eq!(
    conversation.preview_text.as_deref(),
    Some("Heading with code")
  );
  assert_eq!(
    conversation.activity_summary.as_deref(),
    Some("Running Bash")
  );
  assert_eq!(conversation.alert_context.as_deref(), Some("ls -la"));
  assert_eq!(
    conversation.grouping_path.as_deref(),
    Some("/tmp/orbitdock")
  );
  assert_eq!(conversation.grouping_name.as_deref(), Some("orbitdock"));
}

#[tokio::test]
async fn dashboard_conversations_project_control_and_lifecycle_state() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let (action_tx, _action_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut direct = SessionHandle::new(
    "direct-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-direct".to_string(),
  );
  direct.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  direct.set_work_status(WorkStatus::Waiting);
  direct.set_status(SessionStatus::Active);
  direct.refresh_snapshot();
  registry.add_session(direct);
  registry.set_codex_action_tx("direct-session", action_tx);

  let conversations =
    crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
  let conversation = conversations
    .iter()
    .find(|entry| entry.session_id == "direct-session")
    .expect("direct session should be visible");

  assert_eq!(conversation.control_mode, SessionControlMode::Direct);
  assert_eq!(conversation.lifecycle_state, SessionLifecycleState::Open);
}

#[tokio::test]
async fn dashboard_and_session_summaries_preserve_worker_and_issue_fields() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut session = SessionHandle::new(
    "mission-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-mission".to_string(),
  );
  session.set_mission_context(Some("mission-1".to_string()), Some("PROJ-42".to_string()));
  session.set_subagents(vec![
    SubagentInfo {
      id: "worker-1".to_string(),
      agent_type: AgentType::BackgroundTask,
      started_at: "2026-03-30T10:00:00Z".to_string(),
      ended_at: None,
      provider: None,
      label: None,
      status: SubagentStatus::Running,
      task_summary: None,
      result_summary: None,
      error_summary: None,
      parent_subagent_id: None,
      model: None,
      last_activity_at: None,
    },
    SubagentInfo {
      id: "worker-2".to_string(),
      agent_type: AgentType::BackgroundTask,
      started_at: "2026-03-30T09:00:00Z".to_string(),
      ended_at: Some("2026-03-30T09:30:00Z".to_string()),
      provider: None,
      label: None,
      status: SubagentStatus::Completed,
      task_summary: None,
      result_summary: None,
      error_summary: None,
      parent_subagent_id: None,
      model: None,
      last_activity_at: None,
    },
  ]);
  session.refresh_snapshot();
  registry.add_session(session);

  let summary = registry
    .get_session_summaries()
    .into_iter()
    .find(|item| item.id == "mission-session")
    .expect("session summary should exist");
  assert_eq!(summary.active_worker_count, 1);
  assert_eq!(summary.mission_id.as_deref(), Some("mission-1"));
  assert_eq!(summary.issue_identifier.as_deref(), Some("PROJ-42"));

  let conversation = crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry)
    .conversations
    .into_iter()
    .find(|item| item.session_id == "mission-session")
    .expect("dashboard conversation should exist");
  assert_eq!(conversation.active_worker_count, 1);
  assert_eq!(conversation.issue_identifier.as_deref(), Some("PROJ-42"));
}

#[tokio::test]
async fn dashboard_snapshot_reflects_in_memory_tool_count() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut session = SessionHandle::new(
    "tool-session".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-tools".to_string(),
  );
  for _ in 0..7 {
    session.increment_tool_count();
  }
  session.refresh_snapshot();
  registry.add_session(session);

  let conversation = crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry)
    .conversations
    .into_iter()
    .find(|item| item.session_id == "tool-session")
    .expect("dashboard conversation should exist");
  assert_eq!(conversation.tool_count, 7);
}

#[tokio::test]
async fn runtime_owner_registration_resolves_before_sqlite_flush() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = SessionRegistry::new_with_primary(persist_tx, true);

  let mut codex_session = SessionHandle::new(
    "direct-codex-owner".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-direct-codex-owner".to_string(),
  );
  codex_session.set_codex_integration_mode(Some(orbitdock_protocol::CodexIntegrationMode::Direct));
  codex_session.set_status(orbitdock_protocol::SessionStatus::Active);
  codex_session.refresh_snapshot();
  registry.add_session(codex_session);

  let mut claude_session = SessionHandle::new(
    "direct-claude-owner".to_string(),
    Provider::Claude,
    "/tmp/orbitdock-direct-claude-owner".to_string(),
  );
  claude_session
    .set_claude_integration_mode(Some(orbitdock_protocol::ClaudeIntegrationMode::Direct));
  claude_session.set_status(orbitdock_protocol::SessionStatus::Active);
  claude_session.refresh_snapshot();
  registry.add_session(claude_session);

  registry.register_codex_runtime_owner("thread-immediate", "direct-codex-owner");
  registry.register_claude_runtime_owner("sdk-immediate", "direct-claude-owner");

  assert_eq!(
    registry.resolve_codex_thread("thread-immediate"),
    Some("direct-codex-owner".to_string())
  );
  assert_eq!(
    registry.resolve_claude_thread("sdk-immediate"),
    Some("direct-claude-owner".to_string())
  );
}
