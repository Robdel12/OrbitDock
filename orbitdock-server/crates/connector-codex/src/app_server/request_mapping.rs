use codex_app_server_protocol::{McpServerElicitationRequest, ServerRequest};
use orbitdock_connector_core::{
  ApprovalType, ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent,
};
use serde_json::json;
use tracing::warn;

use super::response_codec::request_key;
use super::AppServerSessionRoute;

pub(super) async fn map_server_request(
  request: ServerRequest,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  let request_id = request.id().clone();
  let key = request_key(&request_id);
  route
    .pending_requests
    .lock()
    .await
    .insert(key.clone(), request_id);

  match request {
    ServerRequest::CommandExecutionRequestApproval { params, .. } => {
      vec![ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Exec,
        tool_name: None,
        tool_input: None,
        command: params.command,
        file_path: params.cwd.map(|path| path.display().to_string()),
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
        requested_permissions: None,
        proposed_amendment: params
          .proposed_execpolicy_amendment
          .map(|amendment| amendment.command),
        permission_suggestions: serde_json::to_value(json!({
          "source": "codex_app_server_command_approval",
          "available_decisions": params.available_decisions,
          "additional_permissions": params.additional_permissions,
          "proposed_network_policy_amendments": params.proposed_network_policy_amendments,
        }))
        .ok(),
        elicitation_mode: None,
        elicitation_schema: None,
        elicitation_url: None,
        elicitation_message: None,
        mcp_server_name: None,
        network_host: params
          .network_approval_context
          .as_ref()
          .map(|context| context.host.clone()),
        network_protocol: params
          .network_approval_context
          .map(|context| format!("{:?}", context.protocol).to_ascii_lowercase()),
      }
      .into()]
    }
    ServerRequest::FileChangeRequestApproval { params, .. } => {
      vec![ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Patch,
        tool_name: None,
        tool_input: None,
        command: None,
        file_path: params.grant_root.map(|path| path.display().to_string()),
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
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
      }
      .into()]
    }
    ServerRequest::ToolRequestUserInput { params, .. } => {
      let question_text = params
        .questions
        .first()
        .map(|question| question.question.clone());
      vec![ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Question,
        tool_name: Some("request_user_input".to_string()),
        tool_input: serde_json::to_string(&params.questions).ok(),
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
      }
      .into()]
    }
    ServerRequest::McpServerElicitationRequest { params, .. } => {
      let (mode, schema, url, message) = match &params.request {
        McpServerElicitationRequest::Form {
          message,
          requested_schema,
          ..
        } => (
          Some("form".to_string()),
          serde_json::to_value(requested_schema).ok(),
          None,
          Some(message.clone()),
        ),
        McpServerElicitationRequest::Url { message, url, .. } => (
          Some("url".to_string()),
          None,
          Some(url.clone()),
          Some(message.clone()),
        ),
      };
      vec![ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Question,
        tool_name: Some("mcp_approval".to_string()),
        tool_input: serde_json::to_string(&params.request).ok(),
        command: None,
        file_path: None,
        diff: None,
        question: message.clone(),
        permission_reason: None,
        requested_permissions: None,
        proposed_amendment: None,
        permission_suggestions: None,
        elicitation_mode: mode,
        elicitation_schema: schema,
        elicitation_url: url,
        elicitation_message: message,
        mcp_server_name: Some(params.server_name),
        network_host: None,
        network_protocol: None,
      }
      .into()]
    }
    ServerRequest::PermissionsRequestApproval { params, .. } => {
      vec![ConnectorStateEvent::ApprovalRequested {
        request_id: key,
        approval_type: ApprovalType::Permissions,
        tool_name: Some("request_permissions".to_string()),
        tool_input: serde_json::to_string(&params.permissions).ok(),
        command: None,
        file_path: None,
        diff: None,
        question: params.reason.clone(),
        permission_reason: params.reason,
        requested_permissions: serde_json::to_value(&params.permissions).ok(),
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
      .into()]
    }
    ServerRequest::DynamicToolCall { params, .. } => {
      vec![ConnectorOutput::Runtime(
        ConnectorRuntimeDirective::DynamicToolCallRequested {
          call_id: key,
          tool_name: params.tool,
          arguments: params.arguments,
        },
      )]
    }
    other => {
      warn!(request = ?other, "Unhandled Codex app-server request");
      Vec::new()
    }
  }
}
