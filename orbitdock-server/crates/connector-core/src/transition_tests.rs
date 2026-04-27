use super::*;
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::{ApprovalPreviewType, ApprovalRiskLevel, TokenUsage};
use serde_json::json;

fn test_state() -> TransitionState {
  TransitionState {
    id: "test-session".to_string(),
    provider: Provider::Claude,
    revision: 0,
    phase: WorkPhase::Idle,
    rows: Vec::new(),
    total_row_count: 0,
    token_usage: TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
    current_diff: None,
    current_plan: None,
    custom_name: None,
    project_path: "/tmp/project".to_string(),
    last_activity_at: None,
    last_progress_at: None,
    current_turn_id: None,
    turn_count: 0,
    turn_diffs: Vec::new(),
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    pending_approval: None,
    repository_root: None,
    is_worktree: false,
    model: None,
    transcript_path: None,
    last_tool: None,
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    subagents: Vec::new(),
    summary: None,
    effort: None,
    first_prompt: None,
    turn_input_tokens: 0,
    turn_output_tokens: 0,
    turn_cached_tokens: 0,
    turn_usage_snapshot: None,
    turn_usage_snapshot_kind: None,
  }
}

fn test_user_row(content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: String::new(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::User(MessageRowContent {
      id: format!("msg-{}", content.len()),
      content: content.to_string(),
      turn_id: None,
      timestamp: Some("0Z".to_string()),
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn test_assistant_row(content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: String::new(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Assistant(MessageRowContent {
      id: format!("msg-{}", content.len()),
      content: content.to_string(),
      turn_id: None,
      timestamp: Some("0Z".to_string()),
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn test_tool_row(id: &str, status: ToolStatus) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: String::new(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Tool(ToolRow {
      id: id.to_string(),
      provider: Provider::Claude,
      family: ToolFamily::Generic,
      kind: ToolKind::Generic,
      status,
      title: id.to_string(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: json!({
          "tool_name": "test",
      }),
      result: None,
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    }),
  }
}

#[test]
fn connector_output_state_lane_converts_to_input() {
  let output: ConnectorOutput = ConnectorStateEvent::TurnStarted.into();
  let input = Input::try_from(output).expect("state output should convert to input");
  assert!(matches!(input, Input::TurnStarted));
}

#[test]
fn connector_output_runtime_lane_is_rejected_by_input_conversion() {
  let output = ConnectorOutput::Runtime(crate::ConnectorRuntimeDirective::HookSessionId(
    "hook-123".to_string(),
  ));

  let err = Input::try_from(output).expect_err("runtime directives must not reach reducer");
  assert!(matches!(
    err,
    ConnectorOutput::Runtime(crate::ConnectorRuntimeDirective::HookSessionId(_))
  ));
}

#[test]
fn connector_output_transport_lane_is_rejected_by_input_conversion() {
  let output = ConnectorOutput::Transport(crate::ConnectorTransportEffect::ToolPtyCreated {
    tool_id: "tool-123".to_string(),
  });

  let err = Input::try_from(output).expect_err("transport effects must not reach reducer");
  assert!(matches!(
    err,
    ConnectorOutput::Transport(crate::ConnectorTransportEffect::ToolPtyCreated { .. })
  ));
}

const NOW: &str = "1000Z";

#[test]
fn turn_started_transitions_to_working() {
  let state = test_state();
  let (new_state, effects) = transition(state, Input::TurnStarted, NOW);

  assert_eq!(new_state.phase, WorkPhase::Working);
  assert_eq!(effects.len(), 2); // Persist + Emit
  assert!(matches!(
      effects[0],
      Effect::Persist(ref op) if matches!(**op, PersistOp::SessionUpdate { .. })
  ));
  assert!(matches!(
      effects[1],
      Effect::Emit(ref msg) if matches!(**msg, ServerMessage::SessionDelta { .. })
  ));
}

#[test]
fn turn_completed_transitions_to_idle() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  assert_eq!(new_state.phase, WorkPhase::Idle);
  assert_eq!(effects.len(), 2);
}

#[test]
fn turn_completed_when_idle_stays_idle() {
  let state = test_state();
  assert_eq!(state.phase, WorkPhase::Idle);

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  // Phase stays Idle (guard prevents transition from non-Working)
  assert_eq!(new_state.phase, WorkPhase::Idle);
  // Still emits persist + broadcast for consistency
  assert_eq!(effects.len(), 2);
}

#[test]
fn approval_requested_sets_awaiting_phase() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(
    state,
    Input::ApprovalRequested {
      request_id: "req-1".to_string(),
      approval_type: ApprovalType::Exec,
      tool_name: None,
      tool_input: None,
      command: Some("rm -rf /".to_string()),
      file_path: None,
      diff: None,
      question: None,
      permission_reason: None,
      requested_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    },
    NOW,
  );

  assert!(matches!(
      new_state.phase,
      WorkPhase::AwaitingApproval {
          ref request_id,
          approval_type: ApprovalType::Exec,
          ..
      } if request_id == "req-1"
  ));
  // Persist(SessionUpdate) + Persist(ApprovalRequested) + Emit(ApprovalRequested)
  assert_eq!(effects.len(), 3);

  if let Effect::Emit(message) = &effects[2] {
    match message.as_ref() {
      ServerMessage::ApprovalRequested { request, .. } => {
        let preview = request.preview.as_ref().expect("expected preview");
        assert_eq!(preview.preview_type, ApprovalPreviewType::ShellCommand);
        assert_eq!(preview.compact.as_deref(), Some("rm -rf /"));
        assert_eq!(
          preview.decision_scope.as_deref(),
          Some("approve/deny applies to all command segments in this request.")
        );
        assert_eq!(preview.risk_level, ApprovalRiskLevel::High);
        assert!(preview
          .risk_findings
          .iter()
          .any(|finding| finding == "Deletes files recursively with rm -rf."));
        assert!(preview
          .manifest
          .as_deref()
          .is_some_and(|manifest| manifest.contains("APPROVAL MANIFEST")));
      }
      other => panic!("expected approval_requested emit, got {other:?}"),
    }
  }
}

#[test]
fn approval_requested_preview_segments_shell_control_operators() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(
    state,
    Input::ApprovalRequested {
      request_id: "req-shell".to_string(),
      approval_type: ApprovalType::Exec,
      tool_name: Some("Bash".to_string()),
      tool_input: Some(r#"{"command":"echo one || echo two"}"#.to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: None,
      permission_reason: None,
      requested_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    },
    NOW,
  );

  assert!(matches!(
      new_state.phase,
      WorkPhase::AwaitingApproval {
          ref request_id,
          approval_type: ApprovalType::Exec,
          ..
      } if request_id == "req-shell"
  ));
  assert_eq!(effects.len(), 3);

  if let Effect::Emit(message) = &effects[2] {
    match message.as_ref() {
      ServerMessage::ApprovalRequested { request, .. } => {
        let preview = request.preview.as_ref().expect("expected preview");
        assert_eq!(preview.preview_type, ApprovalPreviewType::ShellCommand);
        assert_eq!(preview.shell_segments.len(), 2);
        assert_eq!(preview.shell_segments[0].leading_operator, None);
        assert_eq!(
          preview.shell_segments[1].leading_operator.as_deref(),
          Some("||")
        );
        assert_eq!(preview.compact.as_deref(), Some("echo one +1 segment"));
        assert_eq!(preview.risk_level, ApprovalRiskLevel::Normal);
        assert!(preview.risk_findings.is_empty());
        assert!(preview
          .manifest
          .as_deref()
          .is_some_and(|manifest| manifest.contains("[2] (||, if previous fails) echo two")));
      }
      other => panic!("expected approval_requested emit, got {other:?}"),
    }
  }
}

#[test]
fn approval_requested_preview_uses_basename_for_patch_like_tools() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (_, effects) = transition(
    state,
    Input::ApprovalRequested {
      request_id: "req-edit".to_string(),
      approval_type: ApprovalType::Patch,
      tool_name: Some("Edit".to_string()),
      tool_input: Some(r#"{"file_path":"/tmp/OrbitDock/docs/approvals.md"}"#.to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: None,
      permission_reason: None,
      requested_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    },
    NOW,
  );

  if let Effect::Emit(message) = &effects[1] {
    match message.as_ref() {
      ServerMessage::ApprovalRequested { request, .. } => {
        let preview = request.preview.as_ref().expect("expected preview");
        assert_eq!(preview.preview_type, ApprovalPreviewType::FilePath);
        assert_eq!(preview.value, "/tmp/OrbitDock/docs/approvals.md");
        assert_eq!(preview.compact.as_deref(), Some("approvals.md"));
        assert_eq!(
          preview.decision_scope.as_deref(),
          Some("approve/deny applies to this full file action.")
        );
        assert!(preview.manifest.as_deref().is_some_and(
          |manifest| manifest.contains("target_file: /tmp/OrbitDock/docs/approvals.md")
        ));
      }
      other => panic!("expected approval_requested emit, got {other:?}"),
    }
  }
}

#[test]
fn approval_requested_preview_uses_diff_for_patch_requests_with_text_changes() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (_, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-edit-diff".to_string(),
                approval_type: ApprovalType::Patch,
                tool_name: Some("Edit".to_string()),
                tool_input: Some(
                    r#"{"file_path":"/tmp/OrbitDock/docs/approvals.md","old_string":"line one","new_string":"line two"}"#
                        .to_string(),
                ),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
            },
            NOW,
        );

  if let Effect::Emit(message) = &effects[1] {
    match message.as_ref() {
      ServerMessage::ApprovalRequested { request, .. } => {
        let preview = request.preview.as_ref().expect("expected preview");
        assert_eq!(preview.preview_type, ApprovalPreviewType::Diff);
        assert!(preview
          .value
          .contains("--- /tmp/OrbitDock/docs/approvals.md"));
        assert!(preview
          .value
          .contains("+++ /tmp/OrbitDock/docs/approvals.md"));
        assert!(preview.value.contains("-line one"));
        assert!(preview.value.contains("+line two"));
        assert!(preview
          .compact
          .as_deref()
          .is_some_and(|compact| compact.contains("approvals.md")));
        assert_eq!(
          preview.decision_scope.as_deref(),
          Some("approve/deny applies to this full file action.")
        );
        assert!(preview
          .manifest
          .as_deref()
          .is_some_and(|manifest| manifest.contains("diff_preview:")));
      }
      other => panic!("expected approval_requested emit, got {other:?}"),
    }
  }
}

#[test]
fn build_approval_preview_covers_supported_non_shell_preview_types() {
  let cases: [(&str, ApprovalType, ApprovalPreviewType, &str, &str); 7] = [
    (
      r#"{"url":"https://example.com/docs"}"#,
      ApprovalType::Exec,
      ApprovalPreviewType::Url,
      "target_url: https://example.com/docs",
      "approve/deny applies to this full tool action.",
    ),
    (
      r#"{"query":"latest orbitdock release"}"#,
      ApprovalType::Exec,
      ApprovalPreviewType::SearchQuery,
      "search_query: latest orbitdock release",
      "approve/deny applies to this full tool action.",
    ),
    (
      r#"{"pattern":"session.resume.connector_failed"}"#,
      ApprovalType::Exec,
      ApprovalPreviewType::Pattern,
      "pattern: session.resume.connector_failed",
      "approve/deny applies to this full tool action.",
    ),
    (
      r#"{"prompt":"Summarize approval history"}"#,
      ApprovalType::Exec,
      ApprovalPreviewType::Prompt,
      "prompt: Summarize approval history",
      "approve/deny applies to this full tool action.",
    ),
    (
      r#"{"file_path":"/tmp/OrbitDock/README.md"}"#,
      ApprovalType::Patch,
      ApprovalPreviewType::FilePath,
      "target_file: /tmp/OrbitDock/README.md",
      "approve/deny applies to this full file action.",
    ),
    (
      r#"{"file_path":"/tmp/OrbitDock/README.md","old_string":"alpha","new_string":"beta"}"#,
      ApprovalType::Patch,
      ApprovalPreviewType::Diff,
      "diff_preview:",
      "approve/deny applies to this full file action.",
    ),
    (
      r#"{"foo":"bar"}"#,
      ApprovalType::Exec,
      ApprovalPreviewType::Value,
      "value: bar",
      "approve/deny applies to this full tool action.",
    ),
  ];

  for (tool_input, approval_type, expected_preview_type, expected_manifest_line, expected_scope) in
    cases
  {
    let preview = build_approval_preview(ApprovalPreviewInput {
      request_id: "req-matrix",
      approval_type,
      tool_name: Some("Bash"),
      tool_input: Some(tool_input),
      command: None,
      file_path: None,
      diff: None,
      question: None,
      permission_reason: None,
    })
    .expect("expected preview");

    assert_eq!(preview.preview_type, expected_preview_type);
    assert_eq!(preview.decision_scope.as_deref(), Some(expected_scope));
    assert!(preview
      .manifest
      .as_deref()
      .is_some_and(|manifest| manifest.contains(expected_manifest_line)));
  }
}

#[test]
fn build_approval_preview_uses_prompt_preview_with_scope_and_low_risk_for_question() {
  let preview = build_approval_preview(ApprovalPreviewInput {
    request_id: "req-question",
    approval_type: ApprovalType::Question,
    tool_name: Some("AskUserQuestion"),
    tool_input: None,
    command: None,
    file_path: None,
    diff: None,
    question: Some("How should we continue?"),
    permission_reason: None,
  })
  .expect("expected preview");

  assert_eq!(preview.preview_type, ApprovalPreviewType::Prompt);
  assert_eq!(preview.value, "How should we continue?");
  assert_eq!(
    preview.decision_scope.as_deref(),
    Some("approve/deny applies to this full tool action.")
  );
  assert_eq!(preview.risk_level, ApprovalRiskLevel::Low);
  assert!(preview.risk_findings.is_empty());
  assert!(preview
    .manifest
    .as_deref()
    .is_some_and(|manifest| manifest.contains("prompt: How should we continue?")));
}

#[test]
fn approval_requested_extracts_structured_question_prompts_from_tool_input() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let question_input = r#"{
            "questions": [
                {
                    "id": "launch_mode",
                    "header": "Launch",
                    "question": "How do you want to launch?",
                    "options": [
                        { "label": "Open Sheet", "description": "Open the full sheet first" },
                        { "label": "Quick Launch", "description": "Use defaults now" }
                    ],
                    "multiSelect": true,
                    "isOther": true
                }
            ]
        }"#;

  let (_, effects) = transition(
    state,
    Input::ApprovalRequested {
      request_id: "req-question-metadata".to_string(),
      approval_type: ApprovalType::Question,
      tool_name: Some("AskUserQuestion".to_string()),
      tool_input: Some(question_input.to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: None,
      permission_reason: None,
      requested_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    },
    NOW,
  );

  if let Effect::Emit(message) = &effects[1] {
    match message.as_ref() {
      ServerMessage::ApprovalRequested { request, .. } => {
        assert_eq!(
          request.question.as_deref(),
          Some("How do you want to launch?")
        );
        assert_eq!(request.question_prompts.len(), 1);
        let prompt = &request.question_prompts[0];
        assert_eq!(prompt.id, "launch_mode");
        assert_eq!(prompt.header.as_deref(), Some("Launch"));
        assert_eq!(prompt.options.len(), 2);
        assert!(prompt.allows_multiple_selection);
        assert!(prompt.allows_other);
        assert!(!prompt.is_secret);
      }
      other => panic!("expected approval_requested emit, got {other:?}"),
    }
  }
}

#[test]
fn row_created_appends_to_state() {
  let state = test_state();
  let entry = test_assistant_row("Hello world");

  let (new_state, effects) = transition(state, Input::RowCreated(entry), NOW);

  assert_eq!(new_state.rows.len(), 1);
  if let ConversationRow::Assistant(ref msg) = new_state.rows[0].row {
    assert_eq!(msg.content, "Hello world");
  } else {
    panic!("expected Assistant row");
  }
  assert_eq!(effects.len(), 2); // Persist + Emit
}

#[test]
fn row_created_with_existing_id_upserts_instead_of_appending() {
  let mut state = test_state();
  let mut entry = test_assistant_row("first");
  if let ConversationRow::Assistant(ref mut msg) = entry.row {
    msg.id = "guardian-call-1".to_string();
  }
  entry.sequence = 7;
  state.rows.push(entry.clone());
  state.total_row_count = 1;

  let mut updated_entry = entry.clone();
  if let ConversationRow::Assistant(ref mut msg) = updated_entry.row {
    msg.content = "updated".to_string();
  }
  updated_entry.sequence = 0;

  let (new_state, effects) = transition(state, Input::RowCreated(updated_entry), NOW);

  assert_eq!(new_state.rows.len(), 1);
  assert_eq!(new_state.rows[0].sequence, 7);
  if let ConversationRow::Assistant(ref msg) = new_state.rows[0].row {
    assert_eq!(msg.id, "guardian-call-1");
    assert_eq!(msg.content, "updated");
  } else {
    panic!("expected Assistant row");
  }
  assert!(matches!(
      effects[0],
      Effect::Persist(ref op)
          if matches!(op.as_ref(), PersistOp::RowUpsert { .. })
  ));
}

#[test]
fn row_updated_mutates_existing_state_row() {
  let mut state = test_state();
  let mut entry = test_assistant_row("I");
  // Give it a known id
  if let ConversationRow::Assistant(ref mut msg) = entry.row {
    msg.id = "msg-stream".to_string();
  }
  entry.sequence = 1;
  state.rows.push(entry.clone());
  state.total_row_count = 1;

  // Build the updated entry
  let mut updated_entry = entry.clone();
  if let ConversationRow::Assistant(ref mut msg) = updated_entry.row {
    msg.content = "I'm now cross-checking the highest-risk claims".to_string();
  }

  let (new_state, effects) = transition(
    state,
    Input::RowUpdated {
      row_id: "msg-stream".to_string(),
      entry: updated_entry,
    },
    NOW,
  );

  assert_eq!(new_state.rows.len(), 1);
  if let ConversationRow::Assistant(ref msg) = new_state.rows[0].row {
    assert_eq!(msg.id, "msg-stream");
    assert_eq!(
      msg.content,
      "I'm now cross-checking the highest-risk claims"
    );
  } else {
    panic!("expected Assistant row");
  }
  assert_eq!(new_state.last_activity_at.as_deref(), Some(NOW));
  assert_eq!(effects.len(), 2); // Persist + Emit
}

#[test]
fn row_updated_inserts_when_row_is_missing() {
  let state = test_state();
  let mut entry = test_assistant_row("late arrival");
  if let ConversationRow::Assistant(ref mut msg) = entry.row {
    msg.id = "guardian-call-2".to_string();
  }
  entry.sequence = 0;

  let (new_state, effects) = transition(
    state,
    Input::RowUpdated {
      row_id: "guardian-call-2".to_string(),
      entry,
    },
    NOW,
  );

  assert_eq!(new_state.rows.len(), 1);
  assert_eq!(new_state.rows[0].sequence, 0);
  assert_eq!(new_state.total_row_count, 1);
  assert!(matches!(
      effects[0],
      Effect::Persist(ref op)
          if matches!(op.as_ref(), PersistOp::RowUpsert { .. })
  ));
}

#[test]
fn row_updated_preserves_dynamic_tool_invocation_when_update_is_placeholder() {
  let mut state = test_state();
  let existing_invocation = json!({
    "tool_name": "file_write",
    "raw_input": {
      "path": ".tmp_codex_tool_probe.txt",
      "content": "hello-from-file-write"
    }
  });
  let existing = ConversationRowEntry {
    session_id: String::new(),
    sequence: 2,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Tool(ToolRow {
      id: "call_dynamic_1".to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Generic,
      kind: ToolKind::DynamicToolCall,
      status: ToolStatus::Running,
      title: "file_write".to_string(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: existing_invocation.clone(),
      result: None,
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    }),
  };
  state.rows.push(existing.clone());
  state.total_row_count = 1;

  let incoming = ConversationRowEntry {
    session_id: String::new(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Tool(ToolRow {
      id: "call_dynamic_1".to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Generic,
      kind: ToolKind::DynamicToolCall,
      status: ToolStatus::Completed,
      title: String::new(),
      subtitle: None,
      summary: Some("{\"ok\":true}".to_string()),
      preview: None,
      started_at: None,
      ended_at: Some("1001Z".to_string()),
      duration_ms: Some(11),
      grouping_key: None,
      invocation: json!({ "tool_name": "" }),
      result: Some(json!({
        "tool_name": "",
        "raw_output": "{\"ok\":true}",
        "summary": "{\"ok\":true}"
      })),
      render_hints: RenderHints::default(),
      shell_execution: None,
      tool_display: None,
    }),
  };

  let (new_state, _) = transition(
    state,
    Input::RowUpdated {
      row_id: "call_dynamic_1".to_string(),
      entry: incoming,
    },
    NOW,
  );

  let ConversationRow::Tool(updated_tool) = &new_state.rows[0].row else {
    panic!("expected tool row");
  };
  assert_eq!(updated_tool.invocation, existing_invocation);
}

#[test]
fn user_row_dedup_skips_echo() {
  let mut state = test_state();
  state.rows.push(test_user_row("do something"));

  let echo = test_user_row("do something");
  let (new_state, effects) = transition(state, Input::RowCreated(echo), NOW);

  // Should NOT add duplicate
  assert_eq!(new_state.rows.len(), 1);
  assert!(effects.is_empty());
}

#[test]
fn session_ended_transitions_to_ended() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(
    state,
    Input::SessionEnded {
      reason: "user_quit".to_string(),
    },
    NOW,
  );

  assert!(matches!(
      new_state.phase,
      WorkPhase::Ended { ref reason } if reason == "user_quit"
  ));
  assert_eq!(effects.len(), 2); // Persist + Emit
}

#[test]
fn undo_started_transitions_to_working() {
  let state = test_state();

  let (new_state, effects) = transition(
    state,
    Input::UndoStarted {
      message: Some("reverting".to_string()),
    },
    NOW,
  );

  assert_eq!(new_state.phase, WorkPhase::Working);
  // Persist + SessionDelta + UndoStarted
  assert_eq!(effects.len(), 3);
}

#[test]
fn undo_completed_transitions_to_idle() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(
    state,
    Input::UndoCompleted {
      success: true,
      message: None,
    },
    NOW,
  );

  assert_eq!(new_state.phase, WorkPhase::Idle);
  // Persist + SessionDelta + UndoCompleted
  assert_eq!(effects.len(), 3);
}

#[test]
fn context_compacted_appends_message_and_emits_event() {
  let mut state = test_state();
  state.token_usage = TokenUsage {
    input_tokens: 120_000,
    output_tokens: 9_500,
    cached_tokens: 2_400,
    context_window: 200_000,
  };

  let (new_state, effects) = transition(state.clone(), Input::ContextCompacted, NOW);
  assert_eq!(new_state.phase, state.phase);
  // Compaction preserves accumulated lifetime totals (input/output/cached).
  // Only context_* columns in the DB are zeroed — the transition layer keeps
  // accumulated values so they survive server restarts.
  assert_eq!(new_state.token_usage.input_tokens, 120_000);
  assert_eq!(new_state.token_usage.cached_tokens, 2_400);
  assert_eq!(new_state.token_usage.output_tokens, 9_500);
  assert_eq!(new_state.token_usage.context_window, 200_000);
  assert_eq!(effects.len(), 5);
  assert!(matches!(effects[0], Effect::Persist(_)));
  assert!(matches!(effects[1], Effect::Emit(_)));
  assert!(matches!(effects[2], Effect::Persist(_)));
  assert!(matches!(effects[3], Effect::Emit(_)));
  assert!(matches!(effects[4], Effect::Emit(_)));
  if let Effect::Emit(message) = &effects[1] {
    match message.as_ref() {
      ServerMessage::TokensUpdated { usage, .. } => {
        assert_eq!(usage.input_tokens, 120_000);
        assert_eq!(usage.cached_tokens, 2_400);
        assert_eq!(usage.output_tokens, 9_500);
        assert_eq!(usage.context_window, 200_000);
      }
      other => panic!("expected tokens_updated effect, got {:?}", other),
    }
  }
  let last_row = new_state.rows.last().expect("expected compaction row");
  if let ConversationRow::System(ref msg) = last_row.row {
    assert_eq!(
      msg.content,
      "Context compacted to keep this session within the model context window."
    );
  } else {
    panic!("expected System row for compaction");
  }
}

#[test]
fn pass_through_events_only_emit() {
  let state = test_state();

  let (_, effects) = transition(state, Input::SkillsUpdateAvailable, NOW);
  assert_eq!(effects.len(), 1);
  assert!(matches!(effects[0], Effect::Emit(_)));
}

#[test]
fn error_keeps_working_phase_intact() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(state, Input::Error("something broke".to_string()), NOW);

  assert_eq!(new_state.phase, WorkPhase::Working);
  // Error rows are informational; a separate terminal event owns work-status changes.
  assert_eq!(effects.len(), 2);
  // Verify the error row was added to state
  let last_row = new_state.rows.last().unwrap();
  if let ConversationRow::System(ref msg) = last_row.row {
    assert!(msg.id.starts_with("error-"));
    assert_eq!(msg.content, "something broke");
  } else {
    panic!("expected System row for error");
  }
}

#[test]
fn error_then_turn_aborted_transitions_to_idle() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (state_after_error, _) = transition(state, Input::Error("something broke".to_string()), NOW);
  let (new_state, effects) = transition(
    state_after_error,
    Input::TurnAborted {
      reason: "something broke".to_string(),
    },
    NOW,
  );

  assert_eq!(new_state.phase, WorkPhase::Idle);
  assert!(effects.iter().any(|effect| {
    matches!(
      effect,
      Effect::Persist(op)
        if matches!(
          op.as_ref(),
          PersistOp::SessionUpdate {
            work_status: Some(WorkStatus::Waiting),
            ..
          }
        )
    )
  }));
}

#[test]
fn tokens_updated_stores_usage() {
  let state = test_state();
  let usage = TokenUsage {
    input_tokens: 100,
    output_tokens: 50,
    cached_tokens: 20,
    context_window: 128000,
  };

  let (new_state, effects) = transition(
    state,
    Input::TokensUpdated {
      usage: usage.clone(),
      snapshot_kind: TokenUsageSnapshotKind::Unknown,
    },
    NOW,
  );

  assert_eq!(new_state.token_usage.input_tokens, 100);
  assert_eq!(new_state.token_usage.output_tokens, 50);
  assert_eq!(
    new_state.token_usage_snapshot_kind,
    TokenUsageSnapshotKind::Unknown
  );
  assert_eq!(effects.len(), 2); // Persist + Emit
}

#[test]
fn tokens_updated_persists_snapshot_kind() {
  let state = test_state();
  let usage = TokenUsage {
    input_tokens: 42,
    output_tokens: 17,
    cached_tokens: 5,
    context_window: 200_000,
  };

  let (_, effects) = transition(
    state,
    Input::TokensUpdated {
      usage,
      snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
    },
    NOW,
  );

  assert!(matches!(
      effects.first(),
      Some(Effect::Persist(op))
          if matches!(
              op.as_ref(),
              PersistOp::TokensUpdate {
                  snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                  ..
              }
          )
  ));
}

#[test]
fn turn_usage_updated_sets_accounting_snapshot_without_live_effects() {
  let state = test_state();
  let usage = TokenUsage {
    input_tokens: 1_000,
    output_tokens: 200,
    cached_tokens: 300,
    context_window: 200_000,
  };

  let (new_state, effects) = transition(
    state,
    Input::TurnUsageUpdated {
      usage,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    },
    NOW,
  );

  assert!(effects.is_empty());
  assert_eq!(
    new_state
      .turn_usage_snapshot
      .as_ref()
      .map(|u| u.input_tokens),
    Some(1_000)
  );
  assert_eq!(
    new_state.turn_usage_snapshot_kind,
    Some(TokenUsageSnapshotKind::LifetimeTotals)
  );
  assert_eq!(new_state.token_usage.input_tokens, 0);
}

#[test]
fn turn_completed_prefers_provider_accounting_snapshot() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state.current_turn_id = Some("turn-1".to_string());
  state.turn_count = 1;
  state.token_usage = TokenUsage {
    input_tokens: 200,
    output_tokens: 10,
    cached_tokens: 20,
    context_window: 200_000,
  };
  state.turn_usage_snapshot = Some(TokenUsage {
    input_tokens: 1_000,
    output_tokens: 200,
    cached_tokens: 300,
    context_window: 200_000,
  });
  state.turn_usage_snapshot_kind = Some(TokenUsageSnapshotKind::LifetimeTotals);

  let (_, effects) = transition(state, Input::TurnCompleted, NOW);
  let persisted = effects.iter().find_map(|effect| match effect {
    Effect::Persist(op) => match op.as_ref() {
      PersistOp::TurnDiffInsert {
        input_tokens,
        output_tokens,
        cached_tokens,
        snapshot_kind,
        ..
      } => Some((
        *input_tokens,
        *output_tokens,
        *cached_tokens,
        *snapshot_kind,
      )),
      _ => None,
    },
    _ => None,
  });

  assert_eq!(
    persisted,
    Some((1_000, 200, 300, TokenUsageSnapshotKind::LifetimeTotals))
  );
}

