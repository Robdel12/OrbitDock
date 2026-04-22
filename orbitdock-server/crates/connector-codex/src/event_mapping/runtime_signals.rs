use super::{row_created_output, state_output, tool_row_entry, ConnectorOutputs};
use crate::runtime::{apply_delta_thinking, row_entry};
use crate::timeline::{
  hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
  is_thread_start_skills_trimmed_warning, realtime_text_from_handoff_request,
  stream_error_should_surface_to_timeline,
};
use crate::workers::iso_now;
use codex_protocol::plan_tool::UpdatePlanArgs;
use codex_protocol::protocol::{
  BackgroundEventEvent, DeprecationNoticeEvent, HookCompletedEvent, HookSource, HookStartedEvent,
  ModelRerouteEvent, PlanDeltaEvent, RealtimeConversationRealtimeEvent, StreamErrorEvent,
  ThreadNameUpdatedEvent, ThreadRolledBackEvent, TokenCountEvent, TurnDiffEvent,
  UndoCompletedEvent, UndoStartedEvent, WarningEvent,
};
use orbitdock_connector_core::ConnectorStateEvent;
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, HandoffRow, HookRow, MessageRowContent, NoticeRow, NoticeRowKind,
  NoticeRowSeverity, RenderHints, ToolRow,
};
use orbitdock_protocol::domain_events::{
  HandoffPayload, HookPayload, PlanStepPayload, PlanStepStatus, ToolFamily, ToolKind, ToolStatus,
};
use orbitdock_protocol::Provider;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tracing::warn;

pub(crate) fn handle_token_count(event: TokenCountEvent) -> ConnectorOutputs {
  if let Some(info) = event.info {
    let last = &info.last_token_usage;
    let context_window = info.model_context_window.unwrap_or(200_000).max(0) as u64;
    let live_usage = orbitdock_protocol::TokenUsage {
      input_tokens: last.input_tokens.max(0) as u64,
      output_tokens: last.output_tokens.max(0) as u64,
      cached_tokens: last.cached_input_tokens.max(0) as u64,
      context_window,
    };
    let total = &info.total_token_usage;
    let accounting_usage = orbitdock_protocol::TokenUsage {
      input_tokens: total.input_tokens.max(0) as u64,
      output_tokens: total.output_tokens.max(0) as u64,
      cached_tokens: total.cached_input_tokens.max(0) as u64,
      context_window,
    };
    vec![
      state_output(ConnectorStateEvent::TokensUpdated {
        usage: live_usage,
        snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::ContextTurn,
      }),
      state_output(ConnectorStateEvent::TurnUsageUpdated {
        usage: accounting_usage,
        snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::LifetimeTotals,
      }),
    ]
  } else {
    vec![]
  }
}

pub(crate) fn handle_turn_diff(event: TurnDiffEvent) -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::DiffUpdated(
    event.unified_diff,
  ))]
}

pub(crate) fn handle_plan_update(
  event_id: &str,
  event: UpdatePlanArgs,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  let plan = serde_json::to_string(&event).unwrap_or_default();
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let explanation = event.explanation.as_deref().map(str::trim);
  let explanation = match explanation {
    Some(value) if !value.is_empty() => value,
    _ => "Plan updated",
  };
  let content = format!("{} ({} steps)", explanation, event.plan.len());
  let steps_json: Vec<serde_json::Value> = event
    .plan
    .iter()
    .map(|step| {
      serde_json::to_value(PlanStepPayload {
        id: None,
        title: step.step.clone(),
        status: PlanStepStatus::Pending,
        detail: None,
      })
      .unwrap_or_default()
    })
    .collect();

  let row = ToolRow {
    id: format!("update-plan-{}-{}", event_id, seq),
    provider: Provider::Codex,
    family: ToolFamily::Plan,
    kind: ToolKind::UpdatePlan,
    status: ToolStatus::Completed,
    title: content,
    subtitle: None,
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "mode": "plan",
        "summary": event.explanation,
        "steps": steps_json,
        "explanation": event.explanation,
    }),
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };
  vec![
    state_output(ConnectorStateEvent::PlanUpdated(plan)),
    row_created_output(tool_row_entry(row)),
  ]
}

pub(crate) async fn handle_plan_delta(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  event: PlanDeltaEvent,
) -> ConnectorOutputs {
  apply_delta_thinking(
    delta_buffers,
    format!("plan-{}", event.item_id),
    event.delta,
  )
  .await
}

pub(crate) fn handle_warning(
  event_id: &str,
  event: WarningEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  if is_suppressed_runtime_warning(&event.message) {
    warn!(
      event_id,
      message = %event.message,
      "suppressing Codex runtime warning from timeline"
    );
    return vec![];
  }
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let entry = row_entry(ConversationRow::Notice(runtime_warning_notice_row(
    event_id,
    seq,
    event.message,
  )));
  vec![row_created_output(entry)]
}

