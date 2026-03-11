use crate::workers::iso_now;
use codex_protocol::approvals::ElicitationRequestEvent;
use codex_protocol::protocol::{
    ApplyPatchApprovalRequestEvent, ExecApprovalRequestEvent, FileChange, RequestUserInputEvent,
};
use codex_protocol::request_permissions::RequestPermissionsEvent;
use orbitdock_connector_core::{ApprovalType, ConnectorEvent};
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) fn handle_exec_approval_request(event: ExecApprovalRequestEvent) -> Vec<ConnectorEvent> {
    let command = event.command.join(" ");
    let amendment = event
        .proposed_execpolicy_amendment
        .map(|amendment| amendment.command().to_vec());
    let request_id = event
        .approval_id
        .clone()
        .unwrap_or_else(|| event.call_id.clone());
    vec![ConnectorEvent::ApprovalRequested {
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
        permission_suggestions: None,
    }]
}

pub(crate) fn handle_apply_patch_approval_request(
    event: ApplyPatchApprovalRequestEvent,
) -> Vec<ConnectorEvent> {
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

    vec![ConnectorEvent::ApprovalRequested {
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
    }]
}

pub(crate) fn handle_request_user_input(
    event_id: &str,
    event: RequestUserInputEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let question_text = event.questions.first().map(|question| question.question.clone());
    let tool_input = serde_json::to_string(&json!({
        "questions": event.questions,
    }))
    .ok();
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let message = orbitdock_protocol::Message {
        id: format!("ask-user-question-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: question_text
            .clone()
            .unwrap_or_else(|| "Question requested".to_string()),
        tool_name: Some("askuserquestion".to_string()),
        tool_input: tool_input.clone(),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![
        ConnectorEvent::MessageCreated(message),
        ConnectorEvent::ApprovalRequested {
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
        },
    ]
}

pub(crate) fn handle_request_permissions(event: RequestPermissionsEvent) -> Vec<ConnectorEvent> {
    let tool_input = serde_json::to_string(&json!({
        "reason": event.reason,
        "permissions": event.permissions,
    }))
    .ok();
    let requested_permissions = serde_json::to_value(&event.permissions).ok();
    vec![ConnectorEvent::ApprovalRequested {
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
    }]
}

pub(crate) fn handle_elicitation_request(
    event_id: &str,
    event: ElicitationRequestEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let question_text = if event.request.message().is_empty() {
        Some(format!("{} request", event.server_name))
    } else {
        Some(event.request.message().to_string())
    };
    let tool_input = serde_json::to_string(&event).ok();
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let message = orbitdock_protocol::Message {
        id: format!("mcp-approval-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: question_text
            .clone()
            .unwrap_or_else(|| "MCP approval requested".to_string()),
        tool_name: Some("mcp_approval".to_string()),
        tool_input: tool_input.clone(),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![
        ConnectorEvent::MessageCreated(message),
        ConnectorEvent::ApprovalRequested {
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
        },
    ]
}