#[test]
fn thread_rolled_back_transitions_to_idle() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;

  let (new_state, effects) = transition(state, Input::ThreadRolledBack { num_turns: 3 }, NOW);

  assert_eq!(new_state.phase, WorkPhase::Idle);
  // Persist + SessionDelta + ThreadRolledBack
  assert_eq!(effects.len(), 3);
}

#[test]
fn turn_started_generates_turn_id() {
  let state = test_state();
  assert_eq!(state.turn_count, 0);
  assert!(state.current_turn_id.is_none());

  let (new_state, effects) = transition(state, Input::TurnStarted, NOW);

  assert_eq!(new_state.turn_count, 1);
  assert_eq!(new_state.current_turn_id, Some("turn-1".to_string()));

  // Verify turn_id and turn_count are in the delta
  if let Effect::Emit(ref msg) = effects[1] {
    if let ServerMessage::SessionDelta { changes, .. } = msg.as_ref() {
      assert_eq!(changes.current_turn_id, Some(Some("turn-1".to_string())));
      assert_eq!(changes.turn_count, Some(1));
    } else {
      panic!("expected SessionDelta");
    }
  }
}

#[test]
fn turn_count_increments_across_turns() {
  let state = test_state();

  // First turn
  let (state1, _) = transition(state, Input::TurnStarted, NOW);
  assert_eq!(state1.turn_count, 1);
  assert_eq!(state1.current_turn_id, Some("turn-1".to_string()));

  let (state2, _) = transition(state1, Input::TurnCompleted, NOW);
  assert!(state2.current_turn_id.is_none());

  // Second turn
  let (state3, _) = transition(state2, Input::TurnStarted, NOW);
  assert_eq!(state3.turn_count, 2);
  assert_eq!(state3.current_turn_id, Some("turn-2".to_string()));
}

