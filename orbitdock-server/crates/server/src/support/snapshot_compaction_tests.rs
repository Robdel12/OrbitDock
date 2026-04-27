use super::{sanitize_row_entry_summary_for_transport, sanitize_server_message_for_transport};
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::tool_display::{
  compute_tool_display, ToolDisplayInput,
};
use orbitdock_protocol::conversation_contracts::{
  ConversationRowSummary, RowEntrySummary, ShellExecutionPayload, ShellPreview, ShellPreviewKind,
  ShellTerminalSnapshot, ToolRowSummary, TurnStatus,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::{Provider, ServerMessage};

fn shell_tool_row_summary(
  live_output_preview: Option<String>,
  aggregated_output: Option<String>,
) -> RowEntrySummary {
  let tool_display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Bash,
    family: ToolFamily::Shell,
    status: ToolStatus::Completed,
    title: "cat README.md",
    subtitle: Some("/repo"),
    summary: None,
    duration_ms: Some(11),
    invocation_input: None,
    result_output: None,
  });
  RowEntrySummary {
    session_id: "session-1".to_string(),
    sequence: 1,
    turn_id: Some("turn-1".to_string()),
    turn_status: TurnStatus::Active,
    row: ConversationRowSummary::Tool(ToolRowSummary {
      id: "row-1".to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Completed,
      title: "cat README.md".to_string(),
      subtitle: Some("/repo".to_string()),
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: Some(11),
      grouping_key: None,
      render_hints: RenderHints::default(),
      tool_display,
      shell_execution: Some(ShellExecutionPayload {
        command: "cat README.md".to_string(),
        cwd: "/repo".to_string(),
        process_id: None,
        actions: vec![],
        live_output_preview,
        aggregated_output,
        terminal_snapshot: Some(ShellTerminalSnapshot {
          command: "cat README.md".to_string(),
          cwd: "/repo".to_string(),
          output: Some("full output".to_string()),
          transcript: "$ cat README.md\nfull output".to_string(),
          title: "Terminal".to_string(),
        }),
        preview: Some(ShellPreview {
          kind: ShellPreviewKind::Status,
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
      }),
    }),
  }
}

#[test]
fn sanitize_row_summary_drops_heavy_shell_fields() {
  let summary = shell_tool_row_summary(None, Some("x".repeat(10_000)));
  let sanitized = sanitize_row_entry_summary_for_transport(summary);

  let ConversationRowSummary::Tool(row) = sanitized.row else {
    panic!("expected tool row");
  };
  let shell = row.shell_execution.expect("shell_execution");
  assert!(shell.aggregated_output.is_none());
  assert!(shell.terminal_snapshot.is_none());
  assert!(shell.live_output_preview.is_some());
  assert!(
    shell
      .live_output_preview
      .unwrap_or_default()
      .chars()
      .count()
      <= 8_195
  );
}

#[test]
fn sanitize_row_summary_bounds_preview_lines_and_overflow() {
  let summary = shell_tool_row_summary(Some("preview".to_string()), None);
  let sanitized = sanitize_row_entry_summary_for_transport(summary);

  let ConversationRowSummary::Tool(row) = sanitized.row else {
    panic!("expected tool row");
  };
  let shell = row.shell_execution.expect("shell_execution");
  let preview = shell.preview.expect("preview");
  assert_eq!(preview.lines.len(), 6);
  assert_eq!(preview.overflow_count, Some(3));
}

#[test]
fn sanitize_server_message_conversation_rows_changed() {
  let message = ServerMessage::ConversationRowsChanged {
    session_id: "session-1".to_string(),
    upserted: vec![shell_tool_row_summary(None, Some("payload".to_string()))],
    removed_row_ids: vec![],
    total_row_count: 1,
  };

  let sanitized = sanitize_server_message_for_transport(message);
  let ServerMessage::ConversationRowsChanged { upserted, .. } = sanitized else {
    panic!("expected conversation rows changed");
  };
  let ConversationRowSummary::Tool(row) = &upserted[0].row else {
    panic!("expected tool row");
  };
  let shell = row.shell_execution.as_ref().expect("shell_execution");
  assert!(shell.aggregated_output.is_none());
  assert!(shell.terminal_snapshot.is_none());
}
