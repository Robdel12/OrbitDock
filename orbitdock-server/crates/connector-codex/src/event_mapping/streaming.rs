use crate::runtime::{
    apply_delta_message, ReasoningEventTracker, StreamingMessage, STREAM_THROTTLE_MS,
};
use crate::timeline::{
    reasoning_trace_metadata_json, render_review_output, review_request_summary,
};
use crate::workers::iso_now;
use codex_protocol::items::TurnItem;
use codex_protocol::models::ResponseItem;
use codex_protocol::protocol::ReviewRequest;
use codex_protocol::protocol::{
    AgentMessageContentDeltaEvent, AgentMessageDeltaEvent, AgentReasoningDeltaEvent,
    AgentReasoningRawContentDeltaEvent, AgentReasoningRawContentEvent,
    ExitedReviewModeEvent, ItemCompletedEvent, ItemStartedEvent, RawResponseItemEvent,
    ReasoningContentDeltaEvent, ReasoningRawContentDeltaEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub(crate) async fn handle_agent_message_content_delta(
    event: AgentMessageContentDeltaEvent,
    streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
    let mut streaming = streaming_message.lock().await;
    match streaming.as_mut() {
        None => {
            let msg_id = event.item_id.clone();
            let message = orbitdock_protocol::Message {
                id: msg_id.clone(),
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Assistant,
                content: event.delta.clone(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: iso_now(),
                duration_ms: None,
                images: vec![],
            };
            *streaming = Some(StreamingMessage {
                message_id: msg_id,
                content: event.delta,
                last_broadcast: std::time::Instant::now(),
                from_content_delta: true,
            });
            vec![ConnectorEvent::MessageCreated(message)]
        }
        Some(streaming_message) => {
            streaming_message.content.push_str(&event.delta);
            let now = std::time::Instant::now();
            if now.duration_since(streaming_message.last_broadcast).as_millis() >= STREAM_THROTTLE_MS
            {
                streaming_message.last_broadcast = now;
                vec![ConnectorEvent::MessageUpdated {
                    message_id: streaming_message.message_id.clone(),
                    content: Some(streaming_message.content.clone()),
                    tool_output: None,
                    is_error: None,
                    is_in_progress: Some(true),
                    duration_ms: None,
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
            let message = orbitdock_protocol::Message {
                id: msg_id.clone(),
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Assistant,
                content: event.delta.clone(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: iso_now(),
                duration_ms: None,
                images: vec![],
            };
            *streaming = Some(StreamingMessage {
                message_id: msg_id,
                content: event.delta,
                last_broadcast: std::time::Instant::now(),
                from_content_delta: false,
            });
            vec![ConnectorEvent::MessageCreated(message)]
        }
        Some(streaming_message) => {
            if streaming_message.from_content_delta {
                return vec![];
            }
            streaming_message.content.push_str(&event.delta);
            let now = std::time::Instant::now();
            if now.duration_since(streaming_message.last_broadcast).as_millis() < STREAM_THROTTLE_MS
            {
                return vec![];
            }
            streaming_message.last_broadcast = now;
            vec![ConnectorEvent::MessageUpdated {
                message_id: streaming_message.message_id.clone(),
                content: Some(streaming_message.content.clone()),
                tool_output: None,
                is_error: None,
                is_in_progress: Some(true),
                duration_ms: None,
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
    apply_delta_message(
        delta_buffers,
        format!("reasoning-summary-{}-{}", event.item_id, event.summary_index),
        event.delta,
        orbitdock_protocol::MessageType::Thinking,
        reasoning_trace_metadata_json(
            "summary",
            "modern",
            Some(event.item_id.as_str()),
            Some(event.summary_index),
        ),
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
    apply_delta_message(
        delta_buffers,
        format!("reasoning-raw-{}-{}", event.item_id, event.content_index),
        event.delta,
        orbitdock_protocol::MessageType::Thinking,
        reasoning_trace_metadata_json(
            "raw",
            "modern",
            Some(event.item_id.as_str()),
            Some(event.content_index),
        ),
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
    apply_delta_message(
        delta_buffers,
        format!("reasoning-summary-legacy-{}", event_id),
        event.delta,
        orbitdock_protocol::MessageType::Thinking,
        reasoning_trace_metadata_json("summary", "legacy", None, None),
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
    let message = orbitdock_protocol::Message {
        id: format!("reasoning-raw-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Thinking,
        content: event.text,
        tool_name: None,
        tool_input: reasoning_trace_metadata_json("raw", "legacy", None, None),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
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
    apply_delta_message(
        delta_buffers,
        format!("reasoning-raw-legacy-{}", event_id),
        event.delta,
        orbitdock_protocol::MessageType::Thinking,
        reasoning_trace_metadata_json("raw", "legacy", None, None),
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
    let message = orbitdock_protocol::Message {
        id: format!("review-entered-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Enter review mode".to_string(),
        tool_name: Some("task".to_string()),
        tool_input: serde_json::to_string(&json!({
            "subagent_type": "review",
            "description": summary,
        }))
        .ok(),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
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
    let message = orbitdock_protocol::Message {
        id: format!("review-exited-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Tool,
        content: "Exit review mode".to_string(),
        tool_name: Some("task".to_string()),
        tool_input: serde_json::to_string(&json!({
            "subagent_type": "review",
            "description": "Review completed",
        }))
        .ok(),
        tool_output: Some(output),
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) async fn handle_item_started(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    event: ItemStartedEvent,
) -> Vec<ConnectorEvent> {
    match event.item {
        TurnItem::Plan(item) => {
            apply_delta_message(
                delta_buffers,
                format!("plan-{}", item.id),
                item.text,
                orbitdock_protocol::MessageType::Thinking,
                None,
            )
            .await
        }
        TurnItem::ContextCompaction(item) => {
            let message = orbitdock_protocol::Message {
                id: item.id,
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Tool,
                content: "Compacting context".to_string(),
                tool_name: Some("compactcontext".to_string()),
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: iso_now(),
                duration_ms: None,
                images: vec![],
            };
            vec![ConnectorEvent::MessageCreated(message)]
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
            vec![ConnectorEvent::MessageUpdated {
                message_id,
                content: Some(item.text),
                tool_output: None,
                is_error: None,
                is_in_progress: Some(false),
                duration_ms: None,
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
                if had_buffer {
                    events.push(ConnectorEvent::MessageUpdated {
                        message_id,
                        content: Some(summary),
                        tool_output: None,
                        is_error: None,
                        is_in_progress: Some(false),
                        duration_ms: None,
                    });
                } else {
                    let message = orbitdock_protocol::Message {
                        id: message_id,
                        session_id: String::new(),
                        sequence: None,
                        message_type: orbitdock_protocol::MessageType::Thinking,
                        content: summary,
                        tool_name: None,
                        tool_input: reasoning_trace_metadata_json(
                            "summary",
                            "modern",
                            Some(item.id.as_str()),
                            Some(idx as i64),
                        ),
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    events.push(ConnectorEvent::MessageCreated(message));
                }
            }

            for (idx, raw) in item.raw_content.into_iter().enumerate() {
                let message_id = format!("reasoning-raw-{}-{}", item.id, idx);
                let had_buffer = {
                    let mut buffers = delta_buffers.lock().await;
                    buffers.remove(&message_id).is_some()
                };
                if had_buffer {
                    events.push(ConnectorEvent::MessageUpdated {
                        message_id,
                        content: Some(raw),
                        tool_output: None,
                        is_error: None,
                        is_in_progress: Some(false),
                        duration_ms: None,
                    });
                } else {
                    let message = orbitdock_protocol::Message {
                        id: message_id,
                        session_id: String::new(),
                        sequence: None,
                        message_type: orbitdock_protocol::MessageType::Thinking,
                        content: raw,
                        tool_name: None,
                        tool_input: reasoning_trace_metadata_json(
                            "raw",
                            "modern",
                            Some(item.id.as_str()),
                            Some(idx as i64),
                        ),
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    events.push(ConnectorEvent::MessageCreated(message));
                }
            }

            events
        }
        TurnItem::ContextCompaction(item) => vec![ConnectorEvent::MessageUpdated {
            message_id: item.id,
            content: Some("Context compacted".to_string()),
            tool_output: Some("Context compacted".to_string()),
            is_error: Some(false),
            is_in_progress: Some(false),
            duration_ms: None,
        }],
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
            let message = orbitdock_protocol::Message {
                id: format!("raw-response-item-{}-{}", event_id, seq),
                session_id: String::new(),
                sequence: None,
                message_type: orbitdock_protocol::MessageType::Assistant,
                content: "Received unsupported raw response item.".to_string(),
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
        _ => vec![],
    }
}
