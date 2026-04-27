use std::collections::HashMap;

use codex_app_server_protocol::{
  CommandExecutionApprovalDecision, CommandExecutionRequestApprovalResponse,
  DynamicToolCallResponse, FileChangeApprovalDecision, FileChangeRequestApprovalResponse,
  PermissionsRequestApprovalResponse, RequestId, ToolRequestUserInputAnswer,
  ToolRequestUserInputResponse,
};
use orbitdock_connector_core::ConnectorError;

pub(crate) fn request_key(request_id: &RequestId) -> String {
  match request_id {
    RequestId::Integer(value) => value.to_string(),
    RequestId::String(value) => value.clone(),
  }
}

pub(crate) fn exec_approval_response(
  decision: crate::session::CodexExecApproval,
) -> CommandExecutionRequestApprovalResponse {
  CommandExecutionRequestApprovalResponse {
    decision: match decision {
      crate::session::CodexExecApproval::Approved => CommandExecutionApprovalDecision::Accept,
      crate::session::CodexExecApproval::ApprovedForSession => {
        CommandExecutionApprovalDecision::AcceptForSession
      }
      crate::session::CodexExecApproval::ApprovedAlways { proposed_amendment } => {
        proposed_amendment
          .map(
            |command| CommandExecutionApprovalDecision::AcceptWithExecpolicyAmendment {
              execpolicy_amendment: codex_app_server_protocol::ExecPolicyAmendment { command },
            },
          )
          .unwrap_or(CommandExecutionApprovalDecision::AcceptForSession)
      }
      crate::session::CodexExecApproval::NetworkPolicyAmendment {
        network_policy_amendment,
      } => CommandExecutionApprovalDecision::ApplyNetworkPolicyAmendment {
        network_policy_amendment: network_policy_amendment.into(),
      },
      crate::session::CodexExecApproval::Abort => CommandExecutionApprovalDecision::Cancel,
      crate::session::CodexExecApproval::Denied => CommandExecutionApprovalDecision::Decline,
    },
  }
}

pub(crate) fn patch_approval_response(
  decision: crate::session::CodexPatchApproval,
) -> FileChangeRequestApprovalResponse {
  FileChangeRequestApprovalResponse {
    decision: match decision {
      crate::session::CodexPatchApproval::Approved => FileChangeApprovalDecision::Accept,
      crate::session::CodexPatchApproval::ApprovedForSession => {
        FileChangeApprovalDecision::AcceptForSession
      }
      crate::session::CodexPatchApproval::Abort => FileChangeApprovalDecision::Cancel,
      crate::session::CodexPatchApproval::Denied => FileChangeApprovalDecision::Decline,
    },
  }
}

pub(crate) fn question_response(
  answers: HashMap<String, Vec<String>>,
) -> ToolRequestUserInputResponse {
  ToolRequestUserInputResponse {
    answers: answers
      .into_iter()
      .map(|(key, answers)| (key, ToolRequestUserInputAnswer { answers }))
      .collect(),
  }
}

pub(crate) fn permissions_response(
  permissions: serde_json::Value,
  scope: orbitdock_protocol::PermissionGrantScope,
) -> Result<PermissionsRequestApprovalResponse, ConnectorError> {
  let permissions = serde_json::from_value(permissions).map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to decode granted permissions payload: {error}"
    ))
  })?;
  Ok(PermissionsRequestApprovalResponse {
    permissions,
    scope: match scope {
      orbitdock_protocol::PermissionGrantScope::Turn => {
        codex_app_server_protocol::PermissionGrantScope::Turn
      }
      orbitdock_protocol::PermissionGrantScope::Session => {
        codex_app_server_protocol::PermissionGrantScope::Session
      }
    },
    strict_auto_review: None,
  })
}

pub(crate) fn dynamic_tool_response(
  response: codex_protocol::dynamic_tools::DynamicToolResponse,
) -> Result<DynamicToolCallResponse, ConnectorError> {
  serde_json::from_value(serde_json::to_value(response).map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to encode dynamic tool response: {error}"))
  })?)
  .map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to convert dynamic tool response for app-server: {error}"
    ))
  })
}
