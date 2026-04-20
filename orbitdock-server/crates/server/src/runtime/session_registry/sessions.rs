use orbitdock_protocol::{SessionListItem, SessionSummary};

use crate::domain::sessions::session::{accepts_user_input_from_parts, SessionHandle};
use crate::runtime::session_actor::SessionActorHandle;
use std::sync::atomic::Ordering;

use super::SessionRegistry;

impl SessionRegistry {
  pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
    self
      .sessions
      .iter()
      .map(|entry| {
        let actor = entry.value();
        let snap = actor.snapshot();
        let control_mode = snap.control_mode;
        let lifecycle_state = snap.lifecycle_state;
        let accepts_user_input =
          accepts_user_input_from_parts(snap.status, control_mode, lifecycle_state);
        let display_title = SessionSummary::display_title_from_parts(
          snap.custom_name.as_deref(),
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.project_name.as_deref(),
          &snap.project_path,
        );
        let context_line = SessionSummary::context_line_from_parts(
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.last_message.as_deref(),
        );
        SessionSummary {
          id: snap.id.clone(),
          provider: snap.provider,
          project_path: snap.project_path.clone(),
          transcript_path: snap.transcript_path.clone(),
          project_name: snap.project_name.clone(),
          model: snap.model.clone(),
          custom_name: snap.custom_name.clone(),
          summary: snap.summary.clone(),
          status: snap.status,
          work_status: snap.work_status,
          control_mode,
          lifecycle_state,
          accepts_user_input,
          token_usage: snap.token_usage.clone(),
          token_usage_snapshot_kind: snap.token_usage_snapshot_kind,
          has_pending_approval: snap.has_pending_approval,
          codex_integration_mode: snap.codex_integration_mode,
          claude_integration_mode: snap.claude_integration_mode,
          approval_policy: snap.approval_policy.clone(),
          approval_policy_details: snap.approval_policy_details.clone(),
          sandbox_mode: snap.sandbox_mode.clone(),
          sandbox_policy_details: snap.sandbox_policy_details.clone(),
          permission_mode: snap.permission_mode.clone(),
          collaboration_mode: snap.collaboration_mode.clone(),
          multi_agent: snap.multi_agent,
          personality: snap.personality.clone(),
          service_tier: snap.service_tier.clone(),
          developer_instructions: snap.developer_instructions.clone(),
          codex_config_mode: snap.codex_config_mode,
          codex_config_profile: snap.codex_config_profile.clone(),
          codex_model_provider: snap.codex_model_provider.clone(),
          codex_config_source: snap.codex_config_source,
          codex_config_overrides: snap.codex_config_overrides.clone(),
          pending_tool_name: snap.pending_tool_name.clone(),
          pending_tool_input: snap.pending_tool_input.clone(),
          pending_question: snap.pending_question.clone(),
          pending_approval_id: snap.pending_approval_id.clone(),
          started_at: snap.started_at.clone(),
          last_activity_at: snap.last_activity_at.clone(),
          last_progress_at: snap.last_progress_at.clone(),
          git_branch: snap.git_branch.clone(),
          git_sha: snap.git_sha.clone(),
          current_cwd: snap.current_cwd.clone(),
          first_prompt: snap.first_prompt.clone(),
          last_message: snap.last_message.clone(),
          effort: snap.effort.clone(),
          approval_version: Some(snap.approval_version),
          summary_revision: snap.revision,
          repository_root: snap.repository_root.clone(),
          is_worktree: snap.is_worktree,
          worktree_id: snap.worktree_id.clone(),
          unread_count: snap.unread_count,
          has_turn_diff: snap.has_turn_diff,
          display_title,
          context_line,
          list_status: SessionSummary::list_status_from_parts(snap.status, snap.work_status),
          active_worker_count: snap.active_worker_count,
          pending_tool_family: None,
          forked_from_session_id: None,
          mission_id: snap.mission_id.clone(),
          steerable: snap.steerable,
          issue_identifier: snap.issue_identifier.clone(),
          allow_bypass_permissions: snap.allow_bypass_permissions,
        }
      })
      .collect()
  }

  #[allow(dead_code)]
  pub fn get_session_list_items(&self) -> Vec<SessionListItem> {
    self
      .get_session_summaries()
      .into_iter()
      .map(SessionListItem::from)
      .collect()
  }

  pub fn iter_sessions(&self) -> dashmap::iter::Iter<'_, String, SessionActorHandle> {
    self.sessions.iter()
  }

  pub fn get_session(&self, id: &str) -> Option<SessionActorHandle> {
    self.sessions.get(id).map(|r| r.clone()).or_else(|| {
      self
        .resolve_runtime_owner_session_id(id)
        .and_then(|owner| self.sessions.get(&owner).map(|entry| entry.clone()))
    })
  }

  pub fn add_session(&self, mut handle: SessionHandle) -> SessionActorHandle {
    handle.set_list_tx(self.list_tx.clone());
    handle.set_sessions_summary_revision_counter(self.sessions_summary_revision.clone());
    handle.set_dashboard_revision_counter(self.dashboard_revision.clone());
    handle.set_library_revision_counter(self.library_revision.clone());
    let id = handle.id().to_string();
    let actor = SessionActorHandle::spawn(handle, self.persist_tx.clone());
    self.sessions.insert(id, actor.clone());
    self
      .sessions_summary_revision
      .fetch_add(1, Ordering::Relaxed);
    self.dashboard_revision.fetch_add(1, Ordering::Relaxed);
    self.library_revision.fetch_add(1, Ordering::Relaxed);
    actor
  }

  pub fn add_session_actor(&self, actor: SessionActorHandle) {
    self.sessions.insert(actor.id.clone(), actor);
    self
      .sessions_summary_revision
      .fetch_add(1, Ordering::Relaxed);
    self.dashboard_revision.fetch_add(1, Ordering::Relaxed);
    self.library_revision.fetch_add(1, Ordering::Relaxed);
  }

  pub fn remove_session(&self, id: &str) -> Option<SessionActorHandle> {
    self.connectors.remove_action_txs(id);
    self.purge_runtime_ownership_for_session(id);
    let removed = self.sessions.remove(id).map(|(_, v)| v);
    if removed.is_some() {
      self
        .sessions_summary_revision
        .fetch_add(1, Ordering::Relaxed);
      self.dashboard_revision.fetch_add(1, Ordering::Relaxed);
      self.library_revision.fetch_add(1, Ordering::Relaxed);
    }
    removed
  }
}
