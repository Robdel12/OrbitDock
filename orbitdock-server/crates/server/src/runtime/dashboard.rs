//! Dashboard snapshot construction from in-memory session state.
//!
//! This module is the ONLY entry point for building `DashboardSnapshot` from
//! live session data. It delegates to the pure projection function in
//! `domain::sessions::dashboard_projection`.

use std::collections::{HashMap, HashSet};

use orbitdock_protocol::{
  DashboardConversationItem, DashboardCounts, DashboardProjectGroup, DashboardSnapshot,
  SessionListStatus, SessionStatus,
};

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
  conversations = dedupe_conversations_by_session_id(conversations);

  let mut counts = DashboardCounts {
    attention: 0,
    running: 0,
    ready: 0,
    direct: 0,
  };
  for c in &conversations {
    match c.list_status {
      SessionListStatus::Permission | SessionListStatus::Question => counts.attention += 1,
      SessionListStatus::Working => counts.running += 1,
      SessionListStatus::Reply => counts.ready += 1,
      SessionListStatus::Ended => {}
    }
    if is_direct_conversation(c) {
      counts.direct += 1;
    }
  }

  let project_groups = build_project_groups(&conversations);

  DashboardSnapshot {
    revision: registry.current_dashboard_revision(),
    conversations,
    counts,
    project_groups,
  }
}

fn dedupe_conversations_by_session_id(
  conversations: Vec<DashboardConversationItem>,
) -> Vec<DashboardConversationItem> {
  let original_len = conversations.len();
  let mut seen_session_ids: HashSet<String> = HashSet::with_capacity(conversations.len());
  let mut deduped: Vec<DashboardConversationItem> = Vec::with_capacity(conversations.len());

  for conversation in conversations {
    if seen_session_ids.insert(conversation.session_id.clone()) {
      deduped.push(conversation);
    }
  }

  let duplicate_count = original_len.saturating_sub(deduped.len());
  if duplicate_count > 0 {
    tracing::warn!(
      component = "dashboard",
      event = "dashboard.snapshot.duplicate_session_ids",
      duplicate_count,
      "Dropped duplicate dashboard conversations by session_id"
    );
  }

  deduped
}

/// Build pre-computed project groups from conversations.
/// Groups are sorted alphabetically by name for consistent ordering.
fn build_project_groups(conversations: &[DashboardConversationItem]) -> Vec<DashboardProjectGroup> {
  // Group by (grouping_path, endpoint_id) — for now endpoint_id is fixed since
  // DashboardConversationItem doesn't carry it yet.
  let endpoint_id = "default".to_string();

  let mut groups: HashMap<String, ProjectGroupBuilder> = HashMap::new();

  for conv in conversations {
    let path = conv
      .grouping_path
      .as_deref()
      .unwrap_or(&conv.project_path)
      .to_string();
    let name = conv
      .grouping_name
      .as_deref()
      .or(conv.project_name.as_deref())
      .unwrap_or_else(|| path.rsplit('/').next().unwrap_or(&path))
      .to_string();

    let builder = groups
      .entry(path.clone())
      .or_insert_with(|| ProjectGroupBuilder {
        path: path.clone(),
        name,
        endpoint_id: endpoint_id.clone(),
        endpoint_name: None,
        attention_count: 0,
        working_count: 0,
        ready_count: 0,
        session_ids: Vec::new(),
        last_activity_at: None,
      });

    builder.session_ids.push(conv.session_id.clone());

    match conv.list_status {
      SessionListStatus::Permission | SessionListStatus::Question => builder.attention_count += 1,
      SessionListStatus::Working => builder.working_count += 1,
      SessionListStatus::Reply => builder.ready_count += 1,
      SessionListStatus::Ended => {}
    }

    if let Some(ref activity) = conv.last_activity_at {
      if builder
        .last_activity_at
        .as_ref()
        .is_none_or(|cur| activity > cur)
      {
        builder.last_activity_at = Some(activity.clone());
      }
    }
  }

  let mut result: Vec<DashboardProjectGroup> = groups
    .into_values()
    .map(|b| DashboardProjectGroup {
      path: b.path,
      name: b.name,
      endpoint_id: b.endpoint_id,
      endpoint_name: b.endpoint_name,
      attention_count: b.attention_count,
      working_count: b.working_count,
      ready_count: b.ready_count,
      session_ids: b.session_ids,
      last_activity_at: b.last_activity_at,
    })
    .collect();

  // Sort alphabetically by name for consistent ordering
  result.sort_by_key(|group| group.name.to_lowercase());

  result
}

struct ProjectGroupBuilder {
  path: String,
  name: String,
  endpoint_id: String,
  endpoint_name: Option<String>,
  attention_count: u32,
  working_count: u32,
  ready_count: u32,
  session_ids: Vec<String>,
  last_activity_at: Option<String>,
}

#[cfg(test)]
#[path = "dashboard_tests.rs"]
mod dashboard_tests;