#[test]
fn turn_completed_snapshots_diff() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state.current_turn_id = Some("turn-1".to_string());
  state.turn_count = 1;
  state.current_diff = Some("--- a/file.rs\n+++ b/file.rs\n@@ -1 +1 @@\n-old\n+new".to_string());

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  // Diff should be snapshotted into turn_diffs
  assert_eq!(new_state.turn_diffs.len(), 1);
  assert_eq!(new_state.turn_diffs[0].turn_id, "turn-1");
  assert!(new_state.turn_diffs[0].diff.contains("+new"));

  // Turn ID and current_diff should be cleared
  assert!(new_state.current_turn_id.is_none());
  assert!(
    new_state.current_diff.is_none(),
    "current_diff should be cleared after archiving into turn_diffs"
  );

  // Should emit TurnDiffSnapshot
  let has_snapshot = effects.iter().any(|e| {
    matches!(
        e,
        Effect::Emit(ref msg) if matches!(msg.as_ref(), ServerMessage::TurnDiffSnapshot { .. })
    )
  });
  assert!(has_snapshot, "should emit TurnDiffSnapshot");

  // SessionDelta should clear current_diff
  let clears_diff = effects.iter().any(|e| match e {
    Effect::Emit(msg) => match msg.as_ref() {
      ServerMessage::SessionDelta { changes, .. } => changes.current_diff == Some(None),
      _ => false,
    },
    _ => false,
  });
  assert!(clears_diff, "SessionDelta should clear current_diff");
}

