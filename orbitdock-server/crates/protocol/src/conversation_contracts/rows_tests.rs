use super::{
  compute_shell_preview, shell_terminal_snapshot, ConversationRow, ConversationRowEntry,
  ConversationRowSummary, MessageRowContent, ShellAction, ShellExecutionPayload, ShellPreviewKind,
  ShellTerminalSnapshot, ToolRow, TurnStatus,
};
use crate::conversation_contracts::render_hints::RenderHints;
use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
use crate::{ImageInput, Provider};

#[test]
fn message_row_content_round_trips_streaming_images_and_turn_id() {
  let entry = ConversationRowEntry {
    session_id: "sess-1".to_string(),
    sequence: 7,
    turn_id: Some("turn-42".to_string()),
    turn_status: TurnStatus::Active,
    row: ConversationRow::Assistant(MessageRowContent {
      id: "row-1".to_string(),
      content: "Streaming reply".to_string(),
      turn_id: Some("turn-42".to_string()),
      timestamp: Some("2026-03-13T12:00:00Z".to_string()),
      is_streaming: true,
      images: vec![ImageInput {
        input_type: "attachment".to_string(),
        value: "att-1".to_string(),
        mime_type: Some("image/png".to_string()),
        byte_count: None,
        display_name: None,
        pixel_width: None,
        pixel_height: None,
        detail: Some("original".to_string()),
      }],
      memory_citation: None,
      delivery_status: None,
    }),
  };

  let json = serde_json::to_value(&entry).expect("serialize conversation row");
  assert_eq!(
    json.get("turn_id").and_then(|value| value.as_str()),
    Some("turn-42")
  );
  assert_eq!(
    json
      .get("row")
      .and_then(|row| row.get("is_streaming"))
      .and_then(|value| value.as_bool()),
    Some(true)
  );
  assert_eq!(
    json
      .get("row")
      .and_then(|row| row.get("images"))
      .and_then(|value| value.as_array())
      .map(Vec::len),
    Some(1)
  );

  let decoded: ConversationRowEntry =
    serde_json::from_value(json).expect("deserialize conversation row");
  assert_eq!(decoded, entry);
}

#[test]
fn steer_rows_do_not_start_turns() {
  let row = ConversationRow::Steer(MessageRowContent {
    id: "steer-1".to_string(),
    content: "nudge".to_string(),
    turn_id: None,
    timestamp: None,
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: Some(super::MessageDeliveryStatus::Pending),
  });

  assert!(row.is_steer());
  assert!(!row.starts_turn());
}

#[test]
fn flat_invocation_passes_through_unchanged() {
  let row = ToolRow {
    id: "toolu_abc".into(),
    provider: Provider::Claude,
    family: ToolFamily::Shell,
    kind: ToolKind::Bash,
    status: ToolStatus::Completed,
    title: "Bash".into(),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: None,
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: serde_json::json!({"command": "ls -la"}),
    result: Some(serde_json::json!({"output": "file1\nfile2"})),
    render_hints: RenderHints::default(),
    tool_display: None,
    shell_execution: None,
  };

  let summary = row.to_summary();
  assert_eq!(summary.kind, ToolKind::Bash);
  assert_eq!(summary.family, ToolFamily::Shell);
  assert_eq!(summary.tool_display.tool_type, "bash");
}

#[test]
fn summary_fallback_uses_structured_result_output() {
  let row = ToolRow {
    id: "toolu_read".into(),
    provider: Provider::Codex,
    family: ToolFamily::FileRead,
    kind: ToolKind::Read,
    status: ToolStatus::Completed,
    title: "Read".into(),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: None,
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: serde_json::json!({"file_path": "/tmp/example.rs"}),
    result: Some(serde_json::json!({"output": "first line\nsecond line"})),
    render_hints: RenderHints::default(),
    tool_display: None,
    shell_execution: None,
  };

  let summary = row.to_summary();
  assert_eq!(summary.tool_display.tool_type, "read");
  assert_eq!(summary.tool_display.right_meta.as_deref(), Some("2 lines"));
  assert_eq!(
    summary.tool_display.output_preview.as_deref(),
    Some("first line\nsecond line")
  );
}

