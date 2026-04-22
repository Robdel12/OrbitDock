use super::{row_created_output, state_output, tool_row_entry, ConnectorOutputs};
use crate::workers::iso_now;
use codex_protocol::approvals::{
  ElicitationRequestEvent, NetworkApprovalProtocol, NetworkPolicyAmendment,
};
use codex_protocol::protocol::{
  ApplyPatchApprovalRequestEvent, ExecApprovalRequestEvent, FileChange, RequestUserInputEvent,
};
use codex_protocol::request_permissions::RequestPermissionsEvent;
use orbitdock_connector_core::{ApprovalType, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::ToolRow;
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};

fn network_protocol_label(protocol: NetworkApprovalProtocol) -> &'static str {
  match protocol {
    NetworkApprovalProtocol::Http => "http",
    NetworkApprovalProtocol::Https => "https",
    NetworkApprovalProtocol::Socks5Tcp => "socks5_tcp",
    NetworkApprovalProtocol::Socks5Udp => "socks5_udp",
  }
}

fn approval_suggestions(
  amendments: Option<&[NetworkPolicyAmendment]>,
  available_decisions: Option<&[codex_protocol::protocol::ReviewDecision]>,
  additional_permissions: Option<&codex_protocol::models::PermissionProfile>,
) -> Option<serde_json::Value> {
  if amendments.is_none() && available_decisions.is_none() && additional_permissions.is_none() {
    return None;
  }

  Some(json!({
    "source": "codex_exec_approval_request",
    "proposed_network_policy_amendments": amendments,
    "available_decisions": available_decisions,
    "additional_permissions": additional_permissions,
  }))
}

pub(crate) fn handle_exec_approval_request(event: ExecApprovalRequestEvent) -> ConnectorOutputs {
  let command = event.command.join(" ");
  let amendment = event
    .proposed_execpolicy_amendment
    .map(|amendment| amendment.command().to_vec());
  let network_host = event
    .network_approval_context
    .as_ref()
    .map(|context| context.host.clone());
  let network_protocol = event
    .network_approval_context
    .as_ref()
    .map(|context| network_protocol_label(context.protocol).to_string());
  let permission_suggestions = approval_suggestions(
    event.proposed_network_policy_amendments.as_deref(),
    event.available_decisions.as_deref(),
    event.additional_permissions.as_ref(),
  );
  let request_id = event
    .approval_id
    .clone()
    .unwrap_or_else(|| event.call_id.clone());
  vec![state_output(ConnectorStateEvent::ApprovalRequested {
    request_id,
    approval_type: ApprovalType::Exec,
    tool_name: None,
    tool_input: None,
    command: Some(command),
    file_path: Some(event.cwd.display().to_string()),
    diff: None,
    question: None,
    permission_reason: None,
    requested_permissions: None,
    proposed_amendment: amendment,
    permission_suggestions,
    elicitation_mode: None,
    elicitation_schema: None,
    elicitation_url: None,
    elicitation_message: None,
    mcp_server_name: None,
    network_host,
    network_protocol,
  })]
}

pub(crate) fn handle_apply_patch_approval_request(
  event: ApplyPatchApprovalRequestEvent,
) -> ConnectorOutputs {
  let files: Vec<String> = event
    .changes
    .keys()
    .map(|path| path.display().to_string())
    .collect();
  let first_file = files.first().cloned();

  let diff = event
    .changes
    .iter()
    .map(|(path, change)| match change {
      FileChange::Add { content } => {
        format!(
          "--- /dev/null\n+++ {}\n{}",
          path.display(),
          content
            .lines()
            .map(|line| format!("+{}", line))
            .collect::<Vec<_>>()
            .join("\n")
        )
      }
      FileChange::Delete { content } => {
        format!(
          "--- {}\n+++ /dev/null\n{}",
          path.display(),
          content
            .lines()
            .map(|line| format!("-{}", line))
            .collect::<Vec<_>>()
            .join("\n")
        )
      }
      FileChange::Update { unified_diff, .. } => {
        format!(
          "--- {}\n+++ {}\n{}",
          path.display(),
          path.display(),
          unified_diff
        )
      }
    })
    .collect::<Vec<_>>()
    .join("\n\n");

  vec![state_output(ConnectorStateEvent::ApprovalRequested {
    request_id: event.call_id.clone(),
    approval_type: ApprovalType::Patch,
    tool_name: None,
    tool_input: None,
    command: None,
    file_path: first_file,
    diff: Some(diff),
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
  })]
}

