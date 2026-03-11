use crate::runtime::apply_delta_message;
use crate::timeline::{
    hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
    realtime_text_from_handoff_request, stream_error_should_surface_to_timeline,
};
use crate::workers::iso_now;
use codex_protocol::plan_tool::UpdatePlanArgs;
use codex_protocol::protocol::{
    BackgroundEventEvent, DeprecationNoticeEvent, HookCompletedEvent, HookStartedEvent,
    ModelRerouteEvent, PlanDeltaEvent, RealtimeConversationRealtimeEvent,
    StreamErrorEvent, ThreadNameUpdatedEvent, ThreadRolledBackEvent, TokenCountEvent,
    TurnDiffEvent, UndoCompletedEvent, UndoStartedEvent, WarningEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub(crate) fn handle_token_count(event: TokenCountEvent) -> Vec<ConnectorEvent> {
    if let Some(info) = event.info {
        let last = &info.last_token_usage;
        let usage = orbitdock_protocol::TokenUsage {
            input_tokens: last.input_tokens.max(0) as u64,
            output_tokens: last.output_tokens.max(0) as u64,
            cached_tokens: last.cached_input_tokens.max(0) as u64,
            context_window: info.model_context_window.unwrap_or(200_000).max(0) as u64,
        };
        vec![ConnectorEvent::TokensUpdated {
            usage,
            snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::ContextTurn,
        }]
    } else {
        vec![]
    }
}

pub(crate) fn handle_turn_diff(event: TurnDiffEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::DiffUpdated(event.unified_diff)]
}

