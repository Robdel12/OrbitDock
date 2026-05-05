//! WebSocket transport sanitization helpers.

use orbitdock_protocol::conversation_contracts::RowEntrySummary;
use orbitdock_protocol::ServerMessage;

/// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
pub(crate) const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;

/// Lightweight timeline representation used by HTTP conversation rows and WS deltas.
/// Heavy command payloads are fetched via REST row-content endpoints.
pub(crate) fn sanitize_row_entry_summary_for_transport(entry: RowEntrySummary) -> RowEntrySummary {
  entry.into_transport_summary()
}

pub(crate) fn sanitize_row_entry_summaries_for_transport(
  rows: Vec<RowEntrySummary>,
) -> Vec<RowEntrySummary> {
  rows
    .into_iter()
    .map(sanitize_row_entry_summary_for_transport)
    .collect()
}

/// Prepare an outbound `ServerMessage` for transport.
/// Applies transport-safe shaping for timeline updates.
pub(crate) fn sanitize_server_message_for_transport(mut msg: ServerMessage) -> ServerMessage {
  if let ServerMessage::ConversationRowsChanged { upserted, .. } = &mut msg {
    let rows = std::mem::take(upserted);
    *upserted = sanitize_row_entry_summaries_for_transport(rows);
  }
  msg
}

/// Sanitize a pre-serialized replay event JSON string for transport.
pub(crate) fn sanitize_replay_event_for_transport(event_json: &str) -> Option<String> {
  let mut value: serde_json::Value = serde_json::from_str(event_json).ok()?;
  if sanitize_replay_event_value_for_transport(&mut value) {
    return serde_json::to_string(&value).ok();
  }

  let revision = value
    .as_object()
    .and_then(|object| object.get("revision").cloned());

  if let Some(object) = value.as_object_mut() {
    object.remove("revision");
  }

  let message: ServerMessage = serde_json::from_value(value).ok()?;
  let sanitized = sanitize_server_message_for_transport(message);
  let mut sanitized_value = serde_json::to_value(sanitized).ok()?;
  if let Some(revision) = revision {
    if let Some(object) = sanitized_value.as_object_mut() {
      object.insert("revision".to_string(), revision);
    }
  }

  serde_json::to_string(&sanitized_value).ok()
}

fn sanitize_replay_event_value_for_transport(value: &mut serde_json::Value) -> bool {
  let Some(kind) = value
    .as_object()
    .and_then(|object| object.get("type"))
    .and_then(serde_json::Value::as_str)
  else {
    return false;
  };

  if kind != "conversation_rows_changed" {
    return false;
  }

  let Some(upserted) = value
    .as_object_mut()
    .and_then(|object| object.get_mut("upserted"))
    .and_then(serde_json::Value::as_array_mut)
  else {
    return true;
  };

  for entry in upserted {
    sanitize_row_entry_summary_value(entry);
  }

  true
}

fn sanitize_row_entry_summary_value(entry: &mut serde_json::Value) {
  let Some(row) = entry
    .as_object_mut()
    .and_then(|object| object.get_mut("row"))
  else {
    return;
  };

  sanitize_conversation_row_summary_value(row);
}

fn sanitize_conversation_row_summary_value(row: &mut serde_json::Value) {
  let Some(row_type) = row
    .as_object()
    .and_then(|object| object.get("row_type"))
    .and_then(serde_json::Value::as_str)
  else {
    return;
  };

  match row_type {
    "tool" => sanitize_tool_row_value(row),
    "activity_group" => {
      if let Some(children) = row
        .as_object_mut()
        .and_then(|object| object.get_mut("children"))
        .and_then(serde_json::Value::as_array_mut)
      {
        for child in children {
          sanitize_tool_row_value(child);
        }
      }
    }
    _ => {}
  }
}

fn sanitize_tool_row_value(tool: &mut serde_json::Value) {
  let Some(shell_execution_value) = tool
    .as_object_mut()
    .and_then(|object| object.get_mut("shell_execution"))
    .cloned()
  else {
    return;
  };

  let Ok(shell_execution) = serde_json::from_value::<
    orbitdock_protocol::conversation_contracts::ShellExecutionPayload,
  >(shell_execution_value) else {
    return;
  };

  let sanitized = shell_execution.into_transport_summary();
  if let (Some(object), Ok(sanitized_value)) =
    (tool.as_object_mut(), serde_json::to_value(sanitized))
  {
    object.insert("shell_execution".to_string(), sanitized_value);
  }
}

/// Check if any replay event exceeds the transport frame limit.
pub(crate) fn replay_has_oversize_event(events: &[String]) -> Option<usize> {
  events
    .iter()
    .map(String::len)
    .max()
    .filter(|size| *size > WS_MAX_TEXT_MESSAGE_BYTES)
}

#[cfg(test)]
#[path = "snapshot_compaction_tests.rs"]
mod tests;
