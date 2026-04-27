use super::*;
use crate::support::session_time::parse_unix_z;
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::conversation_contracts::{
  rows::MessageDeliveryStatus, MessageRowContent, ShellExecutionPayload, ShellTerminalSnapshot,
  ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

fn session_handle(provider: Provider) -> SessionHandle {
  SessionHandle::new("session-1".to_string(), provider, "/repo".to_string())
}

fn pending_approval_session() -> SessionHandle {
  session_handle(Provider::Claude)
}

fn user_entry(session_id: &str, row_id: &str, content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: row_id.to_string(),
      content: content.to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn shell_tool_entry_with_large_payload(
  session_id: &str,
  row_id: &str,
  aggregated_output: String,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Tool(ToolRow {
      id: row_id.to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Completed,
      title: "cat big.log".to_string(),
      subtitle: Some("/tmp".to_string()),
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: Some(1),
      grouping_key: None,
      invocation: serde_json::json!({
        "command": "cat big.log",
        "cwd": "/tmp",
      }),
      result: None,
      render_hints: orbitdock_protocol::conversation_contracts::render_hints::RenderHints::default(
      ),
      tool_display: None,
      shell_execution: Some(ShellExecutionPayload {
        command: "cat big.log".to_string(),
        cwd: "/tmp".to_string(),
        process_id: None,
        actions: vec![],
        live_output_preview: None,
        aggregated_output: Some(aggregated_output),
        terminal_snapshot: Some(ShellTerminalSnapshot {
          command: "cat big.log".to_string(),
          cwd: "/tmp".to_string(),
          output: Some("payload".to_string()),
          transcript: "payload".to_string(),
          title: "/tmp".to_string(),
        }),
        preview: None,
        exit_code: Some(0),
      }),
    }),
  }
}

#[test]
fn broadcast_always_emits_active_sessions_invalidation() {
  let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
  let sessions_summary_revision = Arc::new(AtomicU64::new(0));
  let dashboard_revision = Arc::new(AtomicU64::new(0));
  let library_revision = Arc::new(AtomicU64::new(0));
  let mut session = session_handle(Provider::Codex);
  session.set_list_tx(list_tx);
  session.set_sessions_summary_revision_counter(sessions_summary_revision);
  session.set_dashboard_revision_counter(dashboard_revision);
  session.set_library_revision_counter(library_revision);

  session.broadcast(ServerMessage::SessionDelta {
    session_id: "session-1".to_string(),
    changes: Box::new(StateChanges {
      work_status: Some(WorkStatus::Working),
      ..Default::default()
    }),
  });

  let msg = list_rx
    .try_recv()
    .expect("sessions-summary invalidation should be emitted");
  assert!(matches!(
    msg,
    ServerMessage::SessionsSummaryInvalidated { revision: 1 }
  ));

  let msg = list_rx
    .try_recv()
    .expect("library invalidation should be emitted");
  assert!(matches!(
    msg,
    ServerMessage::ArchivedSessionsInvalidated { revision: 1 }
  ));

  let msg = list_rx
    .try_recv()
    .expect("dashboard update should be emitted");
  assert!(matches!(
    msg,
    ServerMessage::ActiveSessionsInvalidated { revision: 1 }
  ));
}

#[test]
fn broadcast_emits_dashboard_update_for_non_delta_messages() {
  let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
  let sessions_summary_revision = Arc::new(AtomicU64::new(0));
  let dashboard_revision = Arc::new(AtomicU64::new(0));
  let library_revision = Arc::new(AtomicU64::new(0));
  let mut session = session_handle(Provider::Codex);
  session.set_list_tx(list_tx);
  session.set_sessions_summary_revision_counter(sessions_summary_revision);
  session.set_dashboard_revision_counter(dashboard_revision);
  session.set_library_revision_counter(library_revision);

  session.broadcast(ServerMessage::ConversationRowsChanged {
    session_id: "session-1".to_string(),
    upserted: vec![],
    removed_row_ids: vec![],
    total_row_count: 0,
  });

  let msg = list_rx
    .try_recv()
    .expect("sessions-summary invalidation should be emitted for any message type");
  assert!(matches!(
    msg,
    ServerMessage::SessionsSummaryInvalidated { revision: 1 }
  ));

  let msg = list_rx
    .try_recv()
    .expect("library invalidation should be emitted for any message type");
  assert!(matches!(
    msg,
    ServerMessage::ArchivedSessionsInvalidated { revision: 1 }
  ));

  let msg = list_rx
    .try_recv()
    .expect("dashboard update should be emitted for any message type");
  assert!(matches!(
    msg,
    ServerMessage::ActiveSessionsInvalidated { revision: 1 }
  ));
}

#[test]
fn conversation_event_log_omits_heavy_command_payloads() {
  let mut session = session_handle(Provider::Codex);
  let row = shell_tool_entry_with_large_payload("session-1", "cmd-1", "x".repeat(25_000));
  let summary = row.to_summary();

  session.broadcast(ServerMessage::ConversationRowsChanged {
    session_id: "session-1".to_string(),
    upserted: vec![summary],
    removed_row_ids: vec![],
    total_row_count: 1,
  });

  let replay = session.replay_since(0).expect("replay");
  let payload = replay.first().expect("event payload");
  assert!(!payload.contains("\"aggregated_output\""));
  assert!(!payload.contains("\"terminal_snapshot\""));
  assert!(payload.contains("\"live_output_preview\""));
}

#[test]
fn replay_since_current_revision_without_event_log_returns_empty_replay() {
  let session = session_handle(Provider::Codex);

  let replay = session
    .replay_since(0)
    .expect("empty replay at current revision");

  assert!(replay.is_empty());
}

#[test]
fn set_config_syncs_sandbox_summary_from_explicit_details() {
  let mut session = session_handle(Provider::Codex);

  session.set_config(SessionConfigPatch {
    sandbox_policy_details: CodexSandboxPolicy::from_storage_text("workspace-write-network"),
    ..Default::default()
  });

  assert_eq!(
    session.config().sandbox_mode.as_deref(),
    Some("workspace-write-network")
  );
}

#[test]
fn set_config_syncs_approval_policy_summary_from_explicit_details() {
  let mut session = session_handle(Provider::Codex);

  session.set_config(SessionConfigPatch {
    approval_policy_details: orbitdock_protocol::CodexApprovalPolicy::from_storage_text("never"),
    ..Default::default()
  });

  assert_eq!(session.config().approval_policy.as_deref(), Some("never"));
}

#[test]
fn apply_changes_syncs_sandbox_summary_from_explicit_details() {
  let mut session = session_handle(Provider::Codex);

  session.apply_changes(&StateChanges {
    sandbox_policy_details: Some(CodexSandboxPolicy::from_storage_text("read-only-network")),
    ..Default::default()
  });

  assert_eq!(
    session.config().sandbox_mode.as_deref(),
    Some("read-only-network")
  );

  session.apply_changes(&StateChanges {
    sandbox_policy_details: Some(None),
    ..Default::default()
  });

  assert!(session.config().sandbox_mode.is_none());
}

#[test]
fn apply_changes_syncs_approval_policy_summary_from_explicit_details() {
  let mut session = session_handle(Provider::Codex);

  session.apply_changes(&StateChanges {
    approval_policy_details: Some(orbitdock_protocol::CodexApprovalPolicy::from_storage_text(
      "never",
    )),
    ..Default::default()
  });

  assert_eq!(session.config().approval_policy.as_deref(), Some("never"));

  session.apply_changes(&StateChanges {
    approval_policy_details: Some(None),
    ..Default::default()
  });

  assert!(session.config().approval_policy.is_none());
}

#[test]
fn duplicate_pending_approval_is_a_no_op() {
  let mut session = pending_approval_session();
  let request = ApprovalRequest {
    id: "approval-1".to_string(),
    session_id: session.id().to_string(),
    approval_type: ApprovalType::Exec,
    tool_name: Some("Bash".to_string()),
    tool_input: Some("{\"command\":\"ls\"}".to_string()),
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

  session.queue_pending_approval(request.clone(), ApprovalType::Exec, None);
  session.promote_queue_front();
  let version_after_first = session.approval_version();

  session.queue_pending_approval(request, ApprovalType::Exec, None);
  session.promote_queue_front();

  assert_eq!(session.approval_version(), version_after_first);
  assert_eq!(session.state.pending_approval_count(), 1);
  assert_eq!(session.state.pending_approval_id(), Some("approval-1"));
}

#[test]
fn control_mode_from_parts_uses_provider_specific_integration_mode() {
  assert_eq!(
    control_mode_from_parts(Provider::Codex, Some(CodexIntegrationMode::Direct), None),
    SessionControlMode::Direct
  );
  assert_eq!(
    control_mode_from_parts(Provider::Codex, Some(CodexIntegrationMode::Passive), None),
    SessionControlMode::Passive
  );
  assert_eq!(
    control_mode_from_parts(Provider::Claude, None, Some(ClaudeIntegrationMode::Direct)),
    SessionControlMode::Direct
  );
  assert_eq!(
    control_mode_from_parts(Provider::Claude, None, Some(ClaudeIntegrationMode::Passive)),
    SessionControlMode::Passive
  );
}

#[test]
fn accepts_user_input_from_parts_requires_direct_open_active_sessions() {
  assert!(accepts_user_input_from_parts(
    SessionStatus::Active,
    SessionControlMode::Direct,
    SessionLifecycleState::Open,
  ));
  assert!(!accepts_user_input_from_parts(
    SessionStatus::Active,
    SessionControlMode::Direct,
    SessionLifecycleState::Resumable,
  ));
  assert!(!accepts_user_input_from_parts(
    SessionStatus::Active,
    SessionControlMode::Passive,
    SessionLifecycleState::Open,
  ));
  assert!(!accepts_user_input_from_parts(
    SessionStatus::Ended,
    SessionControlMode::Direct,
    SessionLifecycleState::Open,
  ));
}

#[test]
fn conversation_bootstrap_projects_direct_active_sessions_as_open_and_sendable() {
  let mut session = session_handle(Provider::Codex);
  session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  session.set_status(SessionStatus::Active);
  session.set_work_status(WorkStatus::Waiting);

  let bootstrap = session.conversation_bootstrap(10);

  assert_eq!(bootstrap.session.control_mode, SessionControlMode::Direct);
  assert_eq!(
    bootstrap.session.lifecycle_state,
    SessionLifecycleState::Open
  );
  assert!(bootstrap.session.accepts_user_input);
}

#[test]
fn retained_state_marks_direct_open_working_sessions_interruptible() {
  let mut session = session_handle(Provider::Codex);
  session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  session.set_status(SessionStatus::Active);
  session.set_work_status(WorkStatus::Working);

  let working = session.retained_state();
  assert!(working.can_interrupt);

  session.set_work_status(WorkStatus::Waiting);
  let settled = session.retained_state();
  assert!(!settled.can_interrupt);
}

#[test]
fn conversation_bootstrap_projects_passive_sessions_as_open_but_not_sendable() {
  let mut session = session_handle(Provider::Codex);
  session.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
  session.set_status(SessionStatus::Active);
  session.set_work_status(WorkStatus::Waiting);

  let bootstrap = session.conversation_bootstrap(10);

  assert_eq!(bootstrap.session.control_mode, SessionControlMode::Passive);
  assert_eq!(
    bootstrap.session.lifecycle_state,
    SessionLifecycleState::Open
  );
  assert!(!bootstrap.session.accepts_user_input);
}

#[test]
fn changed_pending_approval_updates_version_in_place() {
  let mut session = pending_approval_session();
  let sid = session.id().to_string();
  let make_request = |input: &str| ApprovalRequest {
    id: "approval-1".to_string(),
    session_id: sid.clone(),
    approval_type: ApprovalType::Exec,
    tool_name: Some("Bash".to_string()),
    tool_input: Some(input.to_string()),
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

  session.queue_pending_approval(
    make_request("{\"command\":\"ls\"}"),
    ApprovalType::Exec,
    None,
  );
  session.promote_queue_front();

  session.queue_pending_approval(
    make_request("{\"command\":\"pwd\"}"),
    ApprovalType::Exec,
    None,
  );
  session.promote_queue_front();

  assert_eq!(session.approval_version(), 2);
  assert_eq!(session.state.pending_approval_count(), 1);
  assert_eq!(
    session.state.pending_tool_input(),
    Some("{\"command\":\"pwd\"}")
  );
}

#[test]
fn apply_changes_with_same_pending_approval_does_not_bump_version() {
  let mut session = pending_approval_session();
  let request = ApprovalRequest {
    id: "approval-1".to_string(),
    session_id: "session-1".to_string(),
    approval_type: ApprovalType::Question,
    tool_name: Some("AskUserQuestion".to_string()),
    tool_input: Some("{\"question\":\"Ship it?\"}".to_string()),
    command: None,
    file_path: None,
    diff: None,
    question: Some("Ship it?".to_string()),
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

  session.apply_changes(&StateChanges {
    pending_approval: Some(Some(request.clone())),
    work_status: Some(WorkStatus::Question),
    ..Default::default()
  });
  let version_after_first = session.approval_version();

  session.apply_changes(&StateChanges {
    pending_approval: Some(Some(request)),
    work_status: Some(WorkStatus::Question),
    ..Default::default()
  });

  assert_eq!(session.approval_version(), version_after_first);
  assert_eq!(session.state.pending_approval_count(), 1);
}

#[test]
fn metadata_setters_do_not_mutate_activity_timestamps() {
  let mut session = pending_approval_session();
  let original_last_activity_at = session.state.last_activity_at().map(str::to_string);
  let original_last_progress_at = session.state.last_progress_at().map(str::to_string);

  session.set_custom_name(Some("Renamed".to_string()));
  session.set_status(SessionStatus::Active);
  session.set_work_status(WorkStatus::Working);
  session.set_last_tool(Some("Read".to_string()));

  assert_eq!(
    session.state.last_activity_at(),
    original_last_activity_at.as_deref()
  );
  assert_eq!(
    session.state.last_progress_at(),
    original_last_progress_at.as_deref()
  );
}

#[test]
fn imperative_row_mutations_use_unix_z_progress_timestamps() {
  let mut session = pending_approval_session();
  let row = user_entry("session-1", "user-1", "hello");

  session.add_row(row);

  assert!(parse_unix_z(session.state.last_activity_at()).is_some());
  assert!(parse_unix_z(session.state.last_progress_at()).is_some());
}

#[test]
fn user_rows_update_activity_without_advancing_progress() {
  let mut session = pending_approval_session();
  let original_last_progress_at = session.state.last_progress_at().map(str::to_string);

  session.add_row(user_entry("session-1", "user-1", "hello"));

  assert!(parse_unix_z(session.state.last_activity_at()).is_some());
  assert_eq!(
    session.state.last_progress_at(),
    original_last_progress_at.as_deref()
  );
}

#[test]
fn steer_rows_do_not_count_for_user_echo_dedup() {
  let mut session = pending_approval_session();
  let steer = ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Steer(MessageRowContent {
      id: "steer-1".to_string(),
      content: "same content".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: Some(MessageDeliveryStatus::Pending),
    }),
  };

  session.add_row(steer);

  assert!(!session.has_user_row_with_content("same content"));
}

#[test]
fn apply_state_recomputes_newest_synced_row_id_from_rows() {
  let mut session = pending_approval_session();
  session.add_row(user_entry("session-1", "user-1", "hello"));
  session.set_newest_synced_row_id(Some("stale-row".to_string()));

  let mut state = session.extract_state();
  state.rows.push(ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence: 1,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: "assistant-2".to_string(),
      content: "done".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  });
  state.total_row_count = state.rows.len() as u64;

  session.apply_state(state);

  assert_eq!(session.newest_synced_row_id(), Some("assistant-2"));
}
