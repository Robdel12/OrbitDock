use std::any::Any;
use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::time::Instant;

use futures::FutureExt;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{error, warn};

use orbitdock_connector_core::{
  panic_payload_message, ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent,
  ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent, ToolRow};
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};

use crate::connector::is_accept_edits_tool;
use crate::images::extract_image_input;
use crate::rows::{
  extract_result_summary, make_entry, make_tool_row, now_iso, parse_epoch_ms,
  refresh_shell_execution,
};

mod control;
mod system;

use control::patch_diff_for_approval;
pub(crate) use control::{handle_cli_control_request, handle_control_response, PendingApproval};
use system::handle_system_message;

/// Groups all shared references and mutable local state for the stdout event
/// loop, replacing the 14+ individual parameters that were threaded through
/// `event_loop` → `dispatch_stdout_message` → sub-handlers.
pub(crate) struct ClaudeEventLoopState {
  pub(crate) session_id: Arc<Mutex<Option<String>>>,
  pub(crate) pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
  pub(crate) pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
  pub(crate) stdin_tx: mpsc::Sender<String>,
  /// OrbitDock session ID for structured log correlation.
  pub(crate) orbitdock_session_id: String,

  pub(crate) streaming_content: String,
  pub(crate) streaming_msg_id: Option<String>,
  pub(crate) streaming_last_broadcast: Option<Instant>,
  pub(crate) in_turn: bool,
  pub(crate) turn_patch_diff: String,
  pub(crate) last_context_window: u64,
  /// Maps tool_use_id → task_id so we can finalize task cards when the Agent
  /// tool_result arrives.
  pub(crate) task_tool_use_map: HashMap<String, String>,
  /// Tracks the in-progress "Compacting context…" message ID.
  pub(crate) compacting_msg_id: Option<String>,
  /// Live ToolRow state so we can reconstruct full ConversationRowEntry on updates.
  pub(crate) tool_rows: HashMap<String, ToolRow>,
  pub(crate) cwd: String,
  pub(crate) line_count: u64,
}

impl ClaudeEventLoopState {
  pub(crate) fn new(
    session_id: Arc<Mutex<Option<String>>>,
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
    stdin_tx: mpsc::Sender<String>,
    orbitdock_session_id: String,
    cwd: String,
  ) -> Self {
    Self {
      session_id,
      pending_controls,
      pending_approvals,
      stdin_tx,
      orbitdock_session_id,
      streaming_content: String::new(),
      streaming_msg_id: None,
      streaming_last_broadcast: None,
      in_turn: false,
      turn_patch_diff: String::new(),
      last_context_window: 1_000_000,
      task_tool_use_map: HashMap::new(),
      compacting_msg_id: None,
      tool_rows: HashMap::new(),
      cwd,
      line_count: 0,
    }
  }
}

const CLAUDE_STREAM_THROTTLE_MS: u128 = 50;

fn state_output(event: ConnectorStateEvent) -> ConnectorOutput {
  event.into()
}

fn runtime_output(event: ConnectorRuntimeDirective) -> ConnectorOutput {
  event.into()
}

fn transport_output(event: ConnectorTransportEffect) -> ConnectorOutput {
  event.into()
}

/// Read stdout line-by-line, parse JSON, and emit typed connector outputs.
pub(crate) async fn event_loop(
  stdout: tokio::process::ChildStdout,
  output_tx: mpsc::Sender<ConnectorOutput>,
  mut state: ClaudeEventLoopState,
) {
  let reader = BufReader::new(stdout);
  let mut lines = reader.lines();

  loop {
    match lines.next_line().await {
      Ok(Some(line)) => {
        state.line_count += 1;
        let line = line.trim().to_string();
        if line.is_empty() {
          continue;
        }

        let raw: Value = match serde_json::from_str(&line) {
          Ok(value) => value,
          Err(error) => {
            warn!(
              component = "claude_connector",
              event = "claude.stdout.parse_error",
              error = %error,
              line_preview = %if line.len() > 200 { &line[..200] } else { &line },
              "Failed to parse stdout JSON"
            );
            continue;
          }
        };

        let events = match AssertUnwindSafe(dispatch_stdout_message(&raw, &mut state))
          .catch_unwind()
          .await
        {
          Ok(events) => events,
          Err(payload) => {
            let payload: Box<dyn Any + Send> = payload;
            error!(
              component = "claude_connector",
              event = "claude.stdout.dispatch_panicked",
              session_id = %state.orbitdock_session_id,
              line_count = state.line_count,
              panic = %panic_payload_message(payload.as_ref()),
              raw_type = %raw.get("type").and_then(|value| value.as_str()).unwrap_or("unknown"),
              "Claude stdout dispatch panicked; ending connector loop safely"
            );
            let _ = output_tx
              .send(state_output(ConnectorStateEvent::SessionEnded {
                reason: "dispatch_panic".to_string(),
              }))
              .await;
            return;
          }
        };

        for event in events {
          if output_tx.send(event).await.is_err() {
            return;
          }
        }
      }
      Ok(None) => {
        warn!(
          component = "claude_connector",
          event = "claude.stdout.eof",
          session_id = %state.orbitdock_session_id,
          lines_read = state.line_count,
          "Claude CLI stdout EOF"
        );
        let _ = output_tx
          .send(state_output(ConnectorStateEvent::SessionEnded {
            reason: "cli_exited".to_string(),
          }))
          .await;
        return;
      }
      Err(error) => {
        error!(
          component = "claude_connector",
          event = "claude.stdout.read_error",
          session_id = %state.orbitdock_session_id,
          error = %error,
          "Error reading CLI stdout"
        );
        let _ = output_tx
          .send(state_output(ConnectorStateEvent::SessionEnded {
            reason: format!("read_error: {}", error),
          }))
          .await;
        return;
      }
    }
  }
}

