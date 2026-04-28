use orbitdock_protocol::conversation_contracts::ConversationRowEntry;

use super::SessionCoreState;

pub(crate) fn is_local_http_row_id(row_id: &str) -> bool {
  row_id.starts_with("user-http-") || row_id.starts_with("steer-http-")
}

pub(crate) fn latest_transcript_synced_row_id(rows: &[ConversationRowEntry]) -> Option<String> {
  rows
    .iter()
    .rev()
    .find(|row| !is_local_http_row_id(row.id()))
    .map(|row| row.id().to_string())
}

impl SessionCoreState {
  #[cfg(test)]
  pub fn newest_synced_row_id(&self) -> Option<&str> {
    self.newest_synced_row_id.as_deref()
  }

  #[cfg(test)]
  pub fn set_newest_synced_row_id(&mut self, id: Option<String>) {
    self.newest_synced_row_id = id;
  }
}