#[test]
fn turn_completed_without_diff_skips_snapshot() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state.current_turn_id = Some("turn-1".to_string());
  state.turn_count = 1;
  state.current_diff = None;

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  assert!(new_state.turn_diffs.is_empty());

  let has_snapshot = effects.iter().any(|e| {
    matches!(
        e,
        Effect::Emit(ref msg) if matches!(msg.as_ref(), ServerMessage::TurnDiffSnapshot { .. })
    )
  });
  assert!(
    !has_snapshot,
    "should NOT emit TurnDiffSnapshot without diff"
  );
}

#[test]
fn turn_aborted_clears_turn_id() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state.current_turn_id = Some("turn-1".to_string());

  let (new_state, _) = transition(
    state,
    Input::TurnAborted {
      reason: "interrupted".to_string(),
    },
    NOW,
  );

  assert!(new_state.current_turn_id.is_none());
}

// -- finalize_in_progress_rows tests --------------------------------------

#[test]
fn turn_completed_finalizes_in_progress_tool_rows() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state
    .rows
    .push(test_tool_row("tool-1", ToolStatus::Running));
  state
    .rows
    .push(test_tool_row("tool-2", ToolStatus::Completed));

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  // The running tool should now be Completed
  if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
    assert_eq!(
      t.status,
      ToolStatus::Completed,
      "tool-1 should be finalized"
    );
  } else {
    panic!("expected Tool row");
  }
  // The already-completed one stays Completed
  if let ConversationRow::Tool(ref t) = new_state.rows[1].row {
    assert_eq!(
      t.status,
      ToolStatus::Completed,
      "tool-2 should stay completed"
    );
  } else {
    panic!("expected Tool row");
  }

  // Should have finalize effects: RowUpsert for tool-1 + ConversationRowsChanged
  let finalize_persists: Vec<_> = effects
    .iter()
    .filter(|e| {
      matches!(e, Effect::Persist(op) if matches!(
          op.as_ref(),
          PersistOp::RowUpsert { ref entry, .. }
              if entry.id() == "tool-1"
      ))
    })
    .collect();
  assert_eq!(finalize_persists.len(), 1);

  let finalize_emits: Vec<_> = effects
    .iter()
    .filter(|e| {
      matches!(e, Effect::Emit(msg) if matches!(
          msg.as_ref(),
          ServerMessage::ConversationRowsChanged { ref upserted, .. }
              if upserted.iter().any(|u| u.id() == "tool-1")
      ))
    })
    .collect();
  assert_eq!(finalize_emits.len(), 1);
}

