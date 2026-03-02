//! Snapshot compaction for WebSocket transport.
//!
//! Fits large `SessionState` snapshots within WebSocket frame limits by
//! progressively truncating message content, trimming images, deduplicating
//! turn diffs, and searching for the smallest representation that stays
//! under the target byte budget.

use std::collections::HashSet;

use tracing::warn;

use orbitdock_protocol::{MessageChanges, ServerMessage, SessionState, StateChanges};

pub(crate) const SNAPSHOT_MAX_MESSAGES: usize = 200;
pub(crate) const SNAPSHOT_MAX_CONTENT_CHARS: usize = 16_000;
const SNAPSHOT_MIN_CONTENT_CHARS: usize = 250;
const SNAPSHOT_MAX_TURN_DIFFS: usize = 80;
/// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
pub(crate) const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;
/// Snapshots should stay much smaller than the hard transport ceiling to avoid reconnect churn.
pub(crate) const SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES: usize = 256 * 1024;

// ── Text truncation ─────────────────────────────────────────────────────

fn truncate_text(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let truncated: String = value.chars().take(max_chars).collect();
    format!("{truncated}\n\n[truncated]")
}

fn truncate_string_in_place(value: &mut String, max_chars: usize) {
    if value.chars().count() <= max_chars {
        return;
    }
    let truncated = truncate_text(value, max_chars);
    *value = truncated;
}

fn truncate_option_string_in_place(value: &mut Option<String>, max_chars: usize) {
    if let Some(content) = value.as_mut() {
        truncate_string_in_place(content, max_chars);
    }
}

// ── Approval compaction ─────────────────────────────────────────────────

fn compact_approval_preview_for_transport(
    preview: &mut orbitdock_protocol::ApprovalPreview,
    max_chars: usize,
) {
    truncate_string_in_place(&mut preview.value, max_chars);
    truncate_option_string_in_place(&mut preview.compact, max_chars);
    truncate_option_string_in_place(&mut preview.decision_scope, max_chars);
    truncate_option_string_in_place(&mut preview.manifest, max_chars.saturating_mul(2));
    for finding in &mut preview.risk_findings {
        truncate_string_in_place(finding, max_chars);
    }
    for segment in &mut preview.shell_segments {
        truncate_string_in_place(&mut segment.command, max_chars);
        truncate_option_string_in_place(&mut segment.leading_operator, 8);
    }
}

fn compact_approval_for_transport(
    approval: &mut orbitdock_protocol::ApprovalRequest,
    max_chars: usize,
) {
    truncate_option_string_in_place(&mut approval.tool_input, max_chars);
    truncate_option_string_in_place(&mut approval.command, max_chars);
    truncate_option_string_in_place(&mut approval.file_path, max_chars);
    truncate_option_string_in_place(&mut approval.question, max_chars);
    truncate_option_string_in_place(&mut approval.diff, max_chars.saturating_mul(2));
    for prompt in &mut approval.question_prompts {
        truncate_string_in_place(&mut prompt.id, max_chars);
        truncate_option_string_in_place(&mut prompt.header, max_chars);
        truncate_string_in_place(&mut prompt.question, max_chars);
        for option in &mut prompt.options {
            truncate_string_in_place(&mut option.label, max_chars);
            truncate_option_string_in_place(&mut option.description, max_chars);
        }
    }
    if let Some(preview) = approval.preview.as_mut() {
        compact_approval_preview_for_transport(preview, max_chars);
    }

    if let Some(amendment) = approval.proposed_amendment.as_mut() {
        for line in amendment {
            truncate_string_in_place(line, max_chars);
        }
    }
}

// ── Message compaction ──────────────────────────────────────────────────

pub(crate) fn compact_message_for_transport(
    message: &mut orbitdock_protocol::Message,
    max_chars: usize,
) {
    compact_message_for_transport_inner(message, max_chars, true);
}

/// Compact a message for individual broadcast (MessageAppended).
/// Unlike snapshot compaction, this preserves `tool_input` because truncating
/// the JSON string makes it unparseable on the client, breaking Write/Edit
/// tool card rendering (shows "0 lines" instead of actual content).
pub(crate) fn compact_message_for_broadcast(
    message: &mut orbitdock_protocol::Message,
    max_chars: usize,
) {
    compact_message_for_transport_inner(message, max_chars, false);
}

fn compact_message_for_transport_inner(
    message: &mut orbitdock_protocol::Message,
    max_chars: usize,
    truncate_tool_input: bool,
) {
    message.images = crate::images::normalize_images_for_transport(&message.images);
    truncate_string_in_place(&mut message.content, max_chars);
    if truncate_tool_input {
        truncate_option_string_in_place(&mut message.tool_input, max_chars);
    }
    truncate_option_string_in_place(&mut message.tool_output, max_chars);
}

