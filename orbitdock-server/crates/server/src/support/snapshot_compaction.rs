//! Snapshot preparation for WebSocket transport.
//!
//! Normalizes images and deduplicates turn diffs before sending over WS.
//! Never truncates message content — clients receive full data.

use std::collections::HashSet;

use orbitdock_protocol::{ServerMessage, SessionState};

/// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
pub(crate) const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;

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

// ── Snapshot preparation ────────────────────────────────────────────────

/// Prepare a snapshot for transport: normalize images, dedupe turn diffs,
/// and set pagination metadata. Never truncates content.
pub(crate) fn prepare_snapshot_for_transport(mut snapshot: SessionState) -> SessionState {
    let message_count = snapshot.messages.len() as u64;
    let original_total = snapshot
        .total_message_count
        .map(|count| count.max(message_count))
        .unwrap_or(message_count);

    // Normalize image references (strip raw bytes, resolve paths to attachment IDs)
    for message in &mut snapshot.messages {
        message.images = crate::infrastructure::images::normalize_images_for_transport(
            &message.session_id,
            &message.images,
        );
    }

    // Deduplicate turn diffs (keep latest per turn_id)
    dedupe_turn_diffs_keep_latest(&mut snapshot.turn_diffs);

    // Pagination metadata
    snapshot.total_message_count = Some(original_total);
    snapshot.oldest_sequence = snapshot
        .messages
        .first()
        .and_then(|message| message.sequence);
    snapshot.newest_sequence = snapshot
        .messages
        .last()
        .and_then(|message| message.sequence);
    snapshot.has_more_before = Some(
        snapshot.has_more_before.unwrap_or(false)
            || original_total > snapshot.messages.len() as u64
            || snapshot
                .oldest_sequence
                .is_some_and(|sequence| sequence > 0),
    );

    snapshot
}

// ── Outbound message sanitization ───────────────────────────────────────

