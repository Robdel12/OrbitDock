use std::collections::BTreeMap;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;

use crate::infrastructure::persistence::load_messages_for_session;

pub(crate) fn normalize_row_sequences(rows: &mut [ConversationRowEntry]) {
  let mut next_sequence = 0_u64;
  for entry in rows {
    if entry.sequence == 0 && next_sequence > 0 {
      entry.sequence = next_sequence;
    }
    next_sequence = entry.sequence + 1;
  }
}

pub(crate) fn merge_rows_by_sequence(
  mut base: Vec<ConversationRowEntry>,
  mut overlay: Vec<ConversationRowEntry>,
) -> Vec<ConversationRowEntry> {
  normalize_row_sequences(&mut base);
  normalize_row_sequences(&mut overlay);

  let mut merged = BTreeMap::<u64, ConversationRowEntry>::new();
  for entry in base {
    merged.insert(entry.sequence, entry);
  }
  for entry in overlay {
    merged.insert(entry.sequence, entry);
  }
  merged.into_values().collect()
}

pub(crate) async fn hydrate_full_row_history(
  session_id: &str,
  retained_rows: Vec<ConversationRowEntry>,
  total_row_count: Option<u64>,
) -> Vec<ConversationRowEntry> {
  let expected_count = total_row_count.unwrap_or(retained_rows.len() as u64);
  if retained_rows.len() as u64 >= expected_count {
    return retained_rows;
  }

  match load_messages_for_session(session_id).await {
    Ok(db_rows) if !db_rows.is_empty() => merge_rows_by_sequence(db_rows, retained_rows),
    _ => retained_rows,
  }
}

#[cfg(test)]
#[path = "session_row_history_tests.rs"]
mod session_row_history_tests;
