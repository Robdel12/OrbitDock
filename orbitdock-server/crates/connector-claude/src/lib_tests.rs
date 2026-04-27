use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::images::{parse_data_uri_base64, transform_image};
use super::protocol::{ImageSource, UserContentBlock};
use super::stdout::{
  handle_assistant_message, handle_cli_control_request, handle_stream_event, ClaudeEventLoopState,
  PendingApproval,
};
use orbitdock_connector_core::ConnectorStateEvent;
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind};

#[test]
fn parse_data_uri_base64_extracts_media_type_and_payload() {
  let uri = "data:image/png;base64,aGVs\nbG8=";
  let parsed = parse_data_uri_base64(uri).expect("expected valid data uri");
  assert_eq!(parsed.0, "image/png");
  assert_eq!(parsed.1, "aGVsbG8=");
}

#[test]
fn transform_image_converts_data_uri_url_to_base64_source() {
  let input = orbitdock_protocol::ImageInput {
    input_type: "url".to_string(),
    value: "data:image/png;base64,aGVsbG8=".to_string(),
    ..Default::default()
  };
  let block = transform_image(&input).expect("transform should succeed");
  match block {
    UserContentBlock::Image {
      source: ImageSource::Base64 { media_type, data },
    } => {
      assert_eq!(media_type, "image/png");
      assert_eq!(data, "aGVsbG8=");
    }
    other => panic!("expected base64 image source, got {:?}", other),
  }
}

#[test]
fn transform_image_keeps_http_url_as_url_source() {
  let input = orbitdock_protocol::ImageInput {
    input_type: "url".to_string(),
    value: "https://example.com/image.png".to_string(),
    ..Default::default()
  };
  let block = transform_image(&input).expect("transform should succeed");
  match block {
    UserContentBlock::Image {
      source: ImageSource::Url { url },
    } => assert_eq!(url, "https://example.com/image.png"),
    other => panic!("expected url image source, got {:?}", other),
  }
}

#[tokio::test]
async fn handle_cli_control_request_accepts_camel_case_permission_fields() {
  let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
    Arc::new(Mutex::new(HashMap::new()));
  let permission_suggestions = json!([
      {
          "type": "addRules",
          "behavior": "allow",
          "destination": "session",
          "rules": [{ "toolName": "Bash", "ruleContent": "npm test" }]
      }
  ]);

  let raw = json!({
      "type": "control_request",
      "requestId": "req-camel-1",
      "request": {
          "subtype": "can_use_tool",
          "toolName": "Bash",
          "toolUseID": "toolu-camel-1",
          "input": { "command": "npm test" },
          "permissionSuggestions": permission_suggestions
      }
  });

  let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
  let events = handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
  assert_eq!(events.len(), 1);
  match events[0].as_state_event() {
    Some(ConnectorStateEvent::ApprovalRequested {
      request_id,
      tool_name,
      command,
      ..
    }) => {
      assert_eq!(request_id, "req-camel-1");
      assert_eq!(tool_name.as_deref(), Some("Bash"));
      assert_eq!(command.as_deref(), Some("npm test"));
    }
    other => panic!("expected ApprovalRequested event, got {:?}", other),
  }

  let pending = pending_approvals.lock().await;
  let stored = pending
    .get("req-camel-1")
    .expect("pending approval should be stored");
  assert_eq!(stored.tool_use_id.as_deref(), Some("toolu-camel-1"));
  assert_eq!(
    stored.permission_suggestions,
    Some(raw["request"]["permissionSuggestions"].clone())
  );
}

