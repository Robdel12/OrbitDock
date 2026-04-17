use std::sync::atomic::Ordering;

use orbitdock_protocol::ServerMessage;

use super::SessionRegistry;

impl SessionRegistry {
  pub fn current_library_revision(&self) -> u64 {
    self.library_revision.load(Ordering::Relaxed)
  }

  pub fn library_revision_counter(&self) -> std::sync::Arc<std::sync::atomic::AtomicU64> {
    self.library_revision.clone()
  }

  pub fn publish_library_invalidation(&self) {
    let revision = self.library_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self
      .list_tx
      .send(ServerMessage::ArchivedSessionsInvalidated { revision });
  }
}