#[test]
fn turn_aborted_finalizes_in_progress_tool_rows() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state
    .rows
    .push(test_tool_row("tool-1", ToolStatus::Running));

  let (new_state, effects) = transition(
    state,
    Input::TurnAborted {
      reason: "interrupted".to_string(),
    },
    NOW,
  );

  if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
    assert_eq!(
      t.status,
      ToolStatus::Completed,
      "tool-1 should be finalized"
    );
  } else {
    panic!("expected Tool row");
  }

  let has_finalize = effects.iter().any(|e| {
    matches!(
        e, Effect::Persist(op) if matches!(
            op.as_ref(),
            PersistOp::RowUpsert { ref entry, .. }
                if entry.id() == "tool-1"
        )
    )
  });
  assert!(
    has_finalize,
    "TurnAborted should finalize in-progress tools"
  );
}

#[test]
fn session_ended_finalizes_in_progress_tool_rows() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state
    .rows
    .push(test_tool_row("tool-1", ToolStatus::Running));

  let (new_state, effects) = transition(
    state,
    Input::SessionEnded {
      reason: "done".to_string(),
    },
    NOW,
  );

  if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
    assert_eq!(
      t.status,
      ToolStatus::Completed,
      "tool-1 should be finalized"
    );
  } else {
    panic!("expected Tool row");
  }

  let has_finalize = effects.iter().any(|e| {
    matches!(
        e, Effect::Persist(op) if matches!(
            op.as_ref(),
            PersistOp::RowUpsert { ref entry, .. }
                if entry.id() == "tool-1"
        )
    )
  });
  assert!(
    has_finalize,
    "SessionEnded should finalize in-progress tools"
  );
}