#[tokio::test]
async fn handle_cli_control_request_uses_top_level_permission_suggestions_fallback() {
  let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
    Arc::new(Mutex::new(HashMap::new()));
  let permission_suggestions: Value = json!([
      {
          "type": "addRules",
          "behavior": "allow",
          "destination": "session",
          "rules": [{ "toolName": "Bash", "ruleContent": "git status" }]
      }
  ]);

  let raw = json!({
      "type": "control_request",
      "request_id": "req-top-level-1",
      "permissionSuggestions": permission_suggestions,
      "request": {
          "subtype": "can_use_tool",
          "tool_name": "Bash",
          "input": { "command": "git status" }
      }
  });

  let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
  let events = handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
  assert_eq!(events.len(), 1);

  let pending = pending_approvals.lock().await;
  let stored = pending
    .get("req-top-level-1")
    .expect("pending approval should be stored");
  assert_eq!(
    stored.permission_suggestions,
    Some(raw["permissionSuggestions"].clone())
  );
}

#[tokio::test]
async fn handle_cli_control_request_emits_plan_update_for_exit_plan_mode() {
  let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
    Arc::new(Mutex::new(HashMap::new()));

  let raw = json!({
      "type": "control_request",
      "request_id": "req-plan-1",
      "request": {
          "subtype": "can_use_tool",
          "tool_name": "ExitPlanMode",
          "tool_use_id": "toolu-plan-1",
          "input": {
              "plan": "# Phase 5\n- Simplify toolbar ordering UX"
          }
      }
  });

  let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
  let events = handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
  assert_eq!(events.len(), 2);

  match events[0].as_state_event() {
    Some(ConnectorStateEvent::PlanUpdated(plan)) => {
      assert_eq!(plan, "# Phase 5\n- Simplify toolbar ordering UX");
    }
    other => panic!("expected PlanUpdated event, got {:?}", other),
  }

  match events[1].as_state_event() {
    Some(ConnectorStateEvent::ApprovalRequested {
      request_id,
      tool_name,
      ..
    }) => {
      assert_eq!(request_id, "req-plan-1");
      assert_eq!(tool_name.as_deref(), Some("ExitPlanMode"));
    }
    other => panic!("expected ApprovalRequested event, got {:?}", other),
  }
}

#[tokio::test]
async fn handle_cli_control_request_rejects_missing_request_id() {
  let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
    Arc::new(Mutex::new(HashMap::new()));

  let raw = json!({
      "type": "control_request",
      "request": {
          "subtype": "can_use_tool",
          "tool_name": "Bash",
          "input": { "command": "pwd" }
      }
  });

  let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
  let events = handle_cli_control_request(&raw, &pending_approvals, &stdin_tx).await;
  assert!(events.is_empty(), "missing request id should be ignored");
  assert!(pending_approvals.lock().await.is_empty());
}

/// Build a minimal `ClaudeEventLoopState` for tests that call sub-handlers.
fn test_event_loop_state() -> ClaudeEventLoopState {
  let (stdin_tx, _stdin_rx) = tokio::sync::mpsc::channel::<String>(16);
  ClaudeEventLoopState::new(
    Arc::new(Mutex::new(None)),
    Arc::new(Mutex::new(HashMap::new())),
    Arc::new(Mutex::new(HashMap::new())),
    stdin_tx,
    "test-session".to_string(),
    "/tmp/orbitdock-claude-test".to_string(),
  )
}

#[test]
fn handle_assistant_message_emits_diff_for_edit_tool_use() {
  let raw = json!({
      "type": "assistant",
      "message": {
          "content": [
              {
                  "type": "tool_use",
                  "id": "toolu-edit-1",
                  "name": "Edit",
                  "input": {
                      "file_path": "src/main.rs",
                      "old_string": "old value",
                      "new_string": "new value"
                  }
              }
          ]
      }
  });

  let mut state = test_event_loop_state();
  state.last_context_window = 200_000;

  let events = handle_assistant_message(&raw, "sess-1", &mut state);

  let has_diff = events.iter().any(|event| {
    matches!(
        event.as_state_event(),
        Some(ConnectorStateEvent::DiffUpdated(diff))
            if diff.contains("--- src/main.rs")
                && diff.contains("+++ src/main.rs")
                && diff.contains("-old value")
                && diff.contains("+new value")
    )
  });
  assert!(has_diff, "expected DiffUpdated with patch-like content");
}

