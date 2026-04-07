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

  let mut counts = DashboardCounts {
    attention: 0,
    running: 0,
    ready: 0,
    direct: 0,
  };
  for c in &conversations {
    match c.list_status {
      orbitdock_protocol::SessionListStatus::Permission
      | orbitdock_protocol::SessionListStatus::Question => counts.attention += 1,
      orbitdock_protocol::SessionListStatus::Working => counts.running += 1,
      orbitdock_protocol::SessionListStatus::Reply => counts.ready += 1,
      orbitdock_protocol::SessionListStatus::Ended => {}
    }
    if is_direct_conversation(c) {
      counts.direct += 1;
    }
  }

  DashboardSnapshot {
    revision: registry.current_dashboard_revision(),
    conversations,
    counts,
  }
}
