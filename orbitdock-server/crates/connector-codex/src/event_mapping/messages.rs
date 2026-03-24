use crate::runtime::{row_entry, thinking_row_entry, ReasoningEventTracker};
use crate::workers::iso_now;
use codex_protocol::protocol::{AgentMessageEvent, AgentReasoningEvent, UserMessageEvent};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
    ConversationRow, MemoryCitation, MemoryCitationEntry, MessageRowContent,
};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub(crate) async fn handle_user_message(
    event_id: &str,
    event: UserMessageEvent,
    msg_counter: &AtomicU64,
) -> Vec<ConnectorEvent> {
    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
    let msg_id = format!("user-{}-{}", event_id, seq);

    let entry = row_entry(ConversationRow::User(MessageRowContent {
        id: msg_id,
        content: event.message,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
    }));
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}

pub(crate) async fn handle_agent_message(
    event_id: &str,
    event: AgentMessageEvent,
    streaming_message: &Arc<tokio::sync::Mutex<Option<crate::runtime::StreamingMessage>>>,
) -> Vec<ConnectorEvent> {
    let mut streaming = streaming_message.lock().await;
    if let Some(streaming_msg) = streaming.take() {
        let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
            id: streaming_msg.message_id.clone(),
            content: event.message,
            turn_id: None,
            timestamp: Some(iso_now()),
            is_streaming: false,
            images: vec![],
            memory_citation: event.memory_citation.map(|citation| MemoryCitation {
                entries: citation
                    .entries
                    .into_iter()
                    .map(|entry| MemoryCitationEntry {
                        path: entry.path,
                        line_start: entry.line_start,
                        line_end: entry.line_end,
                        note: entry.note,
                    })
                    .collect(),
                rollout_ids: citation.rollout_ids,
            }),
            delivery_status: None,
        }));
        vec![ConnectorEvent::ConversationRowUpdated {
            row_id: streaming_msg.message_id,
            entry,
        }]
    } else {
        let entry = row_entry(ConversationRow::Assistant(MessageRowContent {
            id: event_id.to_string(),
            content: event.message,
            turn_id: None,
            timestamp: Some(iso_now()),
            is_streaming: false,
            images: vec![],
            memory_citation: event.memory_citation.map(|citation| MemoryCitation {
                entries: citation
                    .entries
                    .into_iter()
                    .map(|entry| MemoryCitationEntry {
                        path: entry.path,
                        line_start: entry.line_start,
                        line_end: entry.line_end,
                        note: entry.note,
                    })
                    .collect(),
                rollout_ids: citation.rollout_ids,
            }),
            delivery_status: None,
        }));
        vec![ConnectorEvent::ConversationRowCreated(entry)]
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
    let entry = thinking_row_entry(format!("thinking-{}-{}", event_id, seq), event.text);
    vec![ConnectorEvent::ConversationRowCreated(entry)]
}