fn runtime_warning_notice_row(event_id: &str, seq: u64, message: String) -> NoticeRow {
  let (title, summary, severity) = runtime_warning_notice_copy(&message);
  NoticeRow {
    id: format!("warning-{}-{}", event_id, seq),
    kind: NoticeRowKind::Generic,
    severity,
    title,
    summary,
    body: Some(message),
    render_hints: RenderHints {
      can_expand: true,
      default_expanded: false,
      emphasized: false,
      monospace_summary: false,
      accent_tone: Some("notice".to_string()),
    },
  }
}

fn runtime_warning_notice_copy(message: &str) -> (String, Option<String>, NoticeRowSeverity) {
  (
    "Codex warning".to_string(),
    Some(message.to_string()),
    NoticeRowSeverity::Warning,
  )
}

pub(crate) fn is_suppressed_runtime_warning(message: &str) -> bool {
  is_thread_start_skills_trimmed_warning(message)
    || (message.starts_with("Model metadata for `")
      && message.contains("Defaulting to fallback metadata"))
    || (message.starts_with("Under-development features enabled:")
      && message.contains("codex_hooks"))
}

pub(crate) async fn handle_model_reroute(
  event_id: &str,
  event: ModelRerouteEvent,
  current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  {
    let mut model = current_model.lock().await;
    *model = Some(event.to_model.clone());
  }
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let reason = format!("{:?}", event.reason);
  let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
    id: format!("model-reroute-{}-{}", event_id, seq),
    content: format!(
      "Model rerouted from {} to {} ({})",
      event.from_model, event.to_model, reason
    ),
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }));
  vec![row_created_output(entry)]
}

pub(crate) fn handle_realtime_conversation_started() -> ConnectorOutputs {
  vec![]
}

pub(crate) fn handle_realtime_conversation_realtime(
  event_id: &str,
  event: RealtimeConversationRealtimeEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  match event.payload {
    codex_protocol::protocol::RealtimeEvent::SessionUpdated { .. }
    | codex_protocol::protocol::RealtimeEvent::InputAudioSpeechStarted(_)
    | codex_protocol::protocol::RealtimeEvent::InputTranscriptDelta(_)
    | codex_protocol::protocol::RealtimeEvent::InputTranscriptDone(_)
    | codex_protocol::protocol::RealtimeEvent::OutputTranscriptDelta(_)
    | codex_protocol::protocol::RealtimeEvent::OutputTranscriptDone(_)
    | codex_protocol::protocol::RealtimeEvent::ResponseCreated(_)
    | codex_protocol::protocol::RealtimeEvent::ResponseCancelled(_)
    | codex_protocol::protocol::RealtimeEvent::ResponseDone(_)
    | codex_protocol::protocol::RealtimeEvent::ConversationItemDone { .. } => vec![],
    codex_protocol::protocol::RealtimeEvent::HandoffRequested(handoff) => {
      let Some(content) = realtime_text_from_handoff_request(&handoff) else {
        return vec![];
      };
      let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
      let entry = row_entry(ConversationRow::Handoff(HandoffRow {
        id: format!("realtime-handoff-{}-{}", event_id, seq),
        title: "Handoff requested".to_string(),
        subtitle: None,
        summary: Some(content),
        payload: HandoffPayload {
          target: None,
          summary: serde_json::to_string(&handoff).ok(),
          body: None,
          transcript_excerpt: None,
        },
        render_hints: Default::default(),
      }));
      vec![row_created_output(entry)]
    }
    codex_protocol::protocol::RealtimeEvent::ConversationItemAdded(_) => vec![],
    codex_protocol::protocol::RealtimeEvent::AudioOut(_) => vec![],
    codex_protocol::protocol::RealtimeEvent::Error(message_text) => {
      let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
      let entry = row_entry(ConversationRow::System(MessageRowContent {
        id: format!("realtime-error-{}-{}", event_id, seq),
        content: format!("Realtime conversation error: {}", message_text),
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }));
      vec![row_created_output(entry)]
    }
  }
}

pub(crate) fn handle_realtime_conversation_closed() -> ConnectorOutputs {
  vec![]
}

pub(crate) fn handle_deprecation_notice(
  event_id: &str,
  event: DeprecationNoticeEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let details = event.details.unwrap_or_default();
  let content = if details.is_empty() {
    event.summary
  } else {
    format!("{}\n\n{}", event.summary, details)
  };
  let entry = row_entry(ConversationRow::System(MessageRowContent {
    id: format!("deprecation-{}-{}", event_id, seq),
    content,
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }));
  vec![row_created_output(entry)]
}

