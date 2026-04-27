use serde_json::Value;
use tracing::warn;

use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};

use crate::connector::is_accept_edits_tool;
use crate::images::extract_image_input;
use crate::rows::{make_entry, make_tool_row, now_iso, refresh_shell_execution};

use super::control::patch_diff_for_approval;
use super::helpers::{finalize_tool_row, flush_streaming, tool_result_content, value_to_u64};
use super::{state_output, transport_output, ClaudeEventLoopState};

pub(crate) fn handle_assistant_message(
  raw: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let mut events = Vec::new();
  let had_streaming = state.streaming_msg_id.is_some();

  flush_streaming(
    &mut events,
    &mut state.streaming_content,
    &mut state.streaming_msg_id,
    &mut state.streaming_last_broadcast,
    session_id,
  );

  let Some(message) = raw.get("message") else {
    return events;
  };
  let Some(content_blocks) = message.get("content").and_then(Value::as_array) else {
    return events;
  };

  let mut tool_use_blocks = Vec::new();
  let mut tool_result_blocks = Vec::new();
  let mut text_thinking_blocks = Vec::new();

  for block in content_blocks {
    match block.get("type").and_then(Value::as_str).unwrap_or("") {
      "tool_use" => tool_use_blocks.push(block.clone()),
      "tool_result" => tool_result_blocks.push(block.clone()),
      "text" | "thinking" if !had_streaming => text_thinking_blocks.push(block.clone()),
      _ => {}
    }
  }

  for block in tool_use_blocks {
    let tool_name = block
      .get("name")
      .or_else(|| block.get("tool_name"))
      .or_else(|| block.get("toolName"))
      .and_then(Value::as_str)
      .unwrap_or_else(|| {
        let input = block.get("input");
        if let Some(input) = input {
          if input.get("subagent_type").is_some()
            || input.get("prompt").is_some()
            || input
              .get("description")
              .and_then(Value::as_str)
              .is_some_and(|value| !value.is_empty())
          {
            return "Agent";
          }
        }
        "unknown"
      });
    let input_value = block.get("input");
    let tool_use_id = block.get("id").and_then(Value::as_str);
    let message_id = tool_use_id
      .map(str::to_string)
      .unwrap_or_else(|| make_row_id("claude-msg", session_id));

    let mut tool_row = make_tool_row(
      message_id.clone(),
      tool_name,
      input_value,
      ToolStatus::Running,
    );
    refresh_shell_execution(&mut tool_row, &state.cwd, None);

    if tool_row.kind == ToolKind::Bash {
      events.push(transport_output(ConnectorTransportEffect::ToolPtyCreated {
        tool_id: message_id.clone(),
      }));
    }

    state.tool_rows.insert(message_id.clone(), tool_row.clone());
    events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
      make_entry(session_id, ConversationRow::Tool(tool_row)),
    )));

    if let Some(payload) = input_value {
      if let Some(diff) = patch_diff_for_tool_use(Some(tool_name), payload) {
        if !state.turn_patch_diff.is_empty() {
          state.turn_patch_diff.push_str("\n\n");
        }
        state.turn_patch_diff.push_str(&diff);
        events.push(state_output(ConnectorStateEvent::DiffUpdated(
          state.turn_patch_diff.clone(),
        )));
      }
    }
  }

  for block in tool_result_blocks {
    if block.get("type").and_then(Value::as_str) != Some("tool_result") {
      continue;
    }

    finalize_tool_result_block(&block, session_id, state, &mut events, true);
  }

  for block in text_thinking_blocks {
    let id = make_row_id("claude-msg", session_id);

    match block.get("type").and_then(Value::as_str).unwrap_or("") {
      "text" => {
        let text = block.get("text").and_then(Value::as_str).unwrap_or("");
        let row = ConversationRow::Assistant(MessageRowContent {
          id,
          content: text.to_string(),
          turn_id: None,
          timestamp: Some(now_iso()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        });
        events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
          make_entry(session_id, row),
        )));
      }
      "thinking" => {
        let thinking = block.get("thinking").and_then(Value::as_str).unwrap_or("");
        let row = ConversationRow::Thinking(MessageRowContent {
          id,
          content: thinking.to_string(),
          turn_id: None,
          timestamp: Some(now_iso()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        });
        events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
          make_entry(session_id, row),
        )));
      }
      _ => {}
    }
  }

  if let Some(usage) = message.get("usage").and_then(Value::as_object) {
    let input = value_to_u64(usage.get("input_tokens"));
    let cached = value_to_u64(usage.get("cache_read_input_tokens"))
      + value_to_u64(usage.get("cache_creation_input_tokens"));
    let call_output = value_to_u64(usage.get("output_tokens"));
    events.push(state_output(ConnectorStateEvent::TokensUpdated {
      usage: orbitdock_protocol::TokenUsage {
        input_tokens: input,
        output_tokens: call_output,
        cached_tokens: cached,
        context_window: state.last_context_window,
      },
      snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::Mixed,
    }));
  }

  events
}

