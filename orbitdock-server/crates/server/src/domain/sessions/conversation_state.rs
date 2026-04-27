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
use super::conversation::ConversationBootstrap;
use super::conversation::ConversationPage;

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
#[path = "conversation_state_tests.rs"]
mod conversation_state_tests;
