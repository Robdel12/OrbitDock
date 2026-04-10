//! Pure conversation-state helpers.
//!
//! This module keeps row sequencing, retention, paging, and row-classification
//! logic separate from the mutable session shell.

#[cfg(test)]
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::conversation_contracts::{
  ConversationRowEntry, ConversationRowSummary, RowEntrySummary,
};
#[cfg(test)]
use orbitdock_protocol::SessionState;

#[cfg(test)]
use super::conversation::{ConversationBootstrap, ConversationPage};

#[derive(Debug, Clone, Default)]
pub struct ConversationState {
  pub rows: Vec<ConversationRowEntry>,
  pub total_row_count: u64,
}

impl ConversationState {
  pub fn new(rows: Vec<ConversationRowEntry>, total_row_count: u64) -> Self {
    Self {
      rows,
      total_row_count,
    }
  }

  #[cfg(test)]
  pub fn next_row_sequence(&self) -> u64 {
    self
      .rows
      .last()
      .map(|entry| entry.sequence + 1)
      .unwrap_or(self.total_row_count)
  }

  #[cfg(test)]
  pub fn latest_row_sequence(&self) -> u64 {
    self
      .rows
      .last()
      .map(|entry| entry.sequence)
      .unwrap_or_else(|| self.total_row_count.saturating_sub(1))
  }

  pub fn normalize_row_sequences(mut rows: Vec<ConversationRowEntry>) -> Vec<ConversationRowEntry> {
    for (index, entry) in rows.iter_mut().enumerate() {
      entry.sequence = index as u64;
    }
    rows
  }

  pub fn trim_retained_rows(mut self, retained_finalized_row_limit: usize) -> Self {
    let Some(newest_sequence) = self.rows.last().map(|entry| entry.sequence) else {
      return self;
    };
    let Some(oldest_allowed_sequence) = newest_sequence
      .checked_add(1)
      .and_then(|count| count.checked_sub(retained_finalized_row_limit as u64))
    else {
      return self;
    };

    self
      .rows
      .retain(|entry| entry.sequence >= oldest_allowed_sequence);
    self
  }

  #[cfg(test)]
  pub fn page(&self, before_sequence: Option<u64>, limit: usize) -> ConversationPage {
    if self.rows.is_empty() || limit == 0 {
      return ConversationPage {
        rows: vec![],
        total_row_count: self.total_row_count,
        has_more_before: false,
        oldest_sequence: None,
        newest_sequence: None,
      };
    }

    let upper_bound = before_sequence.unwrap_or(u64::MAX);
    let mut page: Vec<ConversationRowEntry> = self
      .rows
      .iter()
      .filter(|entry| entry.sequence < upper_bound)
      .rev()
      .take(limit)
      .cloned()
      .collect();
    page.reverse();

    let oldest_sequence = page.first().map(|entry| entry.sequence);
    let newest_sequence = page.last().map(|entry| entry.sequence);
    let has_more_before = oldest_sequence.is_some_and(|sequence| sequence > 0);

    ConversationPage {
      rows: page,
      total_row_count: self.total_row_count,
      has_more_before,
      oldest_sequence,
      newest_sequence,
    }
  }

  #[cfg(test)]
  pub fn bootstrap(&self, session: SessionState, limit: usize) -> ConversationBootstrap {
    let page = self.page(None, limit);
    ConversationBootstrap {
      session,
      total_row_count: page.total_row_count,
      has_more_before: page.has_more_before,
      oldest_sequence: page.oldest_sequence,
      newest_sequence: page.newest_sequence,
    }
  }
}

pub fn is_non_user_row(entry: &ConversationRowEntry) -> bool {
  !entry.row.is_user_input()
}

pub fn is_non_user_row_summary(entry: &RowEntrySummary) -> bool {
  !matches!(
    entry.row,
    ConversationRowSummary::User(_) | ConversationRowSummary::Steer(_)
  )
}

pub fn is_message_row_summary(entry: &RowEntrySummary) -> bool {
  matches!(
    entry.row,
    ConversationRowSummary::User(_)
      | ConversationRowSummary::Steer(_)
      | ConversationRowSummary::Assistant(_)
      | ConversationRowSummary::Thinking(_)
      | ConversationRowSummary::System(_)
  )
}

#[cfg(test)]
pub fn is_actively_streaming_message_row(entry: &ConversationRowEntry) -> bool {
  matches!(
    &entry.row,
    ConversationRow::Assistant(msg) | ConversationRow::Thinking(msg) | ConversationRow::System(msg)
      if msg.is_streaming
  )
}

pub fn is_actively_streaming_message_row_summary(entry: &RowEntrySummary) -> bool {
  matches!(
    &entry.row,
    ConversationRowSummary::Assistant(msg)
      | ConversationRowSummary::Thinking(msg)
      | ConversationRowSummary::System(msg)
      if msg.is_streaming
  )
}

pub fn streaming_message_row_summary_content_len(entry: &RowEntrySummary) -> Option<usize> {
  match &entry.row {
    ConversationRowSummary::Assistant(msg)
    | ConversationRowSummary::Thinking(msg)
    | ConversationRowSummary::System(msg) => Some(msg.content.chars().count()),
    _ => None,
  }
}

#[cfg(test)]
mod tests {
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
}
