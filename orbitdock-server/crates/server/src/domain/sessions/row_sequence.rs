use orbitdock_protocol::conversation_contracts::ConversationRowEntry;

use super::SessionCoreState;

pub(crate) fn next_row_sequence(rows: &[ConversationRowEntry], total_row_count: u64) -> u64 {
  rows
    .last()
    .map(|entry| entry.sequence + 1)
    .unwrap_or(total_row_count)
}

pub(crate) fn latest_row_sequence(rows: &[ConversationRowEntry], total_row_count: u64) -> u64 {
  rows
    .last()
    .map(|entry| entry.sequence)
    .unwrap_or_else(|| total_row_count.saturating_sub(1))
}

pub(crate) fn row_by_id<'a>(
  rows: &'a [ConversationRowEntry],
  row_id: &str,
) -> Option<&'a ConversationRowEntry> {
  rows.iter().find(|entry| entry.id() == row_id)
}

pub(crate) fn set_row_sequence(rows: &mut [ConversationRowEntry], row_id: &str, sequence: u64) {
  if let Some(entry) = rows.iter_mut().find(|entry| entry.id() == row_id) {
    entry.sequence = sequence;
  }
}

impl SessionCoreState {
  pub fn latest_row_sequence(&self) -> u64 {
    latest_row_sequence(&self.rows, self.total_row_count)
  }

  pub fn set_row_sequence(&mut self, row_id: &str, sequence: u64) {
    set_row_sequence(&mut self.rows, row_id, sequence);
  }

  pub fn row_by_id(&self, row_id: &str) -> Option<&ConversationRowEntry> {
    row_by_id(&self.rows, row_id)
  }
}
