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

use crate::rows::{make_entry, now_iso};
use orbitdock_connector_core::{
  panic_payload_message, ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent,
  ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent, ToolRow};

mod control;
mod helpers;
mod messages;
mod system;

pub(crate) use control::{handle_cli_control_request, handle_control_response, PendingApproval};
use helpers::string_field;
pub(crate) use messages::handle_assistant_message;
use messages::{handle_result_message, handle_tool_progress, handle_user_message};
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
