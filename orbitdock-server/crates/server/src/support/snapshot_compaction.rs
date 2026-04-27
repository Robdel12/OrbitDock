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
