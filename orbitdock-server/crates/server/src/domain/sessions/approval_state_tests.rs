use super::*;
use orbitdock_protocol::{ApprovalPreviewType, ApprovalRiskLevel};
use serde_json::json;

struct ApprovalRequestFixture<'a> {
  id: &'a str,
  approval_type: ApprovalType,
  tool_name: Option<&'a str>,
  tool_input: Option<&'a str>,
  command: Option<&'a str>,
  file_path: Option<&'a str>,
  question: Option<&'a str>,
  preview: Option<ApprovalPreview>,
}

fn base_fixture<'a>(approval_type: ApprovalType) -> ApprovalRequestFixture<'a> {
  ApprovalRequestFixture {
    id: "a",
    approval_type,
    tool_name: None,
    tool_input: None,
    command: None,
    file_path: None,
    question: None,
    preview: None,
  }
}

fn approval_request(fixture: ApprovalRequestFixture<'_>) -> ApprovalRequest {
  ApprovalRequest {
    id: fixture.id.to_string(),
    session_id: "session-1".to_string(),
    approval_type: fixture.approval_type,
    tool_name: fixture.tool_name.map(ToString::to_string),
    tool_input: fixture.tool_input.map(ToString::to_string),
    command: fixture.command.map(ToString::to_string),
    file_path: fixture.file_path.map(ToString::to_string),
    diff: None,
    question: fixture.question.map(ToString::to_string),
    question_prompts: vec![],
    preview: fixture.preview,
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
  }
}

#[test]
fn fallback_tool_shape_matches_approval_type() {
  let exec = approval_request(ApprovalRequestFixture {
    ..base_fixture(ApprovalType::Exec)
  });
  let patch = approval_request(ApprovalRequestFixture {
    ..base_fixture(ApprovalType::Patch)
  });
  let question = approval_request(ApprovalRequestFixture {
    ..base_fixture(ApprovalType::Question)
  });

  assert_eq!(fallback_tool_name(&exec), Some("Bash".to_string()));
  assert_eq!(fallback_tool_name(&patch), Some("Edit".to_string()));
  assert_eq!(fallback_tool_name(&question), None);

  let with_command = approval_request(ApprovalRequestFixture {
    tool_name: None,
    tool_input: None,
    command: Some("ls"),
    file_path: Some("/tmp"),
    ..base_fixture(ApprovalType::Exec)
  });
  assert_eq!(
    fallback_tool_input(&with_command),
    Some("{\"command\":\"ls\",\"file_path\":\"/tmp\"}".to_string())
  );
}

#[test]
fn fallback_tool_input_uses_preview_value_when_needed() {
  let approval = approval_request(ApprovalRequestFixture {
    preview: Some(ApprovalPreview {
      preview_type: ApprovalPreviewType::Url,
      value: "https://example.com".to_string(),
      shell_segments: vec![],
      compact: None,
      decision_scope: None,
      risk_level: ApprovalRiskLevel::Normal,
      risk_findings: vec![],
      manifest: None,
    }),
    ..base_fixture(ApprovalType::Exec)
  });

  assert_eq!(
    fallback_tool_input(&approval),
    Some("{\"url\":\"https://example.com\"}".to_string())
  );
}

#[test]
fn parse_question_prompt_and_fallback_question_are_consistent() {
  let payload = json!({
    "questions": [
      {
        "id": "0",
        "header": "Header",
        "question": "Continue?",
        "options": [
          {"label": "Yes", "description": "keep going"}
        ],
        "multiSelect": true,
        "isOther": false,
        "isSecret": true
      }
    ]
  });

  let prompts = extract_question_prompts(Some(&payload.to_string()), Some("Fallback question"));

  assert_eq!(prompts.len(), 1);
  assert_eq!(prompts[0].question, "Continue?");
  assert!(prompts[0].allows_multiple_selection);
  assert!(prompts[0].is_secret);
  assert_eq!(prompts[0].options[0].label, "Yes");

  let fallback = extract_question_prompts(None, Some("Fallback question"));
  assert_eq!(fallback.len(), 1);
  assert_eq!(fallback[0].question, "Fallback question");
}

#[test]
fn queue_resolve_and_bootstrap_follow_queue_semantics() {
  let base = ApprovalQueueState::new(WorkStatus::Waiting);
  let request = approval_request(ApprovalRequestFixture {
    id: " approval-1 ",
    tool_name: Some("AskUserQuestion"),
    tool_input: Some("{\"question\":\"Ship it?\"}"),
    question: Some("Ship it?"),
    ..base_fixture(ApprovalType::Question)
  });

  let (state, mutation) =
    base
      .clone()
      .queue_pending_approval(request.clone(), ApprovalType::Question, None);
  assert_eq!(mutation, PendingApprovalMutation::Enqueued);
  assert_eq!(state.approval_version, 1);

  let (state, mutation) =
    state
      .clone()
      .queue_pending_approval(request.clone(), ApprovalType::Question, None);
  assert_eq!(mutation, PendingApprovalMutation::Unchanged);
  assert_eq!(state.approval_version, 1);

  let updated = approval_request(ApprovalRequestFixture {
    id: "approval-1",
    tool_name: Some("AskUserQuestion"),
    tool_input: Some("{\"question\":\"Ship now?\"}"),
    question: Some("Ship now?"),
    ..base_fixture(ApprovalType::Question)
  });
  let (state, mutation) =
    state.queue_pending_approval(updated.clone(), ApprovalType::Question, None);
  assert_eq!(mutation, PendingApprovalMutation::Updated);
  assert_eq!(state.approval_version, 2);

  let state = state.promote_queue_front();
  assert_eq!(state.pending_approval_id.as_deref(), Some("approval-1"));
  assert_eq!(state.work_status, WorkStatus::Question);

  let (state, resolution) = state.resolve_pending_approval("approval-1", WorkStatus::Waiting);
  assert_eq!(resolution.approval_type, Some(ApprovalType::Question));
  assert_eq!(resolution.work_status, WorkStatus::Waiting);
  assert!(resolution.active_approval.is_none());
  assert!(state.pending_approvals.is_empty());
  assert_eq!(state.work_status, WorkStatus::Waiting);
}

#[test]
fn pending_tool_family_prefers_question_and_known_tool_mappings() {
  let request = approval_request(base_fixture(ApprovalType::Question));
  assert_eq!(
    pending_tool_family_from_state(Some(&request), Some("Bash"), None),
    Some(ToolFamily::Question)
  );
  assert_eq!(
    pending_tool_family_from_state(None, Some("Write"), None),
    Some(ToolFamily::FileChange)
  );
  assert_eq!(
    pending_tool_family_from_state(None, Some("mcp__example"), None),
    Some(ToolFamily::Mcp)
  );
}
