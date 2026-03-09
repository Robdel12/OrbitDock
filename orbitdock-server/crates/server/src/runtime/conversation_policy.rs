use orbitdock_protocol::{Message, MessageType};

use crate::domain::sessions::conversation::ConversationPage;

const COHERENT_HISTORY_MIN_TURNS: usize = 4;
pub(crate) const COHERENT_HISTORY_MAX_MESSAGES: usize = 200;

pub(crate) fn normalize_message_sequences(messages: &mut [Message]) {
    let mut next_sequence = 0_u64;
    for message in messages {
        let sequence = message.sequence.unwrap_or(next_sequence);
        message.sequence = Some(sequence);
        next_sequence = sequence + 1;
    }
}

pub(crate) fn conversation_page_from_messages(
    mut messages: Vec<Message>,
    before_sequence: Option<u64>,
    limit: usize,
) -> ConversationPage {
    normalize_message_sequences(&mut messages);
    let total_message_count = messages.len() as u64;
    if messages.is_empty() || limit == 0 {
        return ConversationPage {
            messages: vec![],
            total_message_count,
            has_more_before: false,
            oldest_sequence: None,
            newest_sequence: None,
        };
    }

    let upper_bound = before_sequence.unwrap_or(u64::MAX);
    let mut page: Vec<Message> = messages
        .into_iter()
        .filter(|message| message.sequence.unwrap_or(u64::MAX) < upper_bound)
        .rev()
        .take(limit)
        .collect();
    page.reverse();

    conversation_page_with_total(page, total_message_count)
}

pub(crate) fn conversation_page_with_total(
    messages: Vec<Message>,
    total_message_count: u64,
) -> ConversationPage {
    let oldest_sequence = messages.first().and_then(|message| message.sequence);
    let newest_sequence = messages.last().and_then(|message| message.sequence);
    let has_more_before = oldest_sequence.is_some_and(|sequence| sequence > 0);
    ConversationPage {
        messages,
        total_message_count,
        has_more_before,
        oldest_sequence,
        newest_sequence,
    }
}

pub(crate) fn requires_coherent_history_page(messages: &[Message], has_more_before: bool) -> bool {
    if !has_more_before || messages.is_empty() {
        return false;
    }

    if !messages.first().is_some_and(message_starts_turn) {
        return true;
    }

    let turn_count = messages
        .iter()
        .filter(|message| message_starts_turn(message))
        .count();
    turn_count < COHERENT_HISTORY_MIN_TURNS
}

pub(crate) fn prepend_conversation_page(
    current: ConversationPage,
    older: ConversationPage,
) -> ConversationPage {
    if older.messages.is_empty() {
        return current;
    }

    let mut messages = older.messages;
    messages.extend(current.messages);

    ConversationPage {
        total_message_count: current.total_message_count.max(older.total_message_count),
        has_more_before: older.has_more_before,
        oldest_sequence: messages.first().and_then(|message| message.sequence),
        newest_sequence: messages.last().and_then(|message| message.sequence),
        messages,
    }
}

pub(crate) fn expected_page_message_count(
    total_message_count: u64,
    before_sequence: Option<u64>,
    limit: usize,
) -> usize {
    let max_available = before_sequence
        .and_then(|sequence| usize::try_from(sequence).ok())
        .unwrap_or(usize::MAX);
    limit.min(max_available).min(total_message_count as usize)
}

fn message_starts_turn(message: &Message) -> bool {
    matches!(message.message_type, MessageType::User | MessageType::Steer)
}

#[cfg(test)]
mod tests {
    use orbitdock_protocol::{Message, MessageType};

    use super::{
        conversation_page_from_messages, conversation_page_with_total, expected_page_message_count,
        normalize_message_sequences, prepend_conversation_page, requires_coherent_history_page,
    };

    fn test_message(id: &str, sequence: Option<u64>, message_type: MessageType) -> Message {
        Message {
            id: id.to_string(),
            session_id: "session-1".to_string(),
            message_type,
            content: id.to_string(),
            timestamp: "2026-03-09T00:00:00Z".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            duration_ms: None,
            is_error: false,
            is_in_progress: false,
            sequence,
            images: vec![],
        }
    }

    #[test]
    fn normalize_sequences_fills_missing_values_in_order() {
        let mut messages = vec![
            test_message("a", None, MessageType::User),
            test_message("b", Some(4), MessageType::Assistant),
            test_message("c", None, MessageType::Assistant),
        ];

        normalize_message_sequences(&mut messages);

        assert_eq!(messages[0].sequence, Some(0));
        assert_eq!(messages[1].sequence, Some(4));
        assert_eq!(messages[2].sequence, Some(5));
    }

    #[test]
    fn conversation_page_from_messages_applies_limit_and_before_sequence() {
        let messages = vec![
            test_message("a", Some(0), MessageType::User),
            test_message("b", Some(1), MessageType::Assistant),
            test_message("c", Some(2), MessageType::User),
            test_message("d", Some(3), MessageType::Assistant),
        ];

        let page = conversation_page_from_messages(messages, Some(3), 2);

        assert_eq!(page.messages.len(), 2);
        assert_eq!(page.oldest_sequence, Some(1));
        assert_eq!(page.newest_sequence, Some(2));
        assert!(page.has_more_before);
    }

    #[test]
    fn coherent_history_requires_turn_boundary_and_minimum_turns() {
        let mid_turn = vec![
            test_message("a", Some(3), MessageType::Assistant),
            test_message("b", Some(4), MessageType::Tool),
        ];
        let short_tail = vec![
            test_message("a", Some(4), MessageType::User),
            test_message("b", Some(5), MessageType::Assistant),
            test_message("c", Some(6), MessageType::User),
        ];
        let coherent = vec![
            test_message("a", Some(7), MessageType::User),
            test_message("b", Some(8), MessageType::Assistant),
            test_message("c", Some(9), MessageType::User),
            test_message("d", Some(10), MessageType::Assistant),
            test_message("e", Some(11), MessageType::User),
            test_message("f", Some(12), MessageType::Assistant),
            test_message("g", Some(13), MessageType::User),
        ];

        assert!(requires_coherent_history_page(&mid_turn, true));
        assert!(requires_coherent_history_page(&short_tail, true));
        assert!(!requires_coherent_history_page(&coherent, true));
        assert!(!requires_coherent_history_page(&coherent, false));
    }

    #[test]
    fn prepend_conversation_page_keeps_order_and_updates_metadata() {
        let older = conversation_page_with_total(
            vec![
                test_message("a", Some(0), MessageType::User),
                test_message("b", Some(1), MessageType::Assistant),
            ],
            6,
        );
        let current = conversation_page_with_total(
            vec![
                test_message("c", Some(2), MessageType::User),
                test_message("d", Some(3), MessageType::Assistant),
            ],
            4,
        );

        let merged = prepend_conversation_page(current, older);

        assert_eq!(merged.messages.len(), 4);
        assert_eq!(merged.oldest_sequence, Some(0));
        assert_eq!(merged.newest_sequence, Some(3));
        assert_eq!(merged.total_message_count, 6);
    }

    #[test]
    fn expected_page_count_respects_limit_total_and_before_sequence() {
        assert_eq!(expected_page_message_count(10, None, 3), 3);
        assert_eq!(expected_page_message_count(2, None, 5), 2);
        assert_eq!(expected_page_message_count(10, Some(2), 5), 2);
        assert_eq!(expected_page_message_count(10, Some(0), 5), 0);
    }
}
