use crate::runtime::{
    apply_delta_thinking, finalized_thinking_row_entry, row_entry, thinking_row_entry,
    ReasoningEventTracker, StreamingMessage, STREAM_THROTTLE_MS,
};
use crate::timeline::{render_review_output, review_request_summary};
use crate::workers::iso_now;
use codex_protocol::items::TurnItem;
use codex_protocol::models::ResponseItem;
use codex_protocol::protocol::ReviewRequest;
use codex_protocol::protocol::{
    AgentMessageContentDeltaEvent, AgentMessageDeltaEvent, AgentReasoningDeltaEvent,
    AgentReasoningRawContentDeltaEvent, AgentReasoningRawContentEvent, ExitedReviewModeEvent,
    ItemCompletedEvent, ItemStartedEvent, RawResponseItemEvent, ReasoningContentDeltaEvent,
    ReasoningRawContentDeltaEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
    compute_tool_display, ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
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

pub(crate) async fn handle_agent_message_content_delta(
    event: AgentMessageContentDeltaEvent,
    streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
    let mut streaming = streaming_message.lock().await;
    match streaming.as_mut() {
        None => {
            let msg_id = event.item_id.clone();
            let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
                id: msg_id.clone(),
                content: event.delta.clone(),
                turn_id: None,
                timestamp: Some(iso_now()),
                is_streaming: true,
                images: vec![],
            }));
            *streaming = Some(StreamingMessage {
                message_id: msg_id,
                content: event.delta,
                last_broadcast: std::time::Instant::now(),
                from_content_delta: true,
            });
            vec![ConnectorEvent::ConversationRowCreated(entry)]
        }
        Some(streaming_msg) => {
            streaming_msg.content.push_str(&event.delta);
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
                }));
                vec![ConnectorEvent::ConversationRowUpdated {
                    row_id: streaming_msg.message_id.clone(),
                    entry,
                }]
            } else {
                vec![]
            }
        }
    }
}

pub(crate) async fn handle_agent_message_delta(
    event_id: &str,
    event: AgentMessageDeltaEvent,
    streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
    let mut streaming = streaming_message.lock().await;
    match streaming.as_mut() {
        None => {
            let msg_id = event_id.to_string();
            let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
                id: msg_id.clone(),
                content: event.delta.clone(),
                turn_id: None,
                timestamp: Some(iso_now()),
                is_streaming: true,
                images: vec![],
            }));
            *streaming = Some(StreamingMessage {
                message_id: msg_id,
                content: event.delta,
                last_broadcast: std::time::Instant::now(),
                from_content_delta: false,
            });
            vec![ConnectorEvent::ConversationRowCreated(entry)]
        }
        Some(streaming_msg) => {
            if streaming_msg.from_content_delta {
                return vec![];
            }
            streaming_msg.content.push_str(&event.delta);
            let now = std::time::Instant::now();
            if now.duration_since(streaming_msg.last_broadcast).as_millis() < STREAM_THROTTLE_MS {
                return vec![];
            }
            streaming_msg.last_broadcast = now;
            let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
                id: streaming_msg.message_id.clone(),
                content: streaming_msg.content.clone(),
                turn_id: None,
                timestamp: Some(iso_now()),
                is_streaming: true,
                images: vec![],
            }));
            vec![ConnectorEvent::ConversationRowUpdated {
                row_id: streaming_msg.message_id.clone(),
                entry,
            }]
        }
    }
}

pub(crate) async fn handle_reasoning_content_delta(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    event: ReasoningContentDeltaEvent,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_modern_summary()
    };
    if !should_process {
        return vec![];
    }
    apply_delta_thinking(
        delta_buffers,
        format!(
            "reasoning-summary-{}-{}",
            event.item_id, event.summary_index
        ),
        event.delta,
    )
    .await
}

pub(crate) async fn handle_reasoning_raw_content_delta(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    event: ReasoningRawContentDeltaEvent,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_modern_raw()
    };
    if !should_process {
        return vec![];
    }
    apply_delta_thinking(
        delta_buffers,
        format!("reasoning-raw-{}-{}", event.item_id, event.content_index),
        event.delta,
    )
    .await
}

pub(crate) async fn handle_agent_reasoning_delta(
    event_id: &str,
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    event: AgentReasoningDeltaEvent,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_legacy_summary()
    };
    if !should_process {
        return vec![];
    }
    apply_delta_thinking(
        delta_buffers,
        format!("reasoning-summary-legacy-{}", event_id),
        event.delta,
    )
    .await
}

pub(crate) async fn handle_agent_reasoning_raw_content(
    event_id: &str,
    event: AgentReasoningRawContentEvent,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_legacy_raw()
    };
    if !should_process {
        return vec![];
    }
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let entry = thinking_row_entry(format!("reasoning-raw-{}-{}", event_id, seq), event.text);
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) async fn handle_agent_reasoning_raw_content_delta(
    event_id: &str,
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    event: AgentReasoningRawContentDeltaEvent,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_legacy_raw()
    };
    if !should_process {
        return vec![];
    }
    apply_delta_thinking(
        delta_buffers,
        format!("reasoning-raw-legacy-{}", event_id),
        event.delta,
    )
    .await
}

pub(crate) async fn handle_agent_reasoning_section_break(
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> Vec<ConnectorEvent> {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.mark_modern_summary_seen();
    vec![]
}

pub(crate) fn handle_entered_review_mode(
    event_id: &str,
    event: ReviewRequest,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let summary = review_request_summary(&event);
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: format!("review-entered-{}-{}", event_id, seq),
            provider: Provider::Codex,
            family: ToolFamily::Plan,
            kind: ToolKind::EnterPlanMode,
            status: ToolStatus::Completed,
            title: "Enter review mode".to_string(),
            subtitle: None,
            summary: Some(summary),
            preview: None,
            started_at: Some(iso_now()),
            ended_at: Some(iso_now()),
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "mode": "review",
                "steps": [],
                "review_mode": "enter",
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        },
    ))]
}

