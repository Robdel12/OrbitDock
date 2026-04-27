use codex_app_server_protocol::{ServerNotification, TurnStatus};
use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, HookRow, MessageRowContent, NoticeRow, NoticeRowKind, NoticeRowSeverity,
};
use orbitdock_protocol::domain_events::{HookOutputEntry, HookPayload};
use orbitdock_protocol::{TokenUsage, TokenUsageSnapshotKind};
use tracing::{debug, warn};

use super::item_mapping::{
  guardian_review_tool_row, map_item, map_terminal_interaction, output_buffer_key, tool_row_outputs,
};
use super::response_codec::request_key;
use super::AppServerSessionRoute;
use crate::row_mapping::{row_created_output, row_updated_output, state_output};
use crate::runtime::{apply_delta_thinking, row_entry, StreamingMessage, STREAM_THROTTLE_MS};
use crate::timeline::is_thread_start_skills_trimmed_warning;
use crate::workers::iso_now;

pub(crate) async fn map_notification(
  notification: ServerNotification,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  match notification {
    ServerNotification::TurnStarted(event) => {
      *route.active_turn_id.lock().await = Some(event.turn.id.clone());
      vec![state_output(ConnectorStateEvent::TurnStarted)]
    }
    ServerNotification::HookStarted(event) => map_hook_started(event),
    ServerNotification::TurnCompleted(event) => {
      *route.active_turn_id.lock().await = None;
      match event.turn.status {
        TurnStatus::Completed => vec![state_output(ConnectorStateEvent::TurnCompleted)],
        TurnStatus::Interrupted => vec![state_output(ConnectorStateEvent::TurnAborted {
          reason: "interrupted".to_string(),
        })],
        TurnStatus::Failed => vec![state_output(ConnectorStateEvent::TurnAborted {
          reason: event
            .turn
            .error
            .map(|error| error.message)
            .unwrap_or_else(|| "failed".to_string()),
        })],
        TurnStatus::InProgress => Vec::new(),
      }
    }
    ServerNotification::HookCompleted(event) => map_hook_completed(event),
    ServerNotification::ThreadStatusChanged(_) => Vec::new(),
    ServerNotification::ThreadClosed(_) => vec![state_output(ConnectorStateEvent::SessionEnded {
      reason: "closed".to_string(),
    })],
    ServerNotification::ThreadNameUpdated(event) => event
      .thread_name
      .map(|name| vec![state_output(ConnectorStateEvent::ThreadNameUpdated(name))])
      .unwrap_or_default(),
    ServerNotification::ThreadTokenUsageUpdated(event) => map_token_usage(event.token_usage),
    ServerNotification::TurnDiffUpdated(event) => {
      vec![state_output(ConnectorStateEvent::DiffUpdated(event.diff))]
    }
    ServerNotification::TurnPlanUpdated(event) => {
      let mut text = String::new();
      if let Some(explanation) = event.explanation.filter(|value| !value.trim().is_empty()) {
        text.push_str(&explanation);
        text.push_str("\n\n");
      }
      for step in event.plan {
        text.push_str("- [");
        text.push_str(match step.status {
          codex_app_server_protocol::TurnPlanStepStatus::Completed => "x",
          _ => " ",
        });
        text.push_str("] ");
        text.push_str(&step.step);
        text.push('\n');
      }
      if text.trim().is_empty() {
        Vec::new()
      } else {
        vec![state_output(ConnectorStateEvent::PlanUpdated(text))]
      }
    }
    ServerNotification::AgentMessageDelta(event) => {
      map_agent_message_delta(event.item_id, event.delta, route).await
    }
    ServerNotification::PlanDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!("plan-{}", event.item_id),
        event.delta,
      )
      .await
    }
    ServerNotification::ReasoningSummaryTextDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!(
          "reasoning-summary-{}-{}",
          event.item_id, event.summary_index
        ),
        event.delta,
      )
      .await
    }
    ServerNotification::ReasoningTextDelta(event) => {
      apply_delta_thinking(
        &route.state.delta_buffers,
        format!("reasoning-raw-{}-{}", event.item_id, event.content_index),
        event.delta,
      )
      .await
    }
    ServerNotification::ItemStarted(event) => map_item(event.item, true, route).await,
    ServerNotification::ItemGuardianApprovalReviewStarted(event) => {
      let row_id = format!("guardian-{}", event.review_id);
      tool_row_outputs(
        row_id,
        guardian_review_tool_row(
          event.review_id,
          event.turn_id,
          event.target_item_id,
          event.review,
          event.action,
          true,
        ),
        true,
      )
    }
    ServerNotification::ItemGuardianApprovalReviewCompleted(event) => {
      let row_id = format!("guardian-{}", event.review_id);
      tool_row_outputs(
        row_id,
        guardian_review_tool_row(
          event.review_id,
          event.turn_id,
          event.target_item_id,
          event.review,
          event.action,
          false,
        ),
        false,
      )
    }
    ServerNotification::ItemCompleted(event) => map_item(event.item, false, route).await,
    ServerNotification::ReasoningSummaryPartAdded(_) => Vec::new(),
    ServerNotification::CommandExecutionOutputDelta(event) => {
      let mut buffers = route.state.delta_buffers.lock().await;
      buffers
        .entry(output_buffer_key("command", &event.item_id))
        .or_default()
        .push_str(&event.delta);
      vec![ConnectorOutput::Transport(
        ConnectorTransportEffect::ToolPtyOutput {
          tool_id: event.item_id,
          bytes: event.delta.into_bytes(),
        },
      )]
    }
    ServerNotification::TerminalInteraction(event) => map_terminal_interaction(event),
    ServerNotification::FileChangeOutputDelta(event) => {
      let mut buffers = route.state.delta_buffers.lock().await;
      buffers
        .entry(output_buffer_key("file-change", &event.item_id))
        .or_default()
        .push_str(&event.delta);
      Vec::new()
    }
    ServerNotification::ServerRequestResolved(event) => {
      let key = request_key(&event.request_id);
      route.pending_requests.lock().await.remove(&key);
      vec![state_output(ConnectorStateEvent::ApprovalCancelled {
        request_id: key,
      })]
    }
    ServerNotification::SkillsChanged(_) => {
      vec![state_output(ConnectorStateEvent::SkillsUpdateAvailable)]
    }
    ServerNotification::McpServerStatusUpdated(event) => {
      vec![state_output(ConnectorStateEvent::McpStartupUpdate {
        server: event.name,
        status: match event.status {
          codex_app_server_protocol::McpServerStartupState::Starting => {
            orbitdock_protocol::McpStartupStatus::Starting
          }
          codex_app_server_protocol::McpServerStartupState::Ready => {
            orbitdock_protocol::McpStartupStatus::Ready
          }
          codex_app_server_protocol::McpServerStartupState::Failed => {
            orbitdock_protocol::McpStartupStatus::Failed {
              error: event
                .error
                .unwrap_or_else(|| "MCP server failed".to_string()),
            }
          }
          codex_app_server_protocol::McpServerStartupState::Cancelled => {
            orbitdock_protocol::McpStartupStatus::Cancelled
          }
        },
      })]
    }
    ServerNotification::Error(event) => {
      let mut outputs = vec![state_output(ConnectorStateEvent::Error(
        event.error.message.clone(),
      ))];
      if !event.will_retry {
        outputs.push(state_output(ConnectorStateEvent::TurnAborted {
          reason: event.error.message,
        }));
      }
      outputs
    }
    ServerNotification::ContextCompacted(_) => {
      vec![state_output(ConnectorStateEvent::ContextCompacted)]
    }
    ServerNotification::ModelRerouted(event) => {
      let content = format!(
        "Model rerouted from {} to {} ({:?})",
        event.from_model, event.to_model, event.reason
      );
      vec![row_created_output(row_entry(ConversationRow::System(
        MessageRowContent {
          id: format!("model-reroute-{}", event.turn_id),
          content,
          turn_id: Some(event.turn_id),
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ServerNotification::Warning(event) => map_warning(event.message),
    other => {
      debug!(notification = ?other, "Unhandled Codex app-server notification");
      Vec::new()
    }
  }
}

async fn map_agent_message_delta(
  item_id: String,
  delta: String,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  let mut streaming = route.state.streaming_message.lock().await;
  match streaming.as_mut() {
    None => {
      let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: item_id.clone(),
        content: delta.clone(),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      *streaming = Some(StreamingMessage {
        message_id: item_id,
        content: delta,
        last_broadcast: std::time::Instant::now(),
      });
      vec![row_created_output(entry)]
    }
    Some(streaming_msg) => {
      streaming_msg.content.push_str(&delta);
      let now = std::time::Instant::now();
      if now.duration_since(streaming_msg.last_broadcast).as_millis() >= STREAM_THROTTLE_MS {
        streaming_msg.last_broadcast = now;
        let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
          id: streaming_msg.message_id.clone(),
          content: streaming_msg.content.clone(),
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: true,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        }));
        vec![row_updated_output(streaming_msg.message_id.clone(), entry)]
      } else {
        Vec::new()
      }
    }
  }
}

fn map_hook_started(
  event: codex_app_server_protocol::HookStartedNotification,
) -> Vec<ConnectorOutput> {
  if !hook_run_is_error(event.run.status) {
    return Vec::new();
  }
  vec![row_created_output(row_entry(ConversationRow::Hook(
    hook_row(event.run, "started"),
  )))]
}

fn map_hook_completed(
  event: codex_app_server_protocol::HookCompletedNotification,
) -> Vec<ConnectorOutput> {
  if !hook_run_is_error(event.run.status) {
    return Vec::new();
  }
  let row_id = format!("hook-{}", event.run.id);
  vec![row_updated_output(
    row_id,
    row_entry(ConversationRow::Hook(hook_row(event.run, "completed"))),
  )]
}

fn hook_row(run: codex_app_server_protocol::HookRunSummary, phase: &str) -> HookRow {
  let output = hook_output_text(&run);
  HookRow {
    id: format!("hook-{}", run.id),
    title: hook_title(&run),
    subtitle: Some(format!("{:?}", run.event_name)),
    summary: output.clone(),
    payload: HookPayload {
      hook_name: Some(format!("{:?}", run.handler_type)),
      event_name: Some(format!("{:?}", run.event_name)),
      phase: Some(phase.to_string()),
      status: Some(format!("{:?}", run.status)),
      source_path: Some(run.source_path.display().to_string()),
      source: Some(format!("{:?}", run.source)),
      summary: output.clone(),
      output,
      duration_ms: duration_millis(run.duration_ms),
      entries: run
        .entries
        .into_iter()
        .map(|entry| HookOutputEntry {
          kind: Some(format!("{:?}", entry.kind)),
          label: None,
          value: Some(entry.text),
        })
        .collect(),
    },
    render_hints: Default::default(),
  }
}

fn hook_title(run: &codex_app_server_protocol::HookRunSummary) -> String {
  match run.status {
    codex_app_server_protocol::HookRunStatus::Running => {
      format!("Hook running: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Failed => {
      format!("Hook failed: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Blocked => {
      format!("Hook blocked: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Stopped => {
      format!("Hook stopped: {:?}", run.event_name)
    }
    codex_app_server_protocol::HookRunStatus::Completed => {
      format!("Hook completed: {:?}", run.event_name)
    }
  }
}

fn hook_run_is_error(status: codex_app_server_protocol::HookRunStatus) -> bool {
  matches!(
    status,
    codex_app_server_protocol::HookRunStatus::Failed
      | codex_app_server_protocol::HookRunStatus::Blocked
      | codex_app_server_protocol::HookRunStatus::Stopped
  )
}

fn hook_output_text(run: &codex_app_server_protocol::HookRunSummary) -> Option<String> {
  let mut entries = run
    .entries
    .iter()
    .map(|entry| entry.text.trim())
    .filter(|text| !text.is_empty())
    .map(ToOwned::to_owned)
    .collect::<Vec<_>>();
  if let Some(message) = run
    .status_message
    .as_deref()
    .map(str::trim)
    .filter(|value| !value.is_empty())
  {
    entries.insert(0, message.to_string());
  }
  (!entries.is_empty()).then(|| entries.join("\n"))
}

pub(crate) fn map_warning(message: String) -> Vec<ConnectorOutput> {
  if is_suppressed_runtime_warning(&message) {
    warn!(
      message = %message,
      "suppressing Codex app-server runtime warning from timeline"
    );
    return Vec::new();
  }
  let (title, summary, severity) = runtime_warning_notice_copy(&message);
  vec![row_created_output(row_entry(ConversationRow::Notice(
    NoticeRow {
      id: runtime_warning_notice_id(&message),
      kind: NoticeRowKind::Generic,
      severity,
      title,
      summary,
      body: Some(message),
      render_hints: Default::default(),
    },
  )))]
}

fn runtime_warning_notice_id(message: &str) -> String {
  if is_thread_start_skills_trimmed_warning(message) {
    "warning-thread-start-skills-trimmed".to_string()
  } else {
    format!("warning-{}", stable_hash(message))
  }
}

fn runtime_warning_notice_copy(message: &str) -> (String, Option<String>, NoticeRowSeverity) {
  if is_thread_start_skills_trimmed_warning(message) {
    return (
      "Some skills are outside the model-visible list".to_string(),
      Some("Mention a skill by name or path if Codex needs it.".to_string()),
      NoticeRowSeverity::Info,
    );
  }
  (
    "Codex warning".to_string(),
    Some(message.to_string()),
    NoticeRowSeverity::Warning,
  )
}

fn is_suppressed_runtime_warning(message: &str) -> bool {
  is_thread_start_skills_trimmed_warning(message)
    || (message.starts_with("Model metadata for `")
      && message.contains("Defaulting to fallback metadata"))
    || (message.starts_with("Under-development features enabled:")
      && message.contains("codex_hooks"))
}

fn stable_hash(value: &str) -> u64 {
  let mut hash = 0xcbf29ce484222325u64;
  for byte in value.as_bytes() {
    hash ^= u64::from(*byte);
    hash = hash.wrapping_mul(0x100000001b3);
  }
  hash
}

pub(crate) fn map_token_usage(
  usage: codex_app_server_protocol::ThreadTokenUsage,
) -> Vec<ConnectorOutput> {
  let live = TokenUsage {
    input_tokens: usage.last.input_tokens.max(0) as u64,
    output_tokens: usage.last.output_tokens.max(0) as u64,
    cached_tokens: usage.last.cached_input_tokens.max(0) as u64,
    context_window: usage.model_context_window.unwrap_or_default().max(0) as u64,
  };
  let accounting = TokenUsage {
    input_tokens: usage.total.input_tokens.max(0) as u64,
    output_tokens: usage.total.output_tokens.max(0) as u64,
    cached_tokens: usage.total.cached_input_tokens.max(0) as u64,
    context_window: usage.model_context_window.unwrap_or_default().max(0) as u64,
  };

  vec![
    state_output(ConnectorStateEvent::TokensUpdated {
      usage: live,
      snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
    }),
    state_output(ConnectorStateEvent::TurnUsageUpdated {
      usage: accounting,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    }),
  ]
}

fn duration_millis(value: Option<i64>) -> Option<u64> {
  value.and_then(|inner| u64::try_from(inner).ok())
}
