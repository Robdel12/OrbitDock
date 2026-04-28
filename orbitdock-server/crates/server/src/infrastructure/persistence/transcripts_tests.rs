use super::*;
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};
use serde_json::Value;
use std::io::Write;
use tempfile::NamedTempFile;

fn write_transcript(lines: &[Value]) -> NamedTempFile {
  let mut file = NamedTempFile::new().expect("temp transcript");
  for line in lines {
    writeln!(
      file,
      "{}",
      serde_json::to_string(line).expect("serialize transcript line")
    )
    .expect("write transcript line");
  }
  file
}

#[test]
fn load_messages_from_transcript_surfaces_codex_function_call_tools() {
  let transcript = write_transcript(&[
    serde_json::json!({
      "type": "response_item",
      "payload": {
        "type": "function_call",
        "name": "Read",
        "arguments": "{\"file_path\":\"/tmp/example.rs\"}",
        "call_id": "call-read-1"
      }
    }),
    serde_json::json!({
      "type": "response_item",
      "payload": {
        "type": "function_call_output",
        "call_id": "call-read-1",
        "output": "fn main() {}"
      }
    }),
  ]);

  let rows = load_messages_from_transcript(
    transcript.path().to_str().expect("transcript path"),
    "session-1",
  )
  .expect("load transcript rows");

  assert_eq!(rows.len(), 1);
  let ConversationRow::Tool(tool) = &rows[0].row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.kind, ToolKind::Read);
  assert_eq!(tool.status, ToolStatus::Completed);
  assert_eq!(tool.id, "call-read-1");
  assert_eq!(
    tool
      .invocation
      .get("raw_input")
      .and_then(|value| value.get("file_path"))
      .and_then(Value::as_str),
    Some("/tmp/example.rs")
  );
  assert_eq!(
    tool
      .result
      .as_ref()
      .and_then(|value| value.get("raw_output"))
      .and_then(Value::as_str),
    Some("fn main() {}")
  );
  assert_eq!(
    tool
      .tool_display
      .as_ref()
      .map(|display| display.tool_type.as_str()),
    Some("read")
  );
  assert_eq!(
    tool
      .tool_display
      .as_ref()
      .and_then(|display| display.output_preview.as_deref()),
    Some("fn main() {}")
  );
}

#[test]
fn load_messages_from_transcript_surfaces_codex_tool_search_rows() {
  let transcript = write_transcript(&[
    serde_json::json!({
      "type": "response_item",
      "payload": {
        "type": "tool_search_call",
        "call_id": "search-1",
        "execution": "client",
        "arguments": {
          "query": "calendar create",
          "limit": 1
        }
      }
    }),
    serde_json::json!({
      "type": "response_item",
      "payload": {
        "type": "tool_search_output",
        "call_id": "search-1",
        "status": "completed",
        "execution": "client",
        "tools": [
          { "name": "search_query" }
        ]
      }
    }),
  ]);

  let rows = load_messages_from_transcript(
    transcript.path().to_str().expect("transcript path"),
    "session-1",
  )
  .expect("load transcript rows");

  assert_eq!(rows.len(), 1);
  let ConversationRow::Tool(tool) = &rows[0].row else {
    panic!("expected tool row");
  };
  assert_eq!(tool.kind, ToolKind::ToolSearch);
  assert_eq!(tool.status, ToolStatus::Completed);
  assert_eq!(tool.id, "search-1");
  assert_eq!(
    tool
      .invocation
      .get("raw_input")
      .and_then(|value| value.get("query"))
      .and_then(Value::as_str),
    Some("calendar create")
  );
  assert_eq!(
    tool
      .tool_display
      .as_ref()
      .map(|display| display.tool_type.as_str()),
    Some("toolSearch")
  );
  assert_eq!(
    tool
      .tool_display
      .as_ref()
      .and_then(|display| display.subtitle.as_deref()),
    Some("calendar create")
  );
}
