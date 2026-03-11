use crate::runtime::ReasoningEventTracker;
use crate::timeline::reasoning_trace_metadata_json;
use crate::workers::iso_now;
use codex_protocol::protocol::{AgentMessageEvent, AgentReasoningEvent, UserMessageEvent};
use orbitdock_connector_core::ConnectorEvent;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub(crate) async fn handle_user_message(
    event_id: &str,
    event: UserMessageEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let msg_id = format!("user-{}-{}", event_id, seq);

    let mut images: Vec<orbitdock_protocol::ImageInput> = Vec::new();
    if let Some(urls) = &event.images {
        for url in urls {
            images.push(orbitdock_protocol::ImageInput {
                input_type: "url".to_string(),
                value: url.clone(),
                ..Default::default()
            });
        }
    }
    for path in &event.local_images {
        images.push(orbitdock_protocol::ImageInput {
            input_type: "path".to_string(),
            value: path.to_string_lossy().to_string(),
            ..Default::default()
        });
    }

    let message = orbitdock_protocol::Message {
        id: msg_id,
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::User,
        content: event.message,
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images,
    };
    vec![ConnectorEvent::MessageCreated(message)]
}

pub(crate) async fn handle_agent_message(
    event_id: &str,
    event: AgentMessageEvent,
    streaming_message: &Arc<tokio::sync::Mutex<Option<crate::runtime::StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
    let mut streaming = streaming_message.lock().await;
    if let Some(streaming_message) = streaming.take() {
        vec![ConnectorEvent::MessageUpdated {
            message_id: streaming_message.message_id,
            content: Some(event.message),
            tool_output: None,
            is_error: None,
            is_in_progress: Some(false),
            duration_ms: None,
        }]
    } else {
        let message = orbitdock_protocol::Message {
            id: event_id.to_string(),
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
}

pub(crate) async fn handle_agent_reasoning(
    event_id: &str,
    event: AgentReasoningEvent,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let should_process = {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.should_process_legacy_summary()
    };
    if !should_process {
        return vec![];
    }

    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let message = orbitdock_protocol::Message {
        id: format!("thinking-{}-{}", event_id, seq),
        session_id: String::new(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Thinking,
        content: event.text,
        tool_name: None,
        tool_input: reasoning_trace_metadata_json("summary", "legacy", None, None),
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_now(),
        duration_ms: None,
        images: vec![],
    };
    vec![ConnectorEvent::MessageCreated(message)]
}