/// Prepare an outbound `ServerMessage` for transport.
/// Normalizes images but never truncates content.
pub(crate) fn sanitize_server_message_for_transport(msg: ServerMessage) -> ServerMessage {
    match msg {
        ServerMessage::SessionSnapshot { session } => {
            let prepared = prepare_snapshot_for_transport(session);
            ServerMessage::SessionSnapshot { session: prepared }
        }
        ServerMessage::MessageAppended {
            session_id,
            mut message,
        } => {
            message.images = crate::infrastructure::images::normalize_images_for_transport(
                &session_id,
                &message.images,
            );
            ServerMessage::MessageAppended {
                session_id,
                message,
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

#[cfg(test)]
mod tests {
    use super::{
        prepare_snapshot_for_transport, replay_has_oversize_event,
        sanitize_replay_event_for_transport, sanitize_server_message_for_transport,
        WS_MAX_TEXT_MESSAGE_BYTES,
    };
    use orbitdock_protocol::{
        new_id, ImageInput, Message, MessageType, Provider, ServerMessage, TurnDiff,
    };
    use std::sync::Once;

    use crate::domain::sessions::session::SessionHandle;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-server-test-data");
            let _ = std::fs::remove_dir_all(&dir);
            crate::infrastructure::paths::init_data_dir(Some(&dir));
        });
    }

    #[test]
    fn snapshot_preparation_normalizes_images_and_sets_pagination() {
        let mut snapshot = SessionHandle::new(
            "prep-test".to_string(),
            Provider::Codex,
            "/tmp/prep-test".into(),
        )
        .retained_state();

        snapshot.messages = (0..5)
            .map(|index| Message {
                id: format!("m-{index}"),
                session_id: snapshot.id.clone(),
                sequence: Some(index as u64),
                message_type: MessageType::Assistant,
                content: format!("Message {index}"),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: false,
                timestamp: "2026-01-01T00:00:00Z".to_string(),
                duration_ms: Some(123),
                images: vec![],
            })
            .collect();

        let prepared = prepare_snapshot_for_transport(snapshot);

        assert_eq!(prepared.oldest_sequence, Some(0));
        assert_eq!(prepared.newest_sequence, Some(4));
        assert_eq!(prepared.total_message_count, Some(5));
        assert_eq!(prepared.messages.len(), 5);
    }

    #[test]
    fn detects_oversized_replay_payloads() {
        let small = vec!["{}".to_string(), "{\"type\":\"ping\"}".to_string()];
        assert_eq!(replay_has_oversize_event(&small), None);

        let large = vec!["{}".to_string(), "X".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 1)];
        assert_eq!(
            replay_has_oversize_event(&large),
            Some(WS_MAX_TEXT_MESSAGE_BYTES + 1)
        );
    }

    #[test]
    fn snapshot_preparation_dedupes_duplicate_turn_ids() {
        let mut snapshot = SessionHandle::new(
            "dupe-turns".to_string(),
            Provider::Codex,
            "/tmp/dupe-turns".into(),
        )
        .retained_state();
        snapshot.turn_diffs = vec![
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "old".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-21".to_string(),
                diff: "next".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "new".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
        ];

        let prepared = prepare_snapshot_for_transport(snapshot);
        assert_eq!(prepared.turn_diffs.len(), 2);
        assert_eq!(prepared.turn_diffs[0].turn_id, "turn-21");
        assert_eq!(prepared.turn_diffs[1].turn_id, "turn-20");
        assert_eq!(prepared.turn_diffs[1].diff, "new");
    }

    #[test]
    fn sanitize_message_appended_normalizes_managed_path_images() {
        ensure_test_data_dir();
        let session_id = "s";
        let image_dir = crate::infrastructure::paths::images_dir().join(session_id);
        std::fs::create_dir_all(&image_dir).expect("create image dir");
        let image_path = image_dir.join(format!("orbitdock-image-{}.png", new_id()));
        std::fs::write(&image_path, b"hello-image").expect("write test image");

        let message = Message {
            id: "m-path".to_string(),
            session_id: session_id.to_string(),
            sequence: None,
            message_type: MessageType::User,
            content: "send path".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "path".to_string(),
                value: image_path.to_string_lossy().to_string(),
                ..Default::default()
            }],
        };

        let sanitized = sanitize_server_message_for_transport(ServerMessage::MessageAppended {
            session_id: session_id.to_string(),
            message,
        });
        let _ = std::fs::remove_file(image_path);

        match sanitized {
            ServerMessage::MessageAppended { message, .. } => {
                assert_eq!(message.images.len(), 1);
                assert_eq!(message.images[0].input_type, "attachment");
                assert!(message.images[0].value.ends_with(".png"));
            }
            other => panic!("expected MessageAppended, got {:?}", other),
        }
    }

    #[test]
    fn sanitize_preserves_data_uri_images() {
        let message = Message {
            id: "m-data-uri".to_string(),
            session_id: "s".to_string(),
            sequence: None,
            message_type: MessageType::User,
            content: "send this".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "url".to_string(),
                value: format!("data:image/png;base64,{}", "A".repeat(5_000)),
                ..Default::default()
            }],
        };

        let sanitized = sanitize_server_message_for_transport(ServerMessage::MessageAppended {
            session_id: "s".to_string(),
            message,
        });

        match sanitized {
            ServerMessage::MessageAppended { message, .. } => {
                assert_eq!(message.images.len(), 1);
                assert_eq!(message.images[0].input_type, "url");
                assert!(message.images[0]
                    .value
                    .starts_with("data:image/png;base64,"));
            }
            other => panic!("expected MessageAppended, got {:?}", other),
        }
    }

    #[test]
    fn replay_sanitize_preserves_revision_and_normalizes_managed_path_images() {
        ensure_test_data_dir();
        let session_id = "s";
        let image_dir = crate::infrastructure::paths::images_dir().join(session_id);
        std::fs::create_dir_all(&image_dir).expect("create image dir");
        let image_path = image_dir.join(format!("orbitdock-image-{}.png", new_id()));
        std::fs::write(&image_path, b"replay-image").expect("write test image");

        let replay_json = serde_json::json!({
            "type": "message_appended",
            "revision": 42,
            "session_id": session_id,
            "message": {
                "id": "m",
                "session_id": session_id,
                "message_type": "user",
                "content": "hello",
                "is_error": false,
                "timestamp": "2026-01-01T00:00:00Z",
                "images": [{
                    "input_type": "path",
                    "value": image_path.to_string_lossy().to_string(),
                }]
            }
        });

        let sanitized = sanitize_replay_event_for_transport(&replay_json.to_string())
            .expect("sanitize replay payload");
        let _ = std::fs::remove_file(image_path);

        let decoded: serde_json::Value =
            serde_json::from_str(&sanitized).expect("decode sanitized replay");
        assert_eq!(
            decoded.get("revision").and_then(|value| value.as_u64()),
            Some(42)
        );
        assert_eq!(
            decoded
                .get("message")
                .and_then(|value| value.get("images"))
                .and_then(|value| value.as_array())
                .and_then(|images| images.first())
                .and_then(|image| image.get("input_type"))
                .and_then(|value| value.as_str()),
            Some("attachment")
        );
    }
}