#[test]
fn no_cleanup_effects_when_no_in_progress_rows() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state
    .rows
    .push(test_tool_row("tool-1", ToolStatus::Completed));
  state
    .rows
    .push(test_tool_row("tool-2", ToolStatus::Completed));

  let (_, effects) = transition(state, Input::TurnCompleted, NOW);

  // Only session status effects (Persist + Emit), no RowUpsert effects for finalization
  let row_upserts: Vec<_> = effects
    .iter()
    .filter(
      |e| matches!(e, Effect::Persist(op) if matches!(op.as_ref(), PersistOp::RowUpsert { .. })),
    )
    .collect();
  assert!(
    row_upserts.is_empty(),
    "no RowUpsert effects when nothing to finalize"
  );
}

#[test]
fn shell_segments_heredoc_single_quote_kept_as_one_segment() {
  let cmd = "cat <<'EOF' > /tmp/plan.md\n# Plan\n\nStep 1\nStep 2\nEOF";
  let segments = shell_segments_for_preview(cmd);
  assert_eq!(
    segments.len(),
    1,
    "heredoc should be a single segment, got: {segments:?}"
  );
  assert!(segments[0].command.contains("# Plan"));
  assert!(segments[0].command.contains("EOF"));
}

#[test]
fn shell_segments_heredoc_double_quote_kept_as_one_segment() {
  let cmd = "cat <<\"END\" > /tmp/out.txt\nline 1\nline 2\nEND";
  let segments = shell_segments_for_preview(cmd);
  assert_eq!(
    segments.len(),
    1,
    "heredoc should be a single segment, got: {segments:?}"
  );
}