pub(crate) fn handle_background_event(
  event_id: &str,
  event: BackgroundEventEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
    id: format!("background-event-{}-{}", event_id, seq),
    content: event.message,
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }));
  vec![row_created_output(entry)]
}

pub(crate) fn handle_hook_started(event: HookStartedEvent) -> ConnectorOutputs {
  if !hook_run_is_error(event.run.status) {
    return vec![];
  }

  let entry = row_entry(ConversationRow::Hook(HookRow {
    id: format!("hook-{}", event.run.id),
    title: hook_started_text(&event.run),
    subtitle: None,
    summary: None,
    payload: HookPayload {
      hook_name: Some(format!("{:?}", event.run.event_name)),
      event_name: Some(format!("{:?}", event.run.event_name)),
      phase: Some("started".to_string()),
      status: Some(format!("{:?}", event.run.status)),
      source_path: Some(event.run.source_path.display().to_string()),
      source: Some(hook_source_value(event.run.source)),
      summary: None,
      output: None,
      duration_ms: None,
      entries: vec![],
    },
    render_hints: Default::default(),
  }));
  vec![row_created_output(entry)]
}

pub(crate) fn handle_hook_completed(event: HookCompletedEvent) -> ConnectorOutputs {
  if !hook_run_is_error(event.run.status) {
    return vec![];
  }

  let entry = row_entry(ConversationRow::Hook(HookRow {
    id: format!("hook-{}", event.run.id),
    title: hook_completed_text(&event.run),
    subtitle: None,
    summary: hook_output_text(&event.run),
    payload: HookPayload {
      hook_name: Some(format!("{:?}", event.run.event_name)),
      event_name: Some(format!("{:?}", event.run.event_name)),
      phase: Some("completed".to_string()),
      status: Some(format!("{:?}", event.run.status)),
      source_path: Some(event.run.source_path.display().to_string()),
      source: Some(hook_source_value(event.run.source)),
      summary: hook_output_text(&event.run),
      output: hook_output_text(&event.run),
      duration_ms: event.run.duration_ms.and_then(|ms| u64::try_from(ms).ok()),
      entries: event
        .run
        .entries
        .iter()
        .map(|e| orbitdock_protocol::domain_events::HookOutputEntry {
          kind: Some(format!("{:?}", e.kind)),
          label: None,
          value: Some(e.text.clone()),
        })
        .collect(),
    },
    render_hints: Default::default(),
  }));
  vec![row_created_output(entry)]
}

fn hook_source_value(source: HookSource) -> String {
  match source {
    HookSource::System => "system",
    HookSource::User => "user",
    HookSource::Project => "project",
    HookSource::Mdm => "mdm",
    HookSource::SessionFlags => "session_flags",
    HookSource::LegacyManagedConfigFile => "legacy_managed_config_file",
    HookSource::LegacyManagedConfigMdm => "legacy_managed_config_mdm",
    HookSource::Unknown => "unknown",
  }
  .to_string()
}

pub(crate) fn handle_thread_name_updated(event: ThreadNameUpdatedEvent) -> ConnectorOutputs {
  match event.thread_name {
    Some(thread_name) => vec![state_output(ConnectorStateEvent::ThreadNameUpdated(
      thread_name,
    ))],
    None => vec![],
  }
}

pub(crate) fn handle_shutdown_complete() -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::SessionEnded {
    reason: "shutdown".to_string(),
  })]
}

pub(crate) fn handle_error(message: String) -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::Error(message))]
}

pub(crate) fn handle_stream_error(
  event_id: &str,
  event: StreamErrorEvent,
  msg_counter: &AtomicU64,
) -> ConnectorOutputs {
  if !stream_error_should_surface_to_timeline(&event) {
    return vec![];
  }

  let details = event.additional_details.unwrap_or_default();
  let content = if details.is_empty() {
    event.message
  } else {
    format!("{}\n\n{}", event.message, details)
  };
  let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
  let entry = row_entry(ConversationRow::System(MessageRowContent {
    id: format!("stream-error-{}-{}", event_id, seq),
    content,
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }));
  vec![row_created_output(entry)]
}

pub(crate) fn handle_context_compacted() -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::ContextCompacted)]
}

pub(crate) fn handle_undo_started(event: UndoStartedEvent) -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::UndoStarted {
    message: event.message,
  })]
}

pub(crate) fn handle_undo_completed(event: UndoCompletedEvent) -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::UndoCompleted {
    success: event.success,
    message: event.message,
  })]
}

pub(crate) fn handle_thread_rolled_back(event: ThreadRolledBackEvent) -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::ThreadRolledBack {
    num_turns: event.num_turns,
  })]
}

pub(crate) fn handle_skills_update_available() -> ConnectorOutputs {
  vec![state_output(ConnectorStateEvent::SkillsUpdateAvailable)]
}
