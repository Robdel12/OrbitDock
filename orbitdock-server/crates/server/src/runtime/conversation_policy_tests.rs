use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent, TurnStatus,
};

use super::*;

fn user_row(sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::User(MessageRowContent {
      id: format!("user-{sequence}"),
      content: "hello".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

#[test]
fn coherent_history_window_stays_bounded_for_tool_heavy_sessions() {
  assert_eq!(COHERENT_HISTORY_MAX_ROWS, 100);
}

#[test]
fn coherent_history_does_not_expand_when_page_has_enough_turns() {
  let rows = vec![user_row(10), user_row(11), user_row(12), user_row(13)];

  assert!(!requires_coherent_history_page(&rows, true));
}