#[test]
fn shell_segments_heredoc_unquoted_kept_as_one_segment() {
  let cmd = "cat <<MARKER\nfoo\nbar\nMARKER";
  let segments = shell_segments_for_preview(cmd);
  assert_eq!(
    segments.len(),
    1,
    "heredoc should be a single segment, got: {segments:?}"
  );
}

#[test]
fn shell_segments_heredoc_with_dash_strip_tabs() {
  let cmd = "cat <<-EOF\n\tfoo\n\tbar\nEOF";
  let segments = shell_segments_for_preview(cmd);
  assert_eq!(
    segments.len(),
    1,
    "<<- heredoc should be a single segment, got: {segments:?}"
  );
}

#[test]
fn shell_segments_heredoc_then_next_command() {
  let cmd =
    "cat <<'EOF' > /tmp/file.md\ncontent\nEOF\ncd /tmp && gh issue create --body-file file.md";
  let segments = shell_segments_for_preview(cmd);
  assert_eq!(
    segments.len(),
    3,
    "expected heredoc + cd + gh, got: {segments:?}"
  );
  assert!(segments[0].command.starts_with("cat <<"));
  assert_eq!(segments[1].command, "cd /tmp");
  assert_eq!(segments[2].leading_operator.as_deref(), Some("&&"));
}