pub(crate) fn handle_exited_review_mode(
    event_id: &str,
    event: ExitedReviewModeEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let output = event
        .review_output
        .map(|review_output| render_review_output(&review_output))
        .unwrap_or_else(|| "Review mode exited.".to_string());

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
        ToolRow {
            id: format!("review-exited-{}-{}", event_id, seq),
            provider: Provider::Codex,
            family: ToolFamily::Plan,
            kind: ToolKind::ExitPlanMode,
            status: ToolStatus::Completed,
            title: "Exit review mode".to_string(),
            subtitle: None,
            summary: Some(output.clone()),
            preview: None,
            started_at: Some(iso_now()),
            ended_at: Some(iso_now()),
            duration_ms: None,
            grouping_key: None,
            invocation: json!({
                "mode": "review",
                "steps": [],
                "review_mode": "exit",
            }),
            result: Some(json!({
                "tool_name": "task",
                "raw_output": output.clone(),
                "summary": output,
            })),
            render_hints: Default::default(),
            tool_display: None,
        },
    ))]
}

pub(crate) async fn handle_item_started(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    event: ItemStartedEvent,
) -> Vec<ConnectorEvent> {
    match event.item {
        TurnItem::Plan(item) => {
            apply_delta_thinking(delta_buffers, format!("plan-{}", item.id), item.text).await
        }
        TurnItem::ContextCompaction(item) => {
            vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
                ToolRow {
                    id: item.id,
                    provider: Provider::Codex,
                    family: ToolFamily::Context,
                    kind: ToolKind::CompactContext,
                    status: ToolStatus::Running,
                    title: "Compacting context".to_string(),
                    subtitle: None,
                    summary: None,
                    preview: None,
                    started_at: Some(iso_now()),
                    ended_at: None,
                    duration_ms: None,
                    grouping_key: None,
                    invocation: json!({}),
                    result: None,
                    render_hints: Default::default(),
                    tool_display: None,
                },
            ))]
        }
        _ => vec![],
    }
}

pub(crate) async fn handle_item_completed(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    event: ItemCompletedEvent,
) -> Vec<ConnectorEvent> {
    match event.item {
        TurnItem::Plan(item) => {
            let message_id = format!("plan-{}", item.id);
            {
                let mut buffers = delta_buffers.lock().await;
                buffers.remove(&message_id);
            }
            let entry = finalized_thinking_row_entry(message_id.clone(), item.text);
            vec![ConnectorEvent::ConversationRowUpdated {
                row_id: message_id,
                entry,
            }]
        }
        TurnItem::Reasoning(item) => {
            let mut events: Vec<ConnectorEvent> = Vec::new();

            for (idx, summary) in item.summary_text.into_iter().enumerate() {
                let message_id = format!("reasoning-summary-{}-{}", item.id, idx);
                let had_buffer = {
                    let mut buffers = delta_buffers.lock().await;
                    buffers.remove(&message_id).is_some()
                };
                let entry = finalized_thinking_row_entry(message_id.clone(), summary);
                if had_buffer {
                    events.push(ConnectorEvent::ConversationRowUpdated {
                        row_id: message_id,
                        entry,
                    });
                } else {
                    events.push(ConnectorEvent::ConversationRowCreated(entry));
                }
            }

            for (idx, raw) in item.raw_content.into_iter().enumerate() {
                let message_id = format!("reasoning-raw-{}-{}", item.id, idx);
                let had_buffer = {
                    let mut buffers = delta_buffers.lock().await;
                    buffers.remove(&message_id).is_some()
                };
                let entry = finalized_thinking_row_entry(message_id.clone(), raw);
                if had_buffer {
                    events.push(ConnectorEvent::ConversationRowUpdated {
                        row_id: message_id,
                        entry,
                    });
                } else {
                    events.push(ConnectorEvent::ConversationRowCreated(entry));
                }
            }

            events
        }
        TurnItem::ContextCompaction(item) => {
            let entry = tool_row_entry(ToolRow {
                id: item.id.clone(),
                provider: Provider::Codex,
                family: ToolFamily::Context,
                kind: ToolKind::CompactContext,
                status: ToolStatus::Completed,
                title: "Context compacted".to_string(),
                subtitle: None,
                summary: Some("Context compacted".to_string()),
                preview: None,
                started_at: None,
                ended_at: Some(iso_now()),
                duration_ms: None,
                grouping_key: None,
                invocation: json!({
                    "summary": "Context compacted",
                }),
                result: Some(json!({
                    "summary": "Context compacted",
                })),
                render_hints: Default::default(),
                tool_display: None,
            });
            vec![ConnectorEvent::ConversationRowUpdated {
                row_id: item.id,
                entry,
            }]
        }
        _ => vec![],
    }
}

pub(crate) fn handle_raw_response_item(
    event_id: &str,
    event: RawResponseItemEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    match event.item {
        ResponseItem::Other => {
            let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
            let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
                id: format!("raw-response-item-{}-{}", event_id, seq),
                content: "Received unsupported raw response item.".to_string(),
                turn_id: None,
                timestamp: Some(iso_now()),
                is_streaming: false,
                images: vec![],
            }));
            vec![ConnectorEvent::ConversationRowCreated(entry)]
        }
        _ => vec![],
    }
}