#[test]
fn tool_transport_summary_compacts_shell_execution_payload() {
  let row = ConversationRow::Tool(ToolRow {
    id: "cmd-big".into(),
    provider: Provider::Codex,
    family: ToolFamily::Shell,
    kind: ToolKind::Bash,
    status: ToolStatus::Completed,
    title: "cat big.log".into(),
    subtitle: Some("/tmp/project".into()),
    summary: None,
    preview: None,
    started_at: None,
    ended_at: None,
    duration_ms: Some(11),
    grouping_key: None,
    invocation: serde_json::json!({"command": "cat big.log", "cwd": "/tmp/project"}),
    result: None,
    render_hints: RenderHints::default(),
    tool_display: None,
    shell_execution: Some(ShellExecutionPayload {
      command: "cat big.log".into(),
      cwd: "/tmp/project".into(),
      process_id: None,
      actions: vec![ShellAction::Unknown {
        command: "cat big.log".into(),
      }],
      live_output_preview: None,
      aggregated_output: Some("x".repeat(20_000)),
      terminal_snapshot: Some(ShellTerminalSnapshot {
        command: "cat big.log".into(),
        cwd: "/tmp/project".into(),
        output: Some("x".repeat(20_000)),
        transcript: "x".repeat(20_000),
        title: "/tmp/project".into(),
      }),
      preview: None,
      exit_code: Some(0),
    }),
  });

  let ConversationRowSummary::Tool(summary) = row.to_transport_summary() else {
    panic!("expected tool summary");
  };
  let shell = summary.shell_execution.expect("shell execution summary");
  assert!(shell.aggregated_output.is_none());
  assert!(shell.terminal_snapshot.is_none());
  assert!(
    shell
      .live_output_preview
      .as_deref()
      .expect("preview")
      .chars()
      .count()
      <= super::SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT + 1
  );
}

#[test]
fn shell_execution_payload_serializes_with_snake_case_wire_keys() {
  let payload = ShellExecutionPayload {
    command: "npm test".into(),
    cwd: "/tmp/project".into(),
    process_id: Some("pty-1".into()),
    actions: vec![ShellAction::Unknown {
      command: "npm test".into(),
    }],
    live_output_preview: Some("running".into()),
    aggregated_output: Some("done".into()),
    terminal_snapshot: None,
    preview: Some(super::ShellPreview {
      kind: ShellPreviewKind::Status,
      lines: vec!["done".into()],
      overflow_count: Some(1),
    }),
    exit_code: Some(0),
  };

  let value = serde_json::to_value(payload).expect("shell payload json");

  assert_eq!(value["process_id"], "pty-1");
  assert_eq!(value["live_output_preview"], "running");
  assert_eq!(value["aggregated_output"], "done");
  assert_eq!(value["preview"]["overflow_count"], 1);
  assert_eq!(value["exit_code"], 0);
  assert!(value.get("processId").is_none());
  assert!(value.get("liveOutputPreview").is_none());
  assert!(value.get("aggregatedOutput").is_none());
  assert!(value.get("exitCode").is_none());
}

#[test]
fn shell_terminal_snapshot_renders_shell_like_transcript() {
  let snapshot =
    shell_terminal_snapshot("swiftc -print-target-info", "/tmp/project", Some("done\n"))
      .expect("terminal snapshot");

  assert_eq!(snapshot.command, "swiftc -print-target-info");
  assert_eq!(snapshot.cwd, "/tmp/project");
  assert_eq!(snapshot.output.as_deref(), Some("done\n"));
  let transcript = snapshot.transcript();
  assert!(transcript.contains("➜"));
  assert!(transcript.contains("swiftc -print-target-info"));
  assert!(transcript.contains("done"));
  assert!(transcript.ends_with("$ "));
  assert_eq!(snapshot.title, "/tmp/project");
}

#[test]
fn shell_terminal_snapshot_strips_legacy_stdin_markers() {
  let snapshot = shell_terminal_snapshot(
    "python -i",
    "/tmp/project",
    Some("[stdin] print('hello')\n[stdin]\ndone\n"),
  )
  .expect("terminal snapshot");

  assert_eq!(snapshot.output.as_deref(), Some("print('hello')\ndone\n"));
  assert!(!snapshot.transcript().contains("[stdin]"));
  assert!(snapshot.transcript().contains("print('hello')"));
}

#[test]
fn shell_preview_prefers_build_status_line() {
  let preview = compute_shell_preview(
    &[ShellAction::Unknown {
      command: "npm run build".to_string(),
    }],
    Some("dist/assets/index.js 123 kB\nbuilt in 228ms\n"),
  )
  .expect("preview");

  assert_eq!(preview.kind, ShellPreviewKind::Status);
  assert_eq!(preview.lines, vec!["built in 228ms".to_string()]);
  assert_eq!(preview.overflow_count, None);
}

#[test]
fn shell_preview_collapses_file_list() {
  let preview = compute_shell_preview(
    &[ShellAction::Unknown {
      command: "git status --short".to_string(),
    }],
    Some(
      "?? web/command-execution-expanded.jsx\n?? web/command-execution-row.jsx\n?? web/command-execution-row.module.css\n",
    ),
  )
  .expect("preview");

  assert_eq!(preview.kind, ShellPreviewKind::FileList);
  assert_eq!(preview.lines.len(), 2);
  assert_eq!(preview.overflow_count, Some(1));
}
