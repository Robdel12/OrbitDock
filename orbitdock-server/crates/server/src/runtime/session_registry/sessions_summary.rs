use std::collections::HashSet;
use std::sync::atomic::Ordering;

use orbitdock_protocol::{
  estimate_session_cost, ServerMessage, SessionListItem, SessionStatus, SessionSummary,
  SessionsSummaryCounts, SessionsSummarySnapshot,
};

use super::SessionRegistry;

const SESSIONS_SUMMARY_RECENT_LIMIT: usize = 5;

impl SessionRegistry {
  pub fn current_sessions_summary_revision(&self) -> u64 {
    self.sessions_summary_revision.load(Ordering::Relaxed)
  }

  pub fn sessions_summary_revision_counter(&self) -> std::sync::Arc<std::sync::atomic::AtomicU64> {
    self.sessions_summary_revision.clone()
  }

  pub async fn current_sessions_summary_snapshot(
    self: &std::sync::Arc<Self>,
  ) -> SessionsSummarySnapshot {
    let active_sessions = self.active_sessions_summary_sessions();
    let recent_snapshot = crate::runtime::session_queries::load_library_snapshot(
      self,
      SESSIONS_SUMMARY_RECENT_LIMIT,
      0,
    )
    .await
    .ok();

    let active_ids: HashSet<&str> = active_sessions
      .iter()
      .map(|item| item.id.as_str())
      .collect();
    let recent_sessions = recent_snapshot
      .as_ref()
      .map(|snapshot| {
        snapshot
          .sessions
          .iter()
          .filter(|item| !active_ids.contains(item.id.as_str()))
          .take(SESSIONS_SUMMARY_RECENT_LIMIT)
          .cloned()
          .collect::<Vec<_>>()
      })
      .unwrap_or_default();

    let total_count = recent_snapshot
      .as_ref()
      .map(|snapshot| snapshot.total_count)
      .unwrap_or(active_sessions.len() as u64);

    SessionsSummarySnapshot {
      revision: self.current_sessions_summary_revision(),
      counts: SessionsSummaryCounts {
        total: total_count,
        active: active_sessions.len() as u32,
        working: active_sessions
          .iter()
          .filter(|item| item.list_status == orbitdock_protocol::SessionListStatus::Working)
          .count() as u32,
        attention: active_sessions
          .iter()
          .filter(|item| {
            matches!(
              item.list_status,
              orbitdock_protocol::SessionListStatus::Permission
                | orbitdock_protocol::SessionListStatus::Question
            )
          })
          .count() as u32,
        ready: active_sessions
          .iter()
          .filter(|item| item.list_status == orbitdock_protocol::SessionListStatus::Reply)
          .count() as u32,
      },
      active_sessions,
      recent_sessions,
    }
  }

  pub fn publish_sessions_summary_invalidation(&self) {
    let revision = self
      .sessions_summary_revision
      .fetch_add(1, Ordering::Relaxed)
      + 1;
    let _ = self
      .list_tx
      .send(ServerMessage::SessionsSummaryInvalidated { revision });
  }

  fn active_sessions_summary_sessions(&self) -> Vec<SessionListItem> {
    let mut sessions: Vec<SessionListItem> = self
      .sessions
      .iter()
      .map(|entry| session_list_item_from_snapshot(&entry.value().snapshot()))
      .filter(|summary| summary.status == SessionStatus::Active)
      .collect();

    sessions.sort_by(|lhs, rhs| {
      rhs
        .last_activity_at
        .cmp(&lhs.last_activity_at)
        .then_with(|| lhs.id.cmp(&rhs.id))
    });
    sessions
  }
}

fn session_list_item_from_snapshot(
  snapshot: &crate::domain::sessions::session::SessionSnapshot,
) -> SessionListItem {
  let display_title = SessionSummary::display_title_from_parts(
    snapshot.custom_name.as_deref(),
    snapshot.summary.as_deref(),
    snapshot.first_prompt.as_deref(),
    snapshot.project_name.as_deref(),
    &snapshot.project_path,
  );
  let context_line = SessionSummary::context_line_from_parts(
    snapshot.summary.as_deref(),
    snapshot.first_prompt.as_deref(),
    snapshot.last_message.as_deref(),
  );
  let list_status = SessionSummary::list_status_from_parts(snapshot.status, snapshot.work_status);

  SessionListItem {
    id: snapshot.id.clone(),
    provider: snapshot.provider,
    project_path: snapshot.project_path.clone(),
    project_name: snapshot.project_name.clone(),
    git_branch: snapshot.git_branch.clone(),
    model: snapshot.model.clone(),
    status: snapshot.status,
    work_status: snapshot.work_status,
    control_mode: snapshot.control_mode,
    lifecycle_state: snapshot.lifecycle_state,
    steerable: snapshot.steerable,
    codex_integration_mode: snapshot.codex_integration_mode,
    claude_integration_mode: snapshot.claude_integration_mode,
    started_at: snapshot.started_at.clone(),
    last_activity_at: snapshot.last_activity_at.clone(),
    last_progress_at: snapshot.last_progress_at.clone(),
    unread_count: snapshot.unread_count,
    has_turn_diff: snapshot.has_turn_diff,
    pending_tool_name: snapshot.pending_tool_name.clone(),
    repository_root: snapshot.repository_root.clone(),
    is_worktree: snapshot.is_worktree,
    worktree_id: snapshot.worktree_id.clone(),
    total_tokens: snapshot.token_usage.input_tokens + snapshot.token_usage.output_tokens,
    total_cost_usd: estimate_session_cost(
      snapshot.provider,
      snapshot.model.as_deref(),
      &snapshot.token_usage,
    ),
    input_tokens: snapshot.token_usage.input_tokens,
    output_tokens: snapshot.token_usage.output_tokens,
    cached_tokens: snapshot.token_usage.cached_tokens,
    display_title,
    context_line,
    list_status,
    effort: snapshot.effort.clone(),
    summary_revision: snapshot.revision,
    active_worker_count: snapshot.active_worker_count,
    pending_tool_family: None,
    forked_from_session_id: None,
    mission_id: snapshot.mission_id.clone(),
    issue_identifier: snapshot.issue_identifier.clone(),
  }
}
