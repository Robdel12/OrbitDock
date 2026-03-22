//! Snapshot preparation for WebSocket transport.
//!
//! Deduplicates turn diffs before sending over WS.
//! Never truncates row content -- clients receive full data.

use std::collections::HashSet;

use orbitdock_protocol::{ServerMessage, SessionState};

/// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
pub(crate) const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;

// -- Turn diff deduplication --

fn dedupe_turn_diffs_keep_latest(turn_diffs: &mut Vec<orbitdock_protocol::TurnDiff>) {
    if turn_diffs.len() < 2 {
        return;
    }

    let mut seen = HashSet::new();
    let mut deduped_reversed = Vec::with_capacity(turn_diffs.len());
    for turn in turn_diffs.iter().rev() {
        if seen.insert(turn.turn_id.clone()) {
            deduped_reversed.push(turn.clone());
        }
    }

    deduped_reversed.reverse();
    *turn_diffs = deduped_reversed;
}

// -- Snapshot preparation --

/// Prepare a snapshot for transport: dedupe turn diffs and set pagination metadata.
/// Never truncates content.
pub(crate) fn prepare_snapshot_for_transport(mut snapshot: SessionState) -> SessionState {
    let row_count = snapshot.rows.len() as u64;
    let original_total = snapshot.total_row_count.max(row_count);

    // Deduplicate turn diffs (keep latest per turn_id)
    dedupe_turn_diffs_keep_latest(&mut snapshot.turn_diffs);

    // Pagination metadata
    snapshot.total_row_count = original_total;
    snapshot.oldest_sequence = snapshot.rows.first().map(|entry| entry.sequence);
    snapshot.newest_sequence = snapshot.rows.last().map(|entry| entry.sequence);
    snapshot.has_more_before = snapshot.has_more_before
        || original_total > snapshot.rows.len() as u64
        || snapshot
            .oldest_sequence
            .is_some_and(|sequence| sequence > 0);

    snapshot
}

// -- Outbound message sanitization --

/// Prepare an outbound `ServerMessage` for transport.
/// Never truncates content.
pub(crate) fn sanitize_server_message_for_transport(msg: ServerMessage) -> ServerMessage {
    match msg {
        ServerMessage::ConversationBootstrap {
            session,
            conversation,
        } => {
            let prepared = prepare_snapshot_for_transport(*session);
            ServerMessage::ConversationBootstrap {
                session: Box::new(prepared),
                conversation,
            }
        }
        // Pass through all other messages without modification.
        other => other,
    }
}

/// Sanitize a pre-serialized replay event JSON string for transport.
pub(crate) fn sanitize_replay_event_for_transport(event_json: &str) -> Option<String> {
    let mut value: serde_json::Value = serde_json::from_str(event_json).ok()?;
    let revision = value
        .as_object()
        .and_then(|object| object.get("revision").cloned());

    if let Some(object) = value.as_object_mut() {
        object.remove("revision");
    }

    let message: ServerMessage = serde_json::from_value(value).ok()?;
    let sanitized = sanitize_server_message_for_transport(message);
    let mut sanitized_value = serde_json::to_value(sanitized).ok()?;
    if let Some(revision) = revision {
        if let Some(object) = sanitized_value.as_object_mut() {
            object.insert("revision".to_string(), revision);
        }
    }

    serde_json::to_string(&sanitized_value).ok()
}

/// Check if any replay event exceeds the transport frame limit.
pub(crate) fn replay_has_oversize_event(events: &[String]) -> Option<usize> {
    events
        .iter()
        .map(String::len)
        .max()
        .filter(|size| *size > WS_MAX_TEXT_MESSAGE_BYTES)
}
