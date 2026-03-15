use crate::runtime::{apply_delta_thinking, row_entry};
use crate::timeline::{
    hook_completed_text, hook_output_text, hook_started_text, realtime_text_from_handoff_request,
    stream_error_should_surface_to_timeline,
};
use crate::workers::iso_now;
use codex_protocol::plan_tool::UpdatePlanArgs;
use codex_protocol::protocol::{
    BackgroundEventEvent, DeprecationNoticeEvent, HookCompletedEvent, HookStartedEvent,
    ModelRerouteEvent, PlanDeltaEvent, RealtimeConversationRealtimeEvent, StreamErrorEvent,
    ThreadNameUpdatedEvent, ThreadRolledBackEvent, TokenCountEvent, TurnDiffEvent,
    UndoCompletedEvent, UndoStartedEvent, WarningEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
    compute_tool_display, ConversationRow, ConversationRowEntry, HandoffRow, HookRow,
    MessageRowContent, ToolRow,
};
use orbitdock_protocol::domain_events::{
    HandoffPayload, HookPayload, PlanStepPayload, PlanStepStatus, ToolFamily, ToolKind, ToolStatus,
};
use orbitdock_protocol::Provider;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
    let row = with_display(row);
    row_entry(ConversationRow::Tool(row))
}

fn with_display(mut row: ToolRow) -> ToolRow {
    let invocation_ref = if row.invocation.is_object() {
        Some(&row.invocation)
    } else {
        None
    };
    let result_str = row
        .result
        .as_ref()
        .and_then(|v| v.get("output").and_then(|o| o.as_str()))
        .map(String::from);
    row.tool_display = Some(compute_tool_display(
        row.kind,
        row.family,
        row.status,
        &row.title,
        row.subtitle.as_deref(),
        row.summary.as_deref(),
        row.duration_ms,
        invocation_ref,
        result_str.as_deref(),
    ));
    row
}

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

    let steps: Vec<PlanStepPayload> = event
        .plan
        .iter()
        .map(|step| PlanStepPayload {
            id: None,
            title: step.step.clone(),
            status: PlanStepStatus::Pending,
            detail: None,
        })
        .collect();

    let steps_json: Vec<serde_json::Value> = steps
        .iter()
        .map(|step| serde_json::to_value(step).unwrap_or_default())
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
    };
    vec![
        ConnectorEvent::PlanUpdated(plan),
        ConnectorEvent::ConversationRowCreated(tool_row_entry(row)),
    ]
}

pub(crate) async fn handle_plan_delta(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    event: PlanDeltaEvent,
) -> Vec<ConnectorEvent> {
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
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: format!("warning-{}-{}", event_id, seq),
        content: event.message,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
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
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
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
            vec![ConnectorEvent::ConversationRowCreated(entry)]
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
            }));
            vec![ConnectorEvent::ConversationRowCreated(entry)]
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
    let entry = row_entry(ConversationRow::System(MessageRowContent {
        id: format!("deprecation-{}-{}", event_id, seq),
        content,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) fn handle_background_event(
    event_id: &str,
    event: BackgroundEventEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
        id: format!("background-event-{}-{}", event_id, seq),
        content: event.message,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) fn handle_hook_started(event: HookStartedEvent) -> Vec<ConnectorEvent> {
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
            summary: None,
            output: None,
            duration_ms: None,
            entries: vec![],
        },
        render_hints: Default::default(),
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) fn handle_hook_completed(event: HookCompletedEvent) -> Vec<ConnectorEvent> {
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
    vec![ConnectorEvent::ConversationRowUpdated {
        row_id: format!("hook-{}", event.run.id),
        entry,
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
    let entry = row_entry(ConversationRow::System(MessageRowContent {
        id: format!("stream-error-{}-{}", event_id, seq),
        content,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
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