/// Dispatch a raw stdout JSON message by its `type` field.
async fn dispatch_stdout_message(
  raw: &Value,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let msg_type = raw
    .get("type")
    .and_then(|value| value.as_str())
    .unwrap_or("");
  let session_id = state.session_id.lock().await.clone().unwrap_or_default();

  let is_replay = raw
    .get("isReplay")
    .and_then(|value| value.as_bool())
    .unwrap_or(false);

  if is_replay && msg_type != "system" {
    return vec![];
  }

  let mut turn_start_event = Vec::new();
  if !state.in_turn && matches!(msg_type, "assistant" | "stream_event") {
    state.in_turn = true;
    state.turn_patch_diff.clear();
    turn_start_event.push(state_output(ConnectorStateEvent::TurnStarted));
  }

  let mut events = match msg_type {
    "system" => handle_system_message(raw, state).await,
    "assistant" => handle_assistant_message(raw, &session_id, state),
    "user" => handle_user_message(raw, &session_id, state),
    "stream_event" => handle_stream_event(raw, &session_id, state),
    "tool_progress" => handle_tool_progress(raw, &session_id, state),
    "result" => {
      state.in_turn = false;
      state.turn_patch_diff.clear();
      handle_result_message(raw, &session_id, state)
    }
    "control_request" => {
      handle_cli_control_request(raw, &state.pending_approvals, &state.stdin_tx).await
    }
    "control_cancel_request" => {
      if let Some(req_id) = string_field(raw, "request_id", "requestId") {
        state.pending_approvals.lock().await.remove(req_id.as_str());
        vec![state_output(ConnectorStateEvent::ApprovalCancelled {
          request_id: req_id,
        })]
      } else {
        vec![]
      }
    }
    "control_response" => {
      handle_control_response(raw, &state.pending_controls).await;
      vec![]
    }
    "status" => {
      let mut status_events = vec![];
      if let Some(mode) = raw
        .get("permission_mode")
        .or_else(|| raw.get("permissionMode"))
        .and_then(Value::as_str)
      {
        status_events.push(state_output(ConnectorStateEvent::PermissionModeChanged {
          mode: mode.to_string(),
        }));
      }
      status_events
    }
    "tool_use_summary" => {
      let summary = raw.get("summary").and_then(Value::as_str).unwrap_or("");
      if summary.is_empty() {
        vec![]
      } else {
        let id = format!("claude-summary-{}", uuid::Uuid::new_v4());
        let row = ConversationRow::Assistant(MessageRowContent {
          id,
          content: summary.to_string(),
          turn_id: None,
          timestamp: Some(now_iso()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        });
        vec![state_output(ConnectorStateEvent::ConversationRowCreated(
          make_entry(&session_id, row),
        ))]
      }
    }
    "rate_limit_event" => {
      let rate_limit_info = raw.get("rate_limit_info").unwrap_or(raw);
      vec![state_output(ConnectorStateEvent::RateLimitEvent {
        info: orbitdock_protocol::RateLimitInfo {
          status: rate_limit_info
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("allowed")
            .to_string(),
          resets_at: rate_limit_info
            .get("resets_at")
            .and_then(Value::as_str)
            .map(String::from),
          rate_limit_type: rate_limit_info
            .get("rate_limit_type")
            .and_then(Value::as_str)
            .map(String::from),
          utilization: rate_limit_info.get("utilization").and_then(Value::as_f64),
          is_using_overage: rate_limit_info
            .get("is_using_overage")
            .and_then(Value::as_bool),
          overage_status: rate_limit_info
            .get("overage_status")
            .and_then(Value::as_str)
            .map(String::from),
          surpassed_threshold: rate_limit_info
            .get("surpassed_threshold")
            .and_then(Value::as_f64),
        },
      })]
    }
    "prompt_suggestion" => {
      let suggestion = raw
        .get("suggestion")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

      if suggestion.is_empty() {
        vec![]
      } else {
        vec![state_output(ConnectorStateEvent::PromptSuggestion {
          suggestion,
        })]
      }
    }
    "keep_alive" | "auth_status" => vec![],
    _ => {
      warn!(
        component = "claude_connector",
        event = "claude.stdout.unknown_type",
        msg_type = %msg_type,
        "Unknown stdout message type"
      );
      vec![]
    }
  };

  if !turn_start_event.is_empty() {
    turn_start_event.append(&mut events);
    turn_start_event
  } else {
    events
  }
}

/// Handle `assistant` messages — extract content blocks into ConnectorOutput values.
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
    let message_id = tool_use_id.map(str::to_string).unwrap_or_else(|| {
      format!(
        "claude-msg-{}-{}",
        &session_id[..8.min(session_id.len())],
        uuid::Uuid::new_v4()
      )
    });

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

    let content = tool_result_content(&block);
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
          &mut events,
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
        refresh_shell_execution(&mut tool_row, &state.cwd, Some(&content));
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

  for block in text_thinking_blocks {
    let id = format!(
      "claude-msg-{}-{}",
      &session_id[..8.min(session_id.len())],
      uuid::Uuid::new_v4()
    );

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

/// Handle echoed `user` messages — extract tool results.
fn handle_user_message(
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
          &mut events,
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

  events
}

/// Handle `stream_event` — streaming deltas from --include-partial-messages.
pub(crate) fn handle_stream_event(
  raw: &Value,
  session_id: &str,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let mut events = Vec::new();
  let Some(event) = raw.get("event") else {
    return events;
  };

  if event.get("type").and_then(Value::as_str) != Some("content_block_delta") {
    return events;
  }
  let Some(delta) = event.get("delta") else {
    return events;
  };
  if delta.get("type").and_then(Value::as_str) != Some("text_delta") {
    return events;
  }

  if let Some(text) = delta.get("text").and_then(Value::as_str) {
    state.streaming_content.push_str(text);

    if state.streaming_msg_id.is_none() {
      let msg_id = format!(
        "claude-msg-{}-{}",
        &session_id[..8.min(session_id.len())],
        uuid::Uuid::new_v4()
      );
      let row = ConversationRow::Assistant(MessageRowContent {
        id: msg_id.clone(),
        content: state.streaming_content.clone(),
        turn_id: None,
        timestamp: Some(now_iso()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      });
      events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
        make_entry(session_id, row),
      )));
      state.streaming_msg_id = Some(msg_id);
      state.streaming_last_broadcast = Some(Instant::now());
    } else {
      let now = Instant::now();
      if state
        .streaming_last_broadcast
        .is_some_and(|last| now.duration_since(last).as_millis() < CLAUDE_STREAM_THROTTLE_MS)
      {
        return events;
      }
      state.streaming_last_broadcast = Some(now);

      let msg_id = match state.streaming_msg_id.clone() {
        Some(msg_id) => msg_id,
        None => {
          warn!(
            component = "claude_connector",
            event = "claude.stream_event.missing_streaming_msg_id",
            session_id = %session_id,
            "Received streaming delta without an active streaming row; creating a replacement row"
          );
          let msg_id = format!(
            "claude-msg-{}-{}",
            &session_id[..8.min(session_id.len())],
            uuid::Uuid::new_v4()
          );
          state.streaming_msg_id = Some(msg_id.clone());
          let row = ConversationRow::Assistant(MessageRowContent {
            id: msg_id.clone(),
            content: state.streaming_content.clone(),
            turn_id: None,
            timestamp: Some(now_iso()),
            is_streaming: true,
            images: vec![],
            memory_citation: None,
            delivery_status: None,
          });
          events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
            make_entry(session_id, row),
          )));
          return events;
        }
      };

      let row = ConversationRow::Assistant(MessageRowContent {
        id: msg_id.clone(),
        content: state.streaming_content.clone(),
        turn_id: None,
        timestamp: Some(now_iso()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      });
      events.push(state_output(ConnectorStateEvent::ConversationRowUpdated {
        row_id: msg_id,
        entry: make_entry(session_id, row),
      }));
    }
  }

  events
}

/// Handle `tool_progress` updates for long-running tool executions.
fn handle_tool_progress(
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

/// Handle `result` messages — turn completed/aborted with usage.
fn handle_result_message(
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

/// Handle `control_request` from the CLI (permission prompts, hook callbacks, MCP messages).
fn finalize_tool_row(
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

fn tool_result_content(block: &Value) -> String {
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

fn value_field<'a>(value: &'a Value, snake_key: &str, camel_key: &str) -> Option<&'a Value> {
  value.get(snake_key).or_else(|| value.get(camel_key))
}

fn string_field(value: &Value, snake_key: &str, camel_key: &str) -> Option<String> {
  value_field(value, snake_key, camel_key)
    .and_then(Value::as_str)
    .map(String::from)
}

/// Flush accumulated streaming content into a final ConversationRowUpdated.
fn flush_streaming(
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

/// Extract a `u64` from an optional JSON value, defaulting to 0.
fn value_to_u64(value: Option<&Value>) -> u64 {
  value.and_then(Value::as_u64).unwrap_or(0)
}