fn compact_message_changes_for_transport(changes: &mut MessageChanges, max_chars: usize) {
    truncate_option_string_in_place(&mut changes.content, max_chars);
    truncate_option_string_in_place(&mut changes.tool_output, max_chars);
}

fn compact_state_changes_for_transport(changes: &mut StateChanges, max_chars: usize) {
    if let Some(diff) = changes.current_diff.as_mut().and_then(Option::as_mut) {
        truncate_string_in_place(diff, max_chars.saturating_mul(2));
    }
    if let Some(plan) = changes.current_plan.as_mut().and_then(Option::as_mut) {
        truncate_string_in_place(plan, max_chars.saturating_mul(2));
    }
    if let Some(approval) = changes.pending_approval.as_mut().and_then(Option::as_mut) {
        compact_approval_for_transport(approval, max_chars);
    }
}

// ── Turn diff deduplication ─────────────────────────────────────────────

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

// ── Snapshot compaction ─────────────────────────────────────────────────

fn compact_snapshot_for_transport_with_limits(
    mut snapshot: SessionState,
    max_messages: usize,
    max_content_chars: usize,
) -> SessionState {
    let max_messages = max_messages.min(SNAPSHOT_MAX_MESSAGES);
    let max_content_chars =
        max_content_chars.clamp(SNAPSHOT_MIN_CONTENT_CHARS, SNAPSHOT_MAX_CONTENT_CHARS);

    if max_messages == 0 {
        snapshot.messages.clear();
    } else if snapshot.messages.len() > max_messages {
        let keep_from = snapshot.messages.len() - max_messages;
        snapshot.messages = snapshot.messages.split_off(keep_from);
    }

    for message in &mut snapshot.messages {
        compact_message_for_transport(message, max_content_chars);
    }

    // Avoid huge payload spikes from active turn context fields.
    truncate_option_string_in_place(
        &mut snapshot.current_diff,
        max_content_chars.saturating_mul(2),
    );
    truncate_option_string_in_place(
        &mut snapshot.current_plan,
        max_content_chars.saturating_mul(2),
    );
    truncate_option_string_in_place(&mut snapshot.pending_tool_input, max_content_chars);
    truncate_option_string_in_place(&mut snapshot.pending_question, max_content_chars);
    if let Some(approval) = snapshot.pending_approval.as_mut() {
        compact_approval_for_transport(approval, max_content_chars);
    }

    dedupe_turn_diffs_keep_latest(&mut snapshot.turn_diffs);

    let max_turn_diffs = if max_messages == 0 {
        0
    } else {
        SNAPSHOT_MAX_TURN_DIFFS.min(max_messages.saturating_mul(2))
    };
    if max_turn_diffs == 0 {
        snapshot.turn_diffs.clear();
    } else if snapshot.turn_diffs.len() > max_turn_diffs {
        let keep_from = snapshot.turn_diffs.len() - max_turn_diffs;
        snapshot.turn_diffs = snapshot.turn_diffs.split_off(keep_from);
    }
    for turn in &mut snapshot.turn_diffs {
        truncate_string_in_place(&mut turn.diff, max_content_chars.saturating_mul(2));
    }

    snapshot
}

pub(crate) fn snapshot_transport_size_bytes(snapshot: &SessionState) -> Option<usize> {
    serde_json::to_vec(&ServerMessage::SessionSnapshot {
        session: snapshot.clone(),
    })
    .ok()
    .map(|bytes| bytes.len())
}

fn trim_snapshot_images_to_transport_limit(snapshot: &mut SessionState, limit_bytes: usize) {
    let mut size = snapshot_transport_size_bytes(snapshot).unwrap_or(usize::MAX);
    if size <= limit_bytes {
        return;
    }

    loop {
        let mut removed = false;
        for message in &mut snapshot.messages {
            if message.images.is_empty() {
                continue;
            }
            message.images.pop();
            removed = true;
            break;
        }

        if !removed {
            break;
        }

        size = snapshot_transport_size_bytes(snapshot).unwrap_or(usize::MAX);
        if size <= limit_bytes {
            break;
        }
    }
}