pub(crate) fn handle_plan_update(
    event_id: &str,
    event: UpdatePlanArgs,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let plan = serde_json::to_string(&event).unwrap_or_default();
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let explanation = event.explanation.as_deref().map(str::trim);
    let explanation = match explanation {
        Some(value) if !value.is_empty() => value,
        _ => "Plan updated",
    };
    let content = format!("{} ({} steps)", explanation, event.plan.len());
    let message = orbitdock_protocol::Message {
        id: format!("update-plan-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content,
        tool_name: Some("update_plan".to_string()),
        tool_input: serde_json::to_string(&event).ok(),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![
        ConnectorEvent::PlanUpdated(plan),
        ConnectorEvent::MessageCreated(message),
    ]
}

pub(crate) async fn handle_plan_delta(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    event: PlanDeltaEvent,
) -> Vec<ConnectorEvent> {
    apply_delta_message(
        delta_buffers,
        format!("plan-{}", event.item_id),
        event.delta,
        orbitdock_protocol::MessageType::Thinking,
        None,
    )
    .await
}

pub(crate) fn handle_warning(
    event_id: &str,
    event: WarningEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let message = orbitdock_protocol::Message {
        id: format!("warning-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Assistant,
        content: event.message,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) async fn handle_model_reroute(
    event_id: &str,
    event: ModelRerouteEvent,
    current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    {
        let mut model = current_model.lock().await;
        *model = Some(event.to_model.clone());
    }
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let reason = format!("{:?}", event.reason);
    let message = orbitdock_protocol::Message {
        id: format!("model-reroute-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Assistant,
        content: format!(
            "Model rerouted from {} to {} ({})",
            event.from_model, event.to_model, reason
        ),
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) fn handle_realtime_conversation_started() -> Vec<ConnectorEvent> {
    vec![]
}

pub(crate) fn handle_realtime_conversation_realtime(
    event_id: &str,
    event: RealtimeConversationRealtimeEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    match event.payload {
        codex_protocol::protocol::RealtimeEvent::SessionUpdated { .. }
        | codex_protocol::protocol::RealtimeEvent::InputTranscriptDelta(_)
        | codex_protocol::protocol::RealtimeEvent::OutputTranscriptDelta(_)
        | codex_protocol::protocol::RealtimeEvent::ConversationItemDone { .. } => vec![],
        codex_protocol::protocol::RealtimeEvent::HandoffRequested(handoff) => {
            let Some(content) = realtime_text_from_handoff_request(&handoff) else {
                return vec![];
            };
            let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
            let message = orbitdock_protocol::Message {
                id: format!("realtime-handoff-{}-{}", event_id, seq),
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Tool,
                content,
                tool_name: Some("handoff".to_string()),
                tool_input: serde_json::to_string(&handoff).ok(),
                tool_output: None,
                is_error: false,
                is_in_progress: false,
                timestamp: iso_now(),
                duration_ms: None,
                images: vec![],
            };
            vec![ConnectorEvent::MessageCreated(message)]
        }
        codex_protocol::protocol::RealtimeEvent::ConversationItemAdded(_) => vec![],
        codex_protocol::protocol::RealtimeEvent::AudioOut(_) => vec![],
        codex_protocol::protocol::RealtimeEvent::Error(message_text) => {
            let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
            let message = orbitdock_protocol::Message {
                id: format!("realtime-error-{}-{}", event_id, seq),
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Assistant,
                content: format!("Realtime conversation error: {}", message_text),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: true,
                is_in_progress: false,
                timestamp: iso_now(),
                duration_ms: None,
                images: vec![],
            };
            vec![ConnectorEvent::MessageCreated(message)]
        }
    }
}

pub(crate) fn handle_realtime_conversation_closed() -> Vec<ConnectorEvent> {
    vec![]
}

pub(crate) fn handle_deprecation_notice(
    event_id: &str,
    event: DeprecationNoticeEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let details = event.details.unwrap_or_default();
    let content = if details.is_empty() {
        event.summary
    } else {
        format!("{}\n\n{}", event.summary, details)
    };
    let message = orbitdock_protocol::Message {
        id: format!("deprecation-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Assistant,
        content,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) fn handle_background_event(
    event_id: &str,
    event: BackgroundEventEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let message = orbitdock_protocol::Message {
        id: format!("background-event-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Assistant,
        content: event.message,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) fn handle_hook_started(event: HookStartedEvent) -> Vec<ConnectorEvent> {
    let message = orbitdock_protocol::Message {
        id: format!("hook-{}", event.run.id),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: hook_started_text(&event.run),
        tool_name: Some("hook".to_string()),
        tool_input: serde_json::to_string(&event.run).ok(),
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) fn handle_hook_completed(event: HookCompletedEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::MessageUpdated {
        message_id: format!("hook-{}", event.run.id),
        content: Some(hook_completed_text(&event.run)),
        tool_output: hook_output_text(&event.run),
        is_error: Some(hook_run_is_error(event.run.status)),
        is_in_progress: Some(false),
        duration_ms: event.run.duration_ms.and_then(|ms| u64::try_from(ms).ok()),
    }]
}

pub(crate) fn handle_thread_name_updated(event: ThreadNameUpdatedEvent) -> Vec<ConnectorEvent> {
    event
        .thread_name
        .map(ConnectorEvent::ThreadNameUpdated)
        .into_iter()
        .collect()
}

pub(crate) fn handle_shutdown_complete() -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::SessionEnded {
        reason: "shutdown".to_string(),
    }]
}

pub(crate) fn handle_error(message: String) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::Error(message)]
}

pub(crate) fn handle_stream_error(
    event_id: &str,
    event: StreamErrorEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
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
    let message = orbitdock_protocol::Message {
        id: format!("stream-error-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Assistant,
        content,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: true,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) fn handle_context_compacted() -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::ContextCompacted]
}

pub(crate) fn handle_undo_started(event: UndoStartedEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::UndoStarted {
        message: event.message,
    }]
}

pub(crate) fn handle_undo_completed(event: UndoCompletedEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::UndoCompleted {
        success: event.success,
        message: event.message,
    }]
}

pub(crate) fn handle_thread_rolled_back(event: ThreadRolledBackEvent) -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::ThreadRolledBack {
        num_turns: event.num_turns,
    }]
}

pub(crate) fn handle_skills_update_available() -> Vec<ConnectorEvent> {
    vec![ConnectorEvent::SkillsUpdateAvailable]
}
