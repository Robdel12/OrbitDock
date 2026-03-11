use orbitdock_protocol::{Message, MessageType, ServerMessage, StateChanges};

/// Inject approval_version into approval-related transport messages so clients
/// can ignore stale events.
pub(crate) fn inject_approval_version(msg: &mut ServerMessage, version: u64) {
    match msg {
        ServerMessage::ApprovalRequested {
            approval_version, ..
        } => {
            *approval_version = Some(version);
        }
        ServerMessage::SessionDelta { changes, .. } => {
            if changes.pending_approval.is_some() && changes.approval_version.is_none() {
                changes.approval_version = Some(version);
            }
        }
        _ => {}
    }
}

fn completed_conversation_message_snippet(message: &Message) -> Option<String> {
    if !matches!(
        message.message_type,
        MessageType::User | MessageType::Assistant
    ) {
        return None;
    }
    if message.is_in_progress {
        return None;
    }
    Some(message.content.chars().take(200).collect())
}

pub(crate) fn latest_completed_conversation_message(messages: &[Message]) -> Option<String> {
    messages
        .iter()
        .rev()
        .find_map(completed_conversation_message_snippet)
}

pub(crate) fn should_increment_unread_for_message(message: &Message) -> bool {
    !matches!(message.message_type, MessageType::User | MessageType::Steer)
}

pub(crate) fn message_append_delta(
    previous_last_message: Option<&str>,
    message: &Message,
    unread_count: u64,
) -> Option<StateChanges> {
    let last_message = completed_conversation_message_snippet(message)
        .filter(|snippet| previous_last_message != Some(snippet.as_str()))
        .map(Some);
    let unread_count = should_increment_unread_for_message(message).then_some(unread_count);

    if last_message.is_none() && unread_count.is_none() {
        return None;
    }

    Some(StateChanges {
        last_message,
        unread_count,
        ..Default::default()
    })
}

pub(crate) fn transition_delta(
    previous_last_message: Option<&str>,
    messages: &[Message],
    unread_count: Option<u64>,
) -> Option<StateChanges> {
    let last_message = latest_completed_conversation_message(messages)
        .filter(|snippet| previous_last_message != Some(snippet.as_str()))
        .map(Some);

    if last_message.is_none() && unread_count.is_none() {
        return None;
    }

    Some(StateChanges {
        last_message,
        unread_count,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::{
        inject_approval_version, message_append_delta, should_increment_unread_for_message,
        transition_delta,
    };
    use orbitdock_protocol::{
        ApprovalRequest, ApprovalType, Message, MessageType, ServerMessage, StateChanges,
    };

    fn message(message_type: MessageType, content: &str, is_in_progress: bool) -> Message {
        Message {
            id: "message-1".to_string(),
            session_id: "session-1".to_string(),
            sequence: Some(1),
            message_type,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress,
            timestamp: "123Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    #[test]
    fn message_append_delta_updates_last_message_and_unread_for_completed_assistant_message() {
        let changes = message_append_delta(
            None,
            &message(MessageType::Assistant, "hello from assistant", false),
            3,
        )
        .expect("expected delta");

        assert_eq!(
            changes.last_message,
            Some(Some("hello from assistant".to_string()))
        );
        assert_eq!(changes.unread_count, Some(3));
    }

    #[test]
    fn message_append_delta_skips_last_message_for_in_progress_updates() {
        let changes = message_append_delta(
            Some("existing"),
            &message(MessageType::Assistant, "streaming", true),
            2,
        )
        .expect("expected unread delta");

        assert_eq!(changes.last_message, None);
        assert_eq!(changes.unread_count, Some(2));
    }

    #[test]
    fn transition_delta_updates_only_when_user_visible_state_changes() {
        let changes = transition_delta(
            Some("older"),
            &[message(MessageType::Assistant, "new reply", false)],
            Some(4),
        )
        .expect("expected delta");

        assert_eq!(changes.last_message, Some(Some("new reply".to_string())));
        assert_eq!(changes.unread_count, Some(4));

        assert!(transition_delta(
            Some("new reply"),
            &[message(MessageType::Assistant, "new reply", false)],
            None,
        )
        .is_none());
    }

    #[test]
    fn unread_policy_only_counts_non_user_non_steer_messages() {
        assert!(!should_increment_unread_for_message(&message(
            MessageType::User,
            "hi",
            false,
        )));
        assert!(!should_increment_unread_for_message(&message(
            MessageType::Steer,
            "guide",
            false,
        )));
        assert!(should_increment_unread_for_message(&message(
            MessageType::Assistant,
            "reply",
            false,
        )));
    }

    #[test]
    fn inject_approval_version_only_touches_approval_related_messages() {
        let mut approval = ServerMessage::ApprovalRequested {
            session_id: "session-1".to_string(),
            request: ApprovalRequest {
                id: "req-1".to_string(),
                session_id: "session-1".to_string(),
                approval_type: ApprovalType::Exec,
                command: Some("echo hi".to_string()),
                tool_name: None,
                tool_input: None,
                file_path: None,
                diff: None,
                question: None,
                question_prompts: vec![],
                preview: None,
                permission_reason: None,
                requested_permissions: None,
                granted_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
            },
            approval_version: None,
        };
        inject_approval_version(&mut approval, 9);
        match approval {
            ServerMessage::ApprovalRequested {
                approval_version, ..
            } => assert_eq!(approval_version, Some(9)),
            _ => unreachable!(),
        }

        let mut delta = ServerMessage::SessionDelta {
            session_id: "session-1".to_string(),
            changes: StateChanges {
                pending_approval: Some(None),
                ..Default::default()
            },
        };
        inject_approval_version(&mut delta, 5);
        match delta {
            ServerMessage::SessionDelta { changes, .. } => {
                assert_eq!(changes.approval_version, Some(5));
            }
            _ => unreachable!(),
        }
    }
}
