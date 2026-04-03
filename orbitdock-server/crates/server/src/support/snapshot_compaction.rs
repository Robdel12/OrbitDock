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
mod tests {
  use super::{sanitize_row_entry_summary_for_transport, sanitize_server_message_for_transport};
  use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
  use orbitdock_protocol::conversation_contracts::{
    CommandExecutionPreview, CommandExecutionPreviewKind, CommandExecutionRow,
    CommandExecutionStatus, CommandExecutionTerminalSnapshot, ConversationRowSummary,
    RowEntrySummary, TurnStatus,
  };
  use orbitdock_protocol::ServerMessage;

  fn command_row_summary(
    live_output_preview: Option<String>,
    aggregated_output: Option<String>,
  ) -> RowEntrySummary {
    RowEntrySummary {
      session_id: "session-1".to_string(),
      sequence: 1,
      turn_id: Some("turn-1".to_string()),
      turn_status: TurnStatus::Active,
      row: ConversationRowSummary::CommandExecution(CommandExecutionRow {
        id: "row-1".to_string(),
        status: CommandExecutionStatus::Completed,
        command: "cat README.md".to_string(),
        cwd: "/repo".to_string(),
        process_id: None,
        command_actions: vec![],
        live_output_preview,
        aggregated_output,
        terminal_snapshot: Some(CommandExecutionTerminalSnapshot {
          command: "cat README.md".to_string(),
          cwd: "/repo".to_string(),
          output: Some("full output".to_string()),
          transcript: "$ cat README.md\nfull output".to_string(),
          title: "Terminal".to_string(),
        }),
        preview: Some(CommandExecutionPreview {
          kind: CommandExecutionPreviewKind::Status,
          lines: vec![
            "line 1".to_string(),
            "line 2".to_string(),
            "line 3".to_string(),
            "line 4".to_string(),
            "line 5".to_string(),
            "line 6".to_string(),
            "line 7".to_string(),
          ],
          overflow_count: Some(2),
        }),
        exit_code: Some(0),
        duration_ms: Some(11),
        render_hints: RenderHints::default(),
      }),
    }
  }

  #[test]
  fn sanitize_row_summary_drops_heavy_command_fields() {
    let summary = command_row_summary(None, Some("x".repeat(10_000)));
    let sanitized = sanitize_row_entry_summary_for_transport(summary);

    let ConversationRowSummary::CommandExecution(row) = sanitized.row else {
      panic!("expected command execution row");
    };
    assert!(row.aggregated_output.is_none());
    assert!(row.terminal_snapshot.is_none());
    assert!(row.live_output_preview.is_some());
    assert!(row.live_output_preview.unwrap_or_default().chars().count() <= 8_195);
  }

  #[test]
  fn sanitize_row_summary_bounds_preview_lines_and_overflow() {
    let summary = command_row_summary(Some("preview".to_string()), None);
    let sanitized = sanitize_row_entry_summary_for_transport(summary);

    let ConversationRowSummary::CommandExecution(row) = sanitized.row else {
      panic!("expected command execution row");
    };
    let preview = row.preview.expect("preview");
    assert_eq!(preview.lines.len(), 6);
    assert_eq!(preview.overflow_count, Some(3));
  }

  #[test]
  fn sanitize_server_message_conversation_rows_changed() {
    let message = ServerMessage::ConversationRowsChanged {
      session_id: "session-1".to_string(),
      upserted: vec![command_row_summary(None, Some("payload".to_string()))],
      removed_row_ids: vec![],
      total_row_count: 1,
    };

    let sanitized = sanitize_server_message_for_transport(message);
    let ServerMessage::ConversationRowsChanged { upserted, .. } = sanitized else {
      panic!("expected conversation rows changed");
    };
    let ConversationRowSummary::CommandExecution(row) = &upserted[0].row else {
      panic!("expected command execution row");
    };
    assert!(row.aggregated_output.is_none());
    assert!(row.terminal_snapshot.is_none());
  }
}
