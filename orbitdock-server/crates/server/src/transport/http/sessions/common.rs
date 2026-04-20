use axum::{http::StatusCode, Json};
use orbitdock_protocol::{
  conversation_contracts::{extract_row_content_str, ConversationRow},
  SessionState, SubagentInfo, SubagentStatus,
};

use crate::{
  runtime::session_queries::SessionLoadError,
  support::session_time::parse_unix_z,
  transport::http::{session_load_error, ApiErrorResponse},
};

use super::{
  ConversationSearchQuery, DEFAULT_CONVERSATION_PAGE_SIZE, DEFAULT_LIBRARY_PAGE_SIZE,
  MAX_CONVERSATION_PAGE_SIZE, MAX_LIBRARY_PAGE_SIZE, MAX_RECENT_INACTIVE_WORKERS,
};

pub fn clamp_conversation_limit(limit: Option<usize>) -> usize {
  limit
    .unwrap_or(DEFAULT_CONVERSATION_PAGE_SIZE)
    .clamp(1, MAX_CONVERSATION_PAGE_SIZE)
}

pub fn clamp_library_limit(limit: Option<usize>) -> usize {
  limit
    .unwrap_or(DEFAULT_LIBRARY_PAGE_SIZE)
    .clamp(1, MAX_LIBRARY_PAGE_SIZE)
}

pub fn map_session_load_error(
  session_id: &str,
  error: SessionLoadError,
) -> (StatusCode, Json<ApiErrorResponse>) {
  session_load_error(session_id, error)
}

pub fn row_matches_search(
  entry: &orbitdock_protocol::conversation_contracts::ConversationRowEntry,
  query: &ConversationSearchQuery,
) -> bool {
  let text_matches = query.q.as_ref().is_none_or(|needle| {
    extract_row_content_str(&entry.row)
      .to_lowercase()
      .contains(&needle.to_lowercase())
  });
  if !text_matches {
    return false;
  }

  match &entry.row {
    ConversationRow::Tool(tool) => {
      let family_matches = query
        .family
        .as_ref()
        .is_none_or(|family| enum_wire_name(tool.family) == Some(family.clone()));
      let status_matches = query
        .status
        .as_ref()
        .is_none_or(|status| enum_wire_name(tool.status) == Some(status.clone()));
      let kind_matches = query
        .kind
        .as_ref()
        .is_none_or(|kind| enum_wire_name(tool.kind) == Some(kind.clone()));
      family_matches && status_matches && kind_matches
    }
    _ => query.family.is_none() && query.status.is_none() && query.kind.is_none(),
  }
}

pub fn duration_ms(started_at: Option<&str>, last_activity_at: Option<&str>) -> u64 {
  let Some(start) = parse_unix_z(started_at) else {
    return 0;
  };
  let Some(end) = parse_unix_z(last_activity_at) else {
    return 0;
  };
  end.saturating_sub(start).saturating_mul(1000)
}

pub fn trim_session_workers(mut session: SessionState) -> SessionState {
  session.subagents = visible_subagents(session.subagents);
  session
}

fn visible_subagents(subagents: Vec<SubagentInfo>) -> Vec<SubagentInfo> {
  let mut ranked = subagents;
  ranked.sort_by(|lhs, rhs| {
    let lhs_active = is_active_subagent(&lhs.status);
    let rhs_active = is_active_subagent(&rhs.status);

    rhs_active
      .cmp(&lhs_active)
      .then_with(|| worker_sort_key(rhs).cmp(&worker_sort_key(lhs)))
  });

  let active_workers: Vec<SubagentInfo> = ranked
    .iter()
    .filter(|worker| is_active_subagent(&worker.status))
    .cloned()
    .collect();
  let inactive_workers: Vec<SubagentInfo> = ranked
    .into_iter()
    .filter(|worker| !is_active_subagent(&worker.status))
    .take(MAX_RECENT_INACTIVE_WORKERS)
    .collect();

  active_workers.into_iter().chain(inactive_workers).collect()
}

fn is_active_subagent(status: &SubagentStatus) -> bool {
  matches!(
    status,
    SubagentStatus::Pending | SubagentStatus::Running | SubagentStatus::Interrupted
  )
}

fn worker_sort_key(subagent: &SubagentInfo) -> (&str, &str) {
  (
    subagent.last_activity_at.as_deref().unwrap_or(""),
    subagent.started_at.as_str(),
  )
}

fn enum_wire_name<T: serde::Serialize>(value: T) -> Option<String> {
  serde_json::to_value(value)
    .ok()?
    .as_str()
    .map(ToString::to_string)
}
