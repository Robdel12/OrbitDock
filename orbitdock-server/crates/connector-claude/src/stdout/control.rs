use std::collections::HashMap;
use std::sync::Arc;

use serde_json::Value;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::warn;

use orbitdock_connector_core::{ApprovalType, ConnectorOutput, ConnectorStateEvent};

use crate::connector::is_accept_edits_tool;
use crate::protocol::{ControlResponsePayload, StdinMessage};

use super::helpers::{string_field, value_field};
use super::state_output;

pub(crate) struct PendingApproval {
  pub(crate) tool_name: Option<String>,
  pub(crate) input: Value,
  pub(crate) tool_use_id: Option<String>,
  pub(crate) permission_suggestions: Option<Value>,
}

pub(crate) async fn handle_cli_control_request(
  raw: &Value,
  pending_approvals: &Arc<Mutex<HashMap<String, PendingApproval>>>,
  stdin_tx: &mpsc::Sender<String>,
) -> Vec<ConnectorOutput> {
  let Some(request) = value_field(raw, "request", "request") else {
    return vec![];
  };

  let subtype = string_field(request, "subtype", "subtype")
    .or_else(|| string_field(request, "sub_type", "subType"))
    .unwrap_or_default();
  let request_id = string_field(raw, "request_id", "requestId").unwrap_or_default();

  match subtype.as_str() {
    "hook_callback" => {
      let response = StdinMessage::ControlResponse {
        response: ControlResponsePayload::Success {
          request_id,
          response: serde_json::json!({ "hookResults": [] }),
        },
      };
      if let Ok(json) = serde_json::to_string(&response) {
        let _ = stdin_tx.send(json).await;
      }
      return vec![];
    }
    "mcp_message" => {
      let server_name = string_field(request, "server_name", "serverName").unwrap_or_default();
      let response = StdinMessage::ControlResponse {
        response: ControlResponsePayload::Error {
          request_id,
          error: format!("MCP server '{}' is not hosted by OrbitDock", server_name),
        },
      };
      if let Ok(json) = serde_json::to_string(&response) {
        let _ = stdin_tx.send(json).await;
      }
      return vec![];
    }
    "can_use_tool" => {}
    _ => return vec![],
  }

  let tool_name = string_field(request, "tool_name", "toolName");
  let input = value_field(request, "input", "input").cloned();
  let tool_use_id = string_field(request, "tool_use_id", "toolUseID")
    .or_else(|| string_field(request, "toolUseId", "toolUseId"));
  let permission_suggestions =
    value_field(request, "permission_suggestions", "permissionSuggestions")
      .cloned()
      .or_else(|| value_field(raw, "permission_suggestions", "permissionSuggestions").cloned());

  if request_id.is_empty() {
    warn!(
      component = "claude_connector",
      event = "claude.control_request.missing_request_id",
      tool_name = ?tool_name,
      tool_use_id = ?tool_use_id,
      "Claude can_use_tool request missing request_id; cannot correlate approval response"
    );
    return vec![];
  }

  let suggestions_for_event = permission_suggestions.clone();
  pending_approvals.lock().await.insert(
    request_id.clone(),
    PendingApproval {
      tool_name: tool_name.clone(),
      input: input.clone().unwrap_or(Value::Null),
      tool_use_id: tool_use_id.clone(),
      permission_suggestions,
    },
  );

  let approval_type = match tool_name.as_deref() {
    Some(name) if is_accept_edits_tool(name) => ApprovalType::Patch,
    Some("AskUserQuestion") => ApprovalType::Question,
    _ => ApprovalType::Exec,
  };

  let command = input
    .as_ref()
    .and_then(|value| value.get("command"))
    .and_then(Value::as_str)
    .map(String::from);
  let file_path = input
    .as_ref()
    .and_then(|value| value.get("file_path"))
    .and_then(Value::as_str)
    .map(String::from);
  let diff = input.as_ref().and_then(|payload| {
    patch_diff_for_approval(tool_name.as_deref(), payload, file_path.as_deref())
  });
  let question = input
    .as_ref()
    .and_then(|value| value.get("question"))
    .and_then(Value::as_str)
    .map(String::from)
    .or_else(|| {
      input
        .as_ref()
        .and_then(|value| value.get("questions"))
        .and_then(Value::as_array)
        .and_then(|questions| questions.first())
        .and_then(|question| question.get("question"))
        .and_then(Value::as_str)
        .map(String::from)
    });

  let plan_update = if matches!(tool_name.as_deref(), Some("ExitPlanMode")) {
    input
      .as_ref()
      .and_then(plan_text_from_tool_input)
      .map(|plan| state_output(ConnectorStateEvent::PlanUpdated(plan)))
  } else {
    None
  };

  let tool_input_json = input
    .as_ref()
    .and_then(|value| serde_json::to_string(value).ok());
  let mut events = Vec::new();
  if let Some(plan_update) = plan_update {
    events.push(plan_update);
  }
  events.push(state_output(ConnectorStateEvent::ApprovalRequested {
    request_id,
    approval_type,
    tool_name: tool_name.clone(),
    tool_input: tool_input_json,
    command,
    file_path,
    diff,
    question,
    permission_reason: None,
    requested_permissions: None,
    proposed_amendment: None,
    permission_suggestions: suggestions_for_event,
    elicitation_mode: None,
    elicitation_schema: None,
    elicitation_url: None,
    elicitation_message: None,
    mcp_server_name: None,
    network_host: None,
    network_protocol: None,
  }));
  events
}

