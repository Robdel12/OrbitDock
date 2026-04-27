use std::time::Instant;

use serde_json::Value;

use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent, ToolRow};
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};

use crate::rows::{
  extract_result_summary, make_entry, now_iso, parse_epoch_ms, refresh_shell_execution,
};

use super::{state_output, transport_output};

pub(super) fn finalize_tool_row(
  tool_row: &mut ToolRow,
  row_id: &str,
  content: &str,
  is_error: bool,
  cwd: &str,
  events: &mut Vec<ConnectorOutput>,
  session_id: &str,
) {
  tool_row.status = if is_error {
    ToolStatus::Failed
  } else {
    ToolStatus::Completed
  };

  let ended = now_iso();
  if tool_row.duration_ms.is_none() {
    if let Some(started) = tool_row.started_at.as_deref() {
      if let (Some(start_ms), Some(end_ms)) = (parse_epoch_ms(started), parse_epoch_ms(&ended)) {
        if end_ms > start_ms {
          tool_row.duration_ms = Some(end_ms - start_ms);
        }
      }
    }
  }
  tool_row.ended_at = Some(ended);

  if tool_row.summary.is_none() {
    tool_row.summary = if is_error {
      Some("Error".to_string())
    } else {
      extract_result_summary(&tool_row.title, content)
    };
  }

  let result_summary = tool_row.summary.clone();
  tool_row.result = Some(serde_json::json!({
    "tool_name": tool_row.title.clone(),
    "output": content,
    "summary": result_summary.as_deref().unwrap_or(""),
  }));
  refresh_shell_execution(tool_row, cwd, Some(content));

  let raw_input = tool_row
    .invocation
    .is_object()
    .then_some(&tool_row.invocation);
  tool_row.tool_display = Some(
    orbitdock_protocol::conversation_contracts::compute_tool_display(
      orbitdock_protocol::conversation_contracts::ToolDisplayInput {
        kind: tool_row.kind,
        family: tool_row.family,
        status: tool_row.status,
        title: &tool_row.title,
        subtitle: tool_row.subtitle.as_deref(),
        summary: tool_row.summary.as_deref(),
        duration_ms: tool_row.duration_ms,
        invocation_input: raw_input,
        result_output: Some(content),
      },
    ),
  );

  if tool_row.kind == ToolKind::Bash && !content.is_empty() {
    events.push(transport_output(ConnectorTransportEffect::ToolPtyOutput {
      tool_id: row_id.to_string(),
      bytes: content.as_bytes().to_vec(),
    }));
  }
  if tool_row.kind == ToolKind::Bash {
    events.push(transport_output(ConnectorTransportEffect::ToolPtyExited {
      tool_id: row_id.to_string(),
      exit_code: if is_error { Some(1) } else { Some(0) },
    }));
  }

  events.push(state_output(ConnectorStateEvent::ConversationRowUpdated {
    row_id: row_id.to_string(),
    entry: make_entry(session_id, ConversationRow::Tool(tool_row.clone())),
  }));
}

pub(super) fn tool_result_content(block: &Value) -> String {
  block
    .get("content")
    .map(|value| {
      if let Some(content) = value.as_str() {
        content.to_string()
      } else if let Some(items) = value.as_array() {
        items
          .iter()
          .filter_map(|item| {
            (item.get("type").and_then(Value::as_str) == Some("text"))
              .then(|| item.get("text").and_then(Value::as_str))
              .flatten()
              .map(String::from)
          })
          .collect::<Vec<_>>()
          .join("\n")
      } else {
        value.to_string()
      }
    })
    .unwrap_or_default()
}

pub(super) fn value_field<'a>(
  value: &'a Value,
  snake_key: &str,
  camel_key: &str,
) -> Option<&'a Value> {
  value.get(snake_key).or_else(|| value.get(camel_key))
}

pub(super) fn string_field(value: &Value, snake_key: &str, camel_key: &str) -> Option<String> {
  value_field(value, snake_key, camel_key)
    .and_then(Value::as_str)
    .map(String::from)
}

pub(super) fn flush_streaming(
  events: &mut Vec<ConnectorOutput>,
  streaming_content: &mut String,
  streaming_msg_id: &mut Option<String>,
  streaming_last_broadcast: &mut Option<Instant>,
  session_id: &str,
) {
  if let Some(message_id) = streaming_msg_id.take() {
    *streaming_last_broadcast = None;
    if !streaming_content.is_empty() {
      let row = ConversationRow::Assistant(MessageRowContent {
        id: message_id.clone(),
        content: std::mem::take(streaming_content),
        turn_id: None,
        timestamp: Some(now_iso()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      });
      events.push(state_output(ConnectorStateEvent::ConversationRowUpdated {
        row_id: message_id,
        entry: make_entry(session_id, row),
      }));
    }
  }
}

pub(super) fn value_to_u64(value: Option<&Value>) -> u64 {
  value.and_then(Value::as_u64).unwrap_or(0)
}
