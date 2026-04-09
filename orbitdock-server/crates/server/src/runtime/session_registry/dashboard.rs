use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use orbitdock_protocol::{DashboardSnapshot, RecentProject};

use super::recent_projects::collect_recent_projects;
use super::SessionRegistry;

impl SessionRegistry {
  pub fn current_dashboard_revision(&self) -> u64 {
    self.dashboard_revision.load(Ordering::Relaxed)
  }

  pub fn cached_dashboard_snapshot(&self) -> Arc<(u64, DashboardSnapshot)> {
    let current_rev = self.current_dashboard_revision();
    let cached = self.dashboard_cache.load_full();
    if cached.0 == current_rev {
      return cached;
    }
    let snapshot = crate::runtime::dashboard::dashboard_snapshot_from_registry(self);
    let entry = Arc::new((snapshot.revision, snapshot));
    self.dashboard_cache.store(Arc::clone(&entry));
    entry
  }

  pub fn publish_dashboard_conversation_updated(&self, session_id: &str) {
    let Some(entry) = self.sessions.get(session_id) else {
      return;
    };
    let snap = entry.value().snapshot();
    let item = crate::domain::sessions::dashboard_projection::dashboard_item_from_snapshot(&snap);
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self.list_tx.send(
      orbitdock_protocol::ServerMessage::DashboardConversationUpdated {
        revision,
        item: Box::new(item),
      },
    );
  }

  pub fn publish_dashboard_snapshot(&self) {
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::DashboardInvalidated { revision });
  }

  pub fn notify_dashboard_session_updated(&self, session_id: &str) {
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    if let Some(entry) = self.sessions.get(session_id) {
      let snap = entry.value().snapshot();
      let item = crate::domain::sessions::dashboard_projection::dashboard_item_from_snapshot(&snap);
      let _ = self.list_tx.send(
        orbitdock_protocol::ServerMessage::DashboardConversationUpdated {
          revision,
          item: Box::new(item),
        },
      );
    } else {
      let _ = self
        .list_tx
        .send(orbitdock_protocol::ServerMessage::DashboardInvalidated { revision });
    }
  }

  pub fn broadcast_to_list(&self, msg: orbitdock_protocol::ServerMessage) {
    let _ = self.list_tx.send(msg);
  }

  pub fn list_tx(&self) -> tokio::sync::broadcast::Sender<orbitdock_protocol::ServerMessage> {
    self.list_tx.clone()
  }

  pub fn dashboard_revision_counter(&self) -> Arc<AtomicU64> {
    self.dashboard_revision.clone()
  }

  pub async fn list_recent_projects(&self) -> Vec<RecentProject> {
    let removed_worktree_paths =
      crate::infrastructure::persistence::load_removed_worktree_paths(&self.db_path);
    let sessions = self.sessions.iter().map(|entry| {
      let snap = entry.value().snapshot();
      (snap.project_path.clone(), snap.last_activity_at.clone())
    });
    collect_recent_projects(sessions, &removed_worktree_paths)
  }
}
