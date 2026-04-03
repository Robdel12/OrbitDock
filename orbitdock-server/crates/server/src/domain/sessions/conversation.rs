use orbitdock_protocol::conversation_contracts::{ConversationRowEntry, RowPageSummary};
use orbitdock_protocol::SessionState;

#[derive(Debug, Clone)]
pub struct ConversationPage {
  pub rows: Vec<ConversationRowEntry>,
  pub total_row_count: u64,
  pub has_more_before: bool,
  pub oldest_sequence: Option<u64>,
  pub newest_sequence: Option<u64>,
}

impl ConversationPage {
  pub fn into_row_page_summary(self) -> RowPageSummary {
    RowPageSummary {
      rows: self
        .rows
        .iter()
        .map(|entry| entry.to_transport_summary())
        .collect(),
      total_row_count: self.total_row_count,
      has_more_before: self.has_more_before,
      oldest_sequence: self.oldest_sequence,
      newest_sequence: self.newest_sequence,
    }
  }
}

#[derive(Debug, Clone)]
pub struct ConversationBootstrap {
  pub session: SessionState,
  pub total_row_count: u64,
  pub has_more_before: bool,
  pub oldest_sequence: Option<u64>,
  pub newest_sequence: Option<u64>,
}