pub(super) fn handle_user_message(
  raw: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let mut events = Vec::new();
  let Some(message) = raw.get("message") else {
    return events;
  };

  let is_subagent_prompt = raw
    .get("parent_tool_use_id")
    .or_else(|| message.get("parent_tool_use_id"))
    .is_some();
  let Some(content_blocks) = message.get("content").and_then(Value::as_array) else {
    return events;
  };

  let mut text_parts = Vec::new();
  let mut images = Vec::new();

  for block in content_blocks {
    match block.get("type").and_then(Value::as_str).unwrap_or("") {
      "text" => {
        if let Some(text) = block.get("text").and_then(Value::as_str) {
          if !text.is_empty() {
            text_parts.push(text.to_string());
          }
        }
      }
      "image" => {
        if let Some(image) = extract_image_input(block) {
          images.push(image);
        }
      }
      _ => {}
    }
  }

  let user_text = text_parts.join("\n");
  if (!user_text.is_empty() || !images.is_empty()) && !is_subagent_prompt {
    let msg_id = message
      .get("id")
      .and_then(Value::as_str)
      .map(String::from)
      .unwrap_or_else(|| format!("claude-user-{}", uuid::Uuid::new_v4()));

    events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
      make_entry(
        session_id,
        ConversationRow::User(MessageRowContent {
          id: msg_id,
          content: user_text,
          turn_id: None,
          timestamp: Some(now_iso()),
          is_streaming: false,
          images,
          memory_citation: None,
          delivery_status: None,
        }),
      ),
    )));
  }

  if !content_blocks
    .iter()
    .any(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
  {
    return events;
  }

  for block in content_blocks {
    if block.get("type").and_then(Value::as_str) != Some("tool_result") {
      continue;
    }

    finalize_tool_result_block(block, session_id, state, &mut events, false);
  }

  events
}

pub(super) fn handle_tool_progress(
  raw: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let Some(tool_use_id) = raw.get("tool_use_id").and_then(Value::as_str) else {
    return vec![];
  };

  let tool_name = raw
    .get("tool_name")
    .and_then(Value::as_str)
    .unwrap_or("Tool");
  let elapsed = raw
    .get("elapsed_time_seconds")
    .and_then(Value::as_u64)
    .unwrap_or(0);

  if let Some(tool_row) = state.tool_rows.get_mut(tool_use_id) {
    tool_row.summary = Some(format!("{} running ({}s)", tool_name, elapsed));
    tool_row.duration_ms = Some(elapsed * 1000);
    vec![state_output(ConnectorStateEvent::ConversationRowUpdated {
      row_id: tool_use_id.to_string(),
      entry: make_entry(session_id, ConversationRow::Tool(tool_row.clone())),
    })]
  } else {
    vec![]
  }
}

pub(super) fn handle_result_message(
  raw: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let mut events = Vec::new();

  flush_streaming(
    &mut events,
    &mut state.streaming_content,
    &mut state.streaming_msg_id,
    &mut state.streaming_last_broadcast,
    session_id,
  );

  if let Some(model_usage) = raw.get("modelUsage").and_then(Value::as_object) {
    if let Some(context_window) = model_usage
      .values()
      .find_map(|stats| stats.get("contextWindow").and_then(Value::as_u64))
    {
      state.last_context_window = context_window.max(1);
    }
  }

  let subtype = raw.get("subtype").and_then(Value::as_str).unwrap_or("");
  let is_error = raw
    .get("is_error")
    .and_then(Value::as_bool)
    .unwrap_or(false);

  if is_error || subtype.starts_with("error") {
    let reason = if subtype.is_empty() {
      "error".to_string()
    } else {
      subtype.to_string()
    };
    events.push(state_output(ConnectorStateEvent::TurnAborted { reason }));
  } else {
    events.push(state_output(ConnectorStateEvent::TurnCompleted));
  }

  events
}

fn patch_diff_for_tool_use(tool_name: Option<&str>, payload: &Value) -> Option<String> {
  if !tool_name.is_some_and(is_accept_edits_tool) {
    return None;
  }

  patch_diff_for_approval(
    tool_name,
    payload,
    payload.get("file_path").and_then(Value::as_str),
  )
}

fn finalize_tool_result_block(
  block: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
  events: &mut Vec<ConnectorOutput>,
  refresh_unknown_shell_output: bool,
) {
  let content = tool_result_content(block);
  let is_error = block
    .get("is_error")
    .and_then(Value::as_bool)
    .unwrap_or(false);

  if let Some(tool_use_id) = block.get("tool_use_id").and_then(Value::as_str) {
    let task_id = state.task_tool_use_map.remove(tool_use_id);
    let row_id = task_id.unwrap_or_else(|| tool_use_id.to_string());

    if let Some(mut tool_row) = state.tool_rows.remove(&row_id) {
      finalize_tool_row(
        &mut tool_row,
        &row_id,
        &content,
        is_error,
        &state.cwd,
        events,
        session_id,
      );
    } else {
      let mut tool_row = make_tool_row(
        row_id.clone(),
        "unknown",
        None,
        if is_error {
          ToolStatus::Failed
        } else {
          ToolStatus::Completed
        },
      );
      tool_row.ended_at = Some(now_iso());
      tool_row.result = Some(serde_json::json!({
        "tool_name": "unknown",
        "output": content.clone(),
      }));
      if refresh_unknown_shell_output {
        refresh_shell_execution(&mut tool_row, &state.cwd, Some(&content));
      }
      events.push(state_output(ConnectorStateEvent::ConversationRowUpdated {
        row_id,
        entry: make_entry(session_id, ConversationRow::Tool(tool_row)),
      }));
    }
  } else {
    warn!(
      component = "claude_connector",
      event = "claude.tool_result.no_tool_use_id",
      session_id = %session_id,
      "tool_result block missing tool_use_id"
    );
  }
}

fn make_row_id(prefix: &str, session_id: &str) -> String {
  format!(
    "{}-{}-{}",
    prefix,
    &session_id[..8.min(session_id.len())],
    uuid::Uuid::new_v4()
  )
}
