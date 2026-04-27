use super::*;
use orbitdock_protocol::conversation_contracts::MessageRowContent;

fn user_entry(sequence: u64, id: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
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

fn assistant_entry(
  sequence: u64,
  id: &str,
  content: &str,
  is_streaming: bool,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: id.to_string(),
      content: content.to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

#[test]
fn normalize_row_sequences_reindexes_from_zero() {
  let rows = vec![user_entry(42, "row-a"), user_entry(99, "row-b")];
  let normalized = ConversationState::normalize_row_sequences(rows);

  assert_eq!(normalized[0].sequence, 0);
  assert_eq!(normalized[1].sequence, 1);
}

#[test]
fn trim_retained_rows_keeps_only_the_newest_window() {
  let state = ConversationState::new(
    vec![
      user_entry(0, "row-a"),
      user_entry(1, "row-b"),
      user_entry(2, "row-c"),
      user_entry(3, "row-d"),
    ],
    4,
  );

  let trimmed = state.trim_retained_rows(2);

  assert_eq!(trimmed.rows.len(), 2);
  assert_eq!(trimmed.rows[0].sequence, 2);
  assert_eq!(trimmed.rows[1].sequence, 3);
}

#[test]
fn page_returns_trailing_rows_before_bound() {
  let state = ConversationState::new(
    vec![
      user_entry(0, "row-a"),
      user_entry(1, "row-b"),
      user_entry(2, "row-c"),
      user_entry(3, "row-d"),
    ],
    4,
  );

  let page = state.page(Some(4), 2);

  assert_eq!(
    page.rows.iter().map(|row| row.sequence).collect::<Vec<_>>(),
    vec![2, 3]
  );
  assert_eq!(page.oldest_sequence, Some(2));
  assert_eq!(page.newest_sequence, Some(3));
  assert!(page.has_more_before);
}

#[test]
fn latest_row_sequence_falls_back_to_total_count() {
  let empty = ConversationState::new(vec![], 0);
  assert_eq!(empty.latest_row_sequence(), 0);

  let state = ConversationState::new(vec![user_entry(3, "row-a"), user_entry(7, "row-b")], 8);
  assert_eq!(state.latest_row_sequence(), 7);
  assert_eq!(state.next_row_sequence(), 8);
}

#[test]
fn streaming_helpers_only_track_active_message_rows() {
  let summary = assistant_entry(1, "msg-1", "payload", true).to_summary();
  assert!(is_non_user_row_summary(&summary));
  assert!(is_message_row_summary(&summary));
  assert!(is_actively_streaming_message_row_summary(&summary));
  assert_eq!(streaming_message_row_summary_content_len(&summary), Some(7));
  assert!(is_actively_streaming_message_row(&assistant_entry(
    1, "msg-1", "payload", true
  )));
  assert!(!is_actively_streaming_message_row(&user_entry(1, "user-1")));
}