pub(crate) fn handle_request_user_input(
  event_id: &str,
  event: RequestUserInputEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  let question_text = event
    .questions
    .first()
    .map(|question| question.question.clone());
  let tool_input = serde_json::to_string(&json!({
      "questions": event.questions,
  }))
  .ok();
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);

  let row = ToolRow {
    id: format!("ask-user-question-{}-{}", event_id, seq),
    provider: Provider::Codex,
    family: ToolFamily::Question,
    kind: ToolKind::AskUserQuestion,
    status: ToolStatus::Completed,
    title: question_text
      .clone()
      .unwrap_or_else(|| "Question requested".to_string()),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "prompt": question_text.clone(),
    }),
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };

  vec![
    row_created_output(tool_row_entry(row)),
    state_output(ConnectorStateEvent::ApprovalRequested {
      request_id: event_id.to_string(),
      approval_type: ApprovalType::Question,
      tool_name: None,
      tool_input,
      command: None,
      file_path: None,
      diff: None,
      question: question_text,
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
    }),
  ]
}

pub(crate) fn handle_request_permissions(event: RequestPermissionsEvent) -> ConnectorOutputs {
  let tool_input = serde_json::to_string(&json!({
      "reason": event.reason,
      "permissions": event.permissions,
  }))
  .ok();
  let requested_permissions = serde_json::to_value(&event.permissions).ok();
  vec![state_output(ConnectorStateEvent::ApprovalRequested {
    request_id: event.call_id,
    approval_type: ApprovalType::Permissions,
    tool_name: Some("request_permissions".to_string()),
    tool_input,
    command: None,
    file_path: None,
    diff: None,
    question: event.reason.clone(),
    permission_reason: event.reason,
    requested_permissions,
    proposed_amendment: None,
    permission_suggestions: None,
    elicitation_mode: None,
    elicitation_schema: None,
    elicitation_url: None,
    elicitation_message: None,
    mcp_server_name: None,
    network_host: None,
    network_protocol: None,
  })]
}

pub(crate) fn handle_elicitation_request(
  event_id: &str,
  event: ElicitationRequestEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  let request_message = event.request.message();
  let question_text = (!request_message.is_empty())
    .then(|| request_message.to_string())
    .or_else(|| Some(format!("{} request", event.server_name)));
  let tool_input = serde_json::to_string(&event).ok();
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);

  let row = ToolRow {
    id: format!("mcp-approval-{}-{}", event_id, seq),
    provider: Provider::Codex,
    family: ToolFamily::Mcp,
    kind: ToolKind::McpToolCall,
    status: ToolStatus::Completed,
    title: question_text
      .clone()
      .unwrap_or_else(|| "MCP approval requested".to_string()),
    subtitle: Some(event.server_name.clone()),
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "tool_name": "mcp_approval",
        "raw_input": serde_json::to_value(&event).ok(),
    }),
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };

  let elicitation_message = (!request_message.is_empty()).then(|| request_message.to_string());

  vec![
    row_created_output(tool_row_entry(row)),
    state_output(ConnectorStateEvent::ApprovalRequested {
      request_id: format!(
        "elicitation-{}-{}",
        event.server_name,
        serde_json::to_string(&event.id).unwrap_or_else(|_| "request".to_string())
      ),
      approval_type: ApprovalType::Question,
      tool_name: Some("mcp_approval".to_string()),
      tool_input,
      command: None,
      file_path: None,
      diff: None,
      question: question_text,
      permission_reason: None,
      requested_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      // Codex elicitation: populate structured fields from event
      elicitation_mode: Some("form".to_string()),
      elicitation_schema: None, // codex-protocol doesn't expose requested_schema yet
      elicitation_url: None,
      elicitation_message,
      mcp_server_name: Some(event.server_name),
      network_host: None,
      network_protocol: None,
    }),
  ]
}
