use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};

use super::*;

fn user_row(id: &str, sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
      content: format!("row-{sequence}"),
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
fn normalize_row_sequences_reindexes_zero_sequences_after_the_first_row() {
  let mut rows = vec![
    user_row("row-1", 0),
    user_row("row-2", 0),
    user_row("row-3", 2),
    user_row("row-4", 0),
  ];

  normalize_row_sequences(&mut rows);

  let sequences: Vec<u64> = rows.into_iter().map(|row| row.sequence).collect();
  assert_eq!(sequences, vec![0, 1, 2, 3]);
}

#[test]
fn merge_rows_by_sequence_overlays_matching_sequences() {
  let base = vec![user_row("base-0", 0), user_row("base-1", 1)];
  let overlay = vec![user_row("overlay-1", 1), user_row("overlay-2", 2)];

  let merged = merge_rows_by_sequence(base, overlay);

  let ids: Vec<String> = merged
    .iter()
    .map(|row| match &row.row {
      ConversationRow::User(message) => message.id.clone(),
      _ => unreachable!("expected user row"),
    })
    .collect();
  assert_eq!(ids, vec!["base-0", "overlay-1", "overlay-2"]);
}

#[tokio::test]
async fn hydrate_full_row_history_returns_retained_rows_when_history_is_complete() {
  let retained_rows = vec![user_row("row-1", 0), user_row("row-2", 1)];

  let hydrated = hydrate_full_row_history("session-1", retained_rows.clone(), Some(2)).await;

  assert_eq!(hydrated, retained_rows);
}