pub(crate) fn compact_snapshot_to_transport_limit(snapshot: SessionState) -> SessionState {
    let mut portable_snapshot = snapshot;
    for message in &mut portable_snapshot.messages {
        message.images = crate::images::normalize_images_for_transport(&message.images);
    }

    let default_compacted = compact_snapshot_for_transport_with_limits(
        portable_snapshot.clone(),
        SNAPSHOT_MAX_MESSAGES,
        SNAPSHOT_MAX_CONTENT_CHARS,
    );
    let mut default_compacted = default_compacted;
    trim_snapshot_images_to_transport_limit(
        &mut default_compacted,
        SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
    );

    if snapshot_transport_size_bytes(&default_compacted)
        .is_some_and(|size| size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES)
    {
        return default_compacted;
    }

    // Never go to 0 — sending an empty snapshot makes the client think the
    // conversation was cleared. Better to exceed the target than lose all context.
    let message_caps = [160, 120, 96, 72, 48, 32, 24, 16, 8, 4, 2, 1];
    let content_caps = [
        12_000,
        8_000,
        4_000,
        2_000,
        1_000,
        500,
        SNAPSHOT_MIN_CONTENT_CHARS,
    ];
    let mut smallest = default_compacted;
    let mut smallest_size = snapshot_transport_size_bytes(&smallest).unwrap_or(usize::MAX);

    for max_messages in message_caps {
        for max_content_chars in content_caps {
            let mut candidate = compact_snapshot_for_transport_with_limits(
                portable_snapshot.clone(),
                max_messages,
                max_content_chars,
            );
            trim_snapshot_images_to_transport_limit(
                &mut candidate,
                SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            );
            let Some(size) = snapshot_transport_size_bytes(&candidate) else {
                continue;
            };
            if size < smallest_size {
                smallest_size = size;
                smallest = candidate.clone();
            }
            if size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES {
                return candidate;
            }
        }
    }

    if smallest_size > WS_MAX_TEXT_MESSAGE_BYTES {
        trim_snapshot_images_to_transport_limit(&mut smallest, WS_MAX_TEXT_MESSAGE_BYTES);
    }

    smallest
}

/// Compact a snapshot with default limits (used by handlers before sending).
pub(crate) fn compact_snapshot_for_transport(snapshot: SessionState) -> SessionState {
    compact_snapshot_for_transport_with_limits(
        snapshot,
        SNAPSHOT_MAX_MESSAGES,
        SNAPSHOT_MAX_CONTENT_CHARS,
    )
}

// ── Per-message transport sanitization ──────────────────────────────────

fn message_appended_transport_size_bytes(
    session_id: &str,
    message: &orbitdock_protocol::Message,
) -> Option<usize> {
    serde_json::to_vec(&ServerMessage::MessageAppended {
        session_id: session_id.to_string(),
        message: message.clone(),
    })
    .ok()
    .map(|bytes| bytes.len())
}

fn trim_message_images_to_transport_limit(
    session_id: &str,
    message: &mut orbitdock_protocol::Message,
) {
    let mut size = message_appended_transport_size_bytes(session_id, message).unwrap_or(usize::MAX);
    if size <= WS_MAX_TEXT_MESSAGE_BYTES {
        return;
    }

    while !message.images.is_empty() && size > WS_MAX_TEXT_MESSAGE_BYTES {
        message.images.pop();
        size = message_appended_transport_size_bytes(session_id, message).unwrap_or(usize::MAX);
    }
}

// ── Outbound message sanitization ───────────────────────────────────────

/// Apply transport compaction to an outbound `ServerMessage` before framing.
pub(crate) fn sanitize_server_message_for_transport(msg: ServerMessage) -> ServerMessage {
    match msg {
        ServerMessage::SessionSnapshot { session } => {
            let before = snapshot_transport_size_bytes(&session);
            let compacted = compact_snapshot_to_transport_limit(session);
            let after = snapshot_transport_size_bytes(&compacted);

            if let (Some(before), Some(after)) = (before, after) {
                if before > SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES && after < before {
                    warn!(
                        component = "websocket",
                        event = "ws.transport.snapshot_compacted",
                        session_id = %compacted.id,
                        before_bytes = before,
                        after_bytes = after,
                        messages_in_snapshot = compacted.messages.len(),
                        target_bytes = SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
                        max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                        "Compacted session snapshot to fit outbound payload target"
                    );
                }
            }

            ServerMessage::SessionSnapshot { session: compacted }
        }
        ServerMessage::MessageAppended {
            session_id,
            mut message,
        } => {
            compact_message_for_broadcast(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);
            trim_message_images_to_transport_limit(&session_id, &mut message);
            ServerMessage::MessageAppended {
                session_id,
                message,
            }
        }
        ServerMessage::MessageUpdated {
            session_id,
            message_id,
            mut changes,
        } => {
            compact_message_changes_for_transport(&mut changes, SNAPSHOT_MAX_CONTENT_CHARS);
            ServerMessage::MessageUpdated {
                session_id,
                message_id,
                changes,
            }
        }
        ServerMessage::SessionDelta {
            session_id,
            mut changes,
        } => {
            compact_state_changes_for_transport(&mut changes, SNAPSHOT_MAX_CONTENT_CHARS);
            ServerMessage::SessionDelta {
                session_id,
                changes,
            }
        }
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
