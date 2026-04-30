use std::path::Path;
use std::sync::atomic::Ordering;
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

  pub fn publish_active_sessions_invalidation_for_session(&self, session_id: &str) {
    if !self.sessions.contains_key(session_id) {
      return;
    }
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    self.publish_library_invalidation();
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::ActiveSessionsInvalidated { revision });
  }

  pub fn publish_active_sessions_invalidation(&self) {
    self.publish_sessions_summary_invalidation();
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    self.publish_library_invalidation();
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::ActiveSessionsInvalidated { revision });
  }

  pub fn notify_active_session_updated(&self, _session_id: &str) {
    self.publish_sessions_summary_invalidation();
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    self.publish_library_invalidation();
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::ActiveSessionsInvalidated { revision });
  }

  pub fn publish_active_session_removed(&self, _session_id: &str) {
    self.publish_sessions_summary_invalidation();
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    self.publish_library_invalidation();
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::ActiveSessionsInvalidated { revision });
  }

  pub fn broadcast_to_list(&self, msg: orbitdock_protocol::ServerMessage) {
    let _ = self.list_tx.send(msg);
  }

  pub fn list_tx(&self) -> tokio::sync::broadcast::Sender<orbitdock_protocol::ServerMessage> {
    self.list_tx.clone()
  }

  pub async fn list_recent_projects(&self) -> Vec<RecentProject> {
    let removed_worktree_paths =
      crate::infrastructure::persistence::load_removed_worktree_paths(&self.db_path);
    let persisted_projects = crate::infrastructure::persistence::load_recent_projects_from_sessions(
      &self.db_path,
      &removed_worktree_paths,
    );
    if !persisted_projects.is_empty() {
      return persisted_projects;
    }

    let sessions = self.sessions.iter().filter_map(|entry| {
      let snap = entry.value().snapshot();
      if snap.mission_id.is_some() {
        return None;
      }
      if snap.is_worktree && !Path::new(&snap.project_path).exists() {
        return None;
      }
      Some((snap.project_path.clone(), snap.last_activity_at.clone()))
    });
    collect_recent_projects(sessions, &removed_worktree_paths)
  }
}