#[test]
fn handle_assistant_message_aggregates_patch_diffs_across_events() {
  let raw_edit = json!({
      "type": "assistant",
      "message": {
          "content": [
              {
                  "type": "tool_use",
                  "id": "toolu-edit-1",
                  "name": "Edit",
                  "input": {
                      "file_path": "src/a.txt",
                      "old_string": "before",
                      "new_string": "after"
                  }
              }
          ]
      }
  });
  let raw_write = json!({
      "type": "assistant",
      "message": {
          "content": [
              {
                  "type": "tool_use",
                  "id": "toolu-write-1",
                  "name": "Write",
                  "input": {
                      "file_path": "src/b.txt",
                      "content": "hello"
                  }
              }
          ]
      }
  });

  let mut state = test_event_loop_state();
  state.last_context_window = 200_000;

  let _ = handle_assistant_message(&raw_edit, "sess-1", &mut state);

  let second_events = handle_assistant_message(&raw_write, "sess-1", &mut state);

  let aggregated = second_events.iter().find_map(|event| {
    if let Some(ConnectorStateEvent::DiffUpdated(diff)) = event.as_state_event() {
      Some(diff.as_str())
    } else {
      None
    }
  });
  let diff = aggregated.expect("expected aggregated diff event");
  assert!(
    diff.contains("--- src/a.txt")
      && diff.contains("--- /dev/null")
      && diff.contains("+++ src/b.txt"),
    "expected combined diff for both edits"
  );
}

#[test]
fn handle_assistant_message_infers_agent_tool_when_name_missing() {
  // When a tool_use block lacks a "name" field but has agent-like input
  // (subagent_type, prompt, or description), we should infer "Agent".
  let raw = json!({
      "type": "assistant",
      "message": {
          "content": [
              {
                  "type": "tool_use",
                  "id": "toolu-agent-1",
                  "input": {
                      "subagent_type": "Explore",
                      "description": "Find all API endpoints"
                  }
              }
          ]
      }
  });

  let mut state = test_event_loop_state();
  state.last_context_window = 200_000;

  let events = handle_assistant_message(&raw, "sess-1", &mut state);

  // Should create a tool row with Agent classification
  let tool_row = events.iter().find_map(|e| match e.as_state_event() {
    Some(ConnectorStateEvent::ConversationRowCreated(entry)) => match &entry.row {
      ConversationRow::Tool(tr) => Some(tr.clone()),
      _ => None,
    },
    _ => None,
  });

  assert!(tool_row.is_some(), "expected a tool row to be created");
  let tr = tool_row.unwrap();
  assert_eq!(tr.family, ToolFamily::Agent, "expected Agent family");
  assert_eq!(tr.kind, ToolKind::SpawnAgent, "expected SpawnAgent kind");
  assert!(
    tr.subtitle
      .as_ref()
      .is_some_and(|s: &String| s.contains("Explore")),
    "expected subtitle to contain agent type"
  );
}

#[test]
fn handle_stream_event_recovers_when_streaming_row_id_is_missing() {
  let raw = json!({
      "type": "stream_event",
      "event": {
          "type": "content_block_delta",
          "delta": {
              "type": "text_delta",
              "text": "hello world"
          }
      }
  });

  let mut state = test_event_loop_state();
  state.streaming_content = "hello world".to_string();
  state.streaming_last_broadcast = Some(Instant::now() - std::time::Duration::from_millis(100));

  let events = handle_stream_event(&raw, "sess-1", &mut state);

  assert!(
    matches!(
      events.first(),
      Some(output) if matches!(
        output.as_state_event(),
        Some(ConnectorStateEvent::ConversationRowCreated(_))
      )
    ),
    "expected a replacement streaming row to be created"
  );
  assert!(state.streaming_msg_id.is_some());
}
