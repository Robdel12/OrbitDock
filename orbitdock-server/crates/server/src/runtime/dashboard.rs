//! Dashboard snapshot construction from in-memory session state.
//!
//! This module is the ONLY entry point for building `DashboardSnapshot` from
//! live session data. It delegates to the pure projection function in
//! `domain::sessions::dashboard_projection`.

use orbitdock_protocol::{DashboardCounts, DashboardSnapshot, SessionStatus};

use crate::domain::sessions::dashboard_projection::{
  dashboard_item_from_snapshot, dashboard_priority, is_direct_conversation,
};
use crate::runtime::session_registry::SessionRegistry;

/// Build a complete DashboardSnapshot from all active in-memory session snapshots.
/// No DB access — reads only from the lock-free ArcSwap snapshots.
pub fn dashboard_snapshot_from_registry(registry: &SessionRegistry) -> DashboardSnapshot {
  let mut conversations: Vec<_> = registry
    .iter_sessions()
    .filter(|entry| entry.value().snapshot().status == SessionStatus::Active)
    .map(|entry| dashboard_item_from_snapshot(&entry.value().snapshot()))
    .collect();

  conversations.sort_by(|lhs, rhs| {
    dashboard_priority(lhs)
      .cmp(&dashboard_priority(rhs))
      .then_with(|| rhs.last_activity_at.cmp(&lhs.last_activity_at))
      .then_with(|| lhs.display_title.cmp(&rhs.display_title))
  });

  let counts = DashboardCounts {
    attention: conversations
      .iter()
      .filter(|c| {
        matches!(
          c.list_status,
          orbitdock_protocol::SessionListStatus::Permission
            | orbitdock_protocol::SessionListStatus::Question
        )
      })
      .count() as u32,
    running: conversations
      .iter()
      .filter(|c| {
        matches!(
          c.list_status,
          orbitdock_protocol::SessionListStatus::Working
        )
      })
      .count() as u32,
    ready: conversations
      .iter()
      .filter(|c| matches!(c.list_status, orbitdock_protocol::SessionListStatus::Reply))
      .count() as u32,
    direct: conversations
      .iter()
      .filter(|c| is_direct_conversation(c))
      .count() as u32,
  };

  DashboardSnapshot {
    revision: registry.current_dashboard_revision(),
    conversations,
    counts,
  }
}