pub(super) fn patch_diff_for_approval(
  tool_name: Option<&str>,
  payload: &Value,
  fallback_file_path: Option<&str>,
) -> Option<String> {
  if !tool_name.is_some_and(is_accept_edits_tool) {
    return payload
      .get("new_string")
      .and_then(Value::as_str)
      .and_then(trim_non_empty_str)
      .map(str::to_string);
  }

  let file_path = payload
    .get("file_path")
    .and_then(Value::as_str)
    .and_then(trim_non_empty_str)
    .or_else(|| fallback_file_path.and_then(trim_non_empty_str))
    .unwrap_or("file");

  let old_string = payload.get("old_string").and_then(Value::as_str);
  let new_string = payload.get("new_string").and_then(Value::as_str);

  if old_string.is_some() || new_string.is_some() {
    return Some(render_patch_diff(
      file_path,
      file_path,
      old_string.unwrap_or_default(),
      new_string.unwrap_or_default(),
    ));
  }

  if let Some(content) = payload
    .get("content")
    .and_then(Value::as_str)
    .and_then(trim_non_empty_str)
  {
    return Some(render_patch_diff("/dev/null", file_path, "", content));
  }

  payload
    .get("new_string")
    .and_then(Value::as_str)
    .and_then(trim_non_empty_str)
    .map(str::to_string)
}

fn plan_text_from_tool_input(payload: &Value) -> Option<String> {
  payload
    .get("plan")
    .and_then(Value::as_str)
    .and_then(trim_non_empty_str)
    .or_else(|| {
      payload
        .get("current_plan")
        .and_then(Value::as_str)
        .and_then(trim_non_empty_str)
    })
    .map(str::to_string)
}

fn render_patch_diff(old_path: &str, new_path: &str, old_text: &str, new_text: &str) -> String {
  let mut lines = vec![
    format!("--- {old_path}"),
    format!("+++ {new_path}"),
    "@@".to_string(),
  ];

  lines.extend(old_text.lines().map(|line| format!("-{line}")));
  lines.extend(new_text.lines().map(|line| format!("+{line}")));

  if old_text.is_empty() && new_text.is_empty() {
    lines.push("(no textual changes provided)".to_string());
  }

  lines.join("\n")
}

fn trim_non_empty_str(value: &str) -> Option<&str> {
  let trimmed = value.trim();
  if trimmed.is_empty() {
    None
  } else {
    Some(trimmed)
  }
}

/// Handle `control_response` from CLI — resolve pending control requests.
pub(crate) async fn handle_control_response(
  raw: &Value,
  pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
) {
  let Some(response) = value_field(raw, "response", "response") else {
    return;
  };

  let request_id = string_field(response, "request_id", "requestId").unwrap_or_default();
  if request_id.is_empty() {
    return;
  }

  let mut pending = pending_controls.lock().await;
  if let Some(tx) = pending.remove(request_id.as_str()) {
    let _ = tx.send(response.clone());
  }
}