#[test]
fn multiple_in_progress_rows_all_finalized() {
  let mut state = test_state();
  state.phase = WorkPhase::Working;
  state
    .rows
    .push(test_tool_row("tool-1", ToolStatus::Running));
  state
    .rows
    .push(test_tool_row("tool-2", ToolStatus::Running));
  state
    .rows
    .push(test_tool_row("tool-3", ToolStatus::Running));

  let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

  // All three should be finalized
  for entry in &new_state.rows {
    if let ConversationRow::Tool(ref t) = entry.row {
      assert_eq!(
        t.status,
        ToolStatus::Completed,
        "tool {} should be finalized",
        t.id
      );
    } else {
      panic!("expected Tool row");
    }
  }

  // Should have 3 RowUpsert persist effects + 1 ConversationRowsChanged emit
  let row_upserts: Vec<_> = effects
    .iter()
    .filter(
      |e| matches!(e, Effect::Persist(op) if matches!(op.as_ref(), PersistOp::RowUpsert { .. })),
    )
    .collect();
  assert_eq!(row_upserts.len(), 3);

  // finalize_in_progress_rows emits a single ConversationRowsChanged with all upserted
  let row_changed_emits: Vec<_> = effects
            .iter()
            .filter(|e| matches!(e, Effect::Emit(msg) if matches!(msg.as_ref(), ServerMessage::ConversationRowsChanged { .. })))
            .collect();
  assert_eq!(row_changed_emits.len(), 1);
}
