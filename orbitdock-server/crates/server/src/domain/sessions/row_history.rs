use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, RowEntrySummary, TurnStatus,
};

use super::super::conversation_state::{
  is_non_user_row, is_non_user_row_summary, ConversationState,
};
use super::row_sequence::next_row_sequence;
use super::transcript_anchor::{is_local_http_row_id, latest_transcript_synced_row_id};
use super::SessionCoreState;

impl SessionCoreState {
  pub fn conversation_state(&self) -> ConversationState {
    ConversationState::new(self.rows.clone(), self.total_row_count)
  }

  pub(super) fn trim_retained_rows(&mut self) {
    let state = ConversationState::new(std::mem::take(&mut self.rows), self.total_row_count)
      .trim_retained_rows(super::RETAINED_FINALIZED_ROW_LIMIT);
    self.rows = state.rows;
    self.total_row_count = state.total_row_count;
  }

  pub fn has_user_row_with_content(&self, content: &str) -> bool {
    self
      .rows
      .iter()
      .rev()
      .take(5)
      .any(|entry| match &entry.row {
        ConversationRow::User(row) => row.content == content,
        ConversationRow::Steer(_) => false,
        _ => false,
      })
  }

  pub fn add_row(
    &mut self,
    mut entry: ConversationRowEntry,
    has_active_viewers: bool,
  ) -> ConversationRowEntry {
    let counts_as_progress = is_non_user_row(&entry);
    if entry.sequence == 0
      && self
        .rows
        .last()
        .is_none_or(|last| last.sequence >= entry.sequence)
    {
      entry.sequence = next_row_sequence(&self.rows, self.total_row_count);
    }
    if is_non_user_row(&entry) && !has_active_viewers {
      self.unread_count += 1;
    }
    if !is_local_http_row_id(entry.id()) {
      self.newest_synced_row_id = Some(entry.id().to_string());
    }
    self.rows.push(entry.clone());
    self.total_row_count = self.total_row_count.saturating_add(1);
    self.trim_retained_rows();
    let now = crate::support::session_time::chrono_now();
    self.timestamps.last_activity_at = Some(now.clone());
    if counts_as_progress {
      self.timestamps.last_progress_at = Some(now);
    }
    entry
  }

  pub fn unread_count_after_row_append(
    &self,
    entry: &ConversationRowEntry,
    has_active_viewers: bool,
  ) -> Option<u64> {
    (is_non_user_row(entry) && !has_active_viewers).then_some(self.unread_count)
  }

  pub fn upsert_row(&mut self, mut entry: ConversationRowEntry) -> ConversationRowEntry {
    let entry_id = entry.id().to_string();
    let counts_as_progress = is_non_user_row(&entry);
    if let Some(pos) = self.rows.iter().position(|r| r.id() == entry_id) {
      if entry.sequence == 0 {
        entry.sequence = self.rows[pos].sequence;
      }
      self.rows[pos] = entry.clone();
      if pos == self.rows.len() - 1 && !is_local_http_row_id(&entry_id) {
        self.newest_synced_row_id = Some(entry_id);
      }
      let now = crate::support::session_time::chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      entry
    } else {
      if entry.sequence == 0
        && self
          .rows
          .last()
          .is_none_or(|last| last.sequence >= entry.sequence)
      {
        entry.sequence = next_row_sequence(&self.rows, self.total_row_count);
      }
      if !is_local_http_row_id(entry.id()) {
        self.newest_synced_row_id = Some(entry.id().to_string());
      }
      self.rows.push(entry.clone());
      if self.rows.len() as u64 > self.total_row_count {
        self.total_row_count = self.rows.len() as u64;
      }
      self.trim_retained_rows();
      let now = crate::support::session_time::chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      entry
    }
  }

  pub fn note_transition_row_append(
    &mut self,
    entry: &RowEntrySummary,
    has_active_viewers: bool,
  ) -> Option<u64> {
    if !is_non_user_row_summary(entry) || has_active_viewers {
      return None;
    }
    self.unread_count += 1;
    Some(self.unread_count)
  }

  pub fn mark_read(&mut self) -> u64 {
    let prev = self.unread_count;
    self.unread_count = 0;
    prev
  }

  pub fn mark_last_turns_status(&mut self, num_turns: u32, status: TurnStatus) -> Vec<String> {
    if self.rows.is_empty() || num_turns == 0 {
      return vec![];
    }

    let mut user_rows_seen: u32 = 0;
    let mut cut_index = self.rows.len();
    for (i, entry) in self.rows.iter().enumerate().rev() {
      if matches!(entry.row, ConversationRow::User(_)) {
        user_rows_seen += 1;
        if user_rows_seen >= num_turns {
          cut_index = i;
          break;
        }
      }
    }

    let mut affected_ids = Vec::new();
    for entry in &mut self.rows[cut_index..] {
      if entry.turn_status != status {
        entry.turn_status = status;
        affected_ids.push(entry.id().to_string());
      }
    }
    affected_ids
  }

  pub fn replace_rows(&mut self, rows: Vec<ConversationRowEntry>) {
    let rows = ConversationState::normalize_row_sequences(rows);
    self.newest_synced_row_id = latest_transcript_synced_row_id(&rows);
    self.total_row_count = rows.len() as u64;
    self.rows = rows;
    self.trim_retained_rows();
    self.timestamps.last_progress_at = Some(crate::support::session_time::chrono_now());
  }
}
