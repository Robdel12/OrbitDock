use std::sync::Arc;

use crate::infrastructure::persistence::{
  load_session_by_id, load_session_metadata_by_id, load_subagents_for_session, RestoredSession,
};
use crate::runtime::restored_sessions::restored_session_to_state;
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::{Provider, SessionState};
use tracing::warn;

use super::projection::SessionLoadError;

pub(crate) fn apply_page_to_session(
  session: &mut SessionState,
  page: &crate::domain::sessions::conversation::ConversationPage,
) {
  session.rows = page.rows.clone();
  session.total_row_count = page.total_row_count;
  session.has_more_before = page.has_more_before;
  session.oldest_sequence = page.oldest_sequence;
  session.newest_sequence = page.newest_sequence;
}

fn strip_diff_payloads(state: &mut SessionState) {
  state.current_diff = None;
  state.cumulative_diff = None;
  state.turn_diffs.clear();
}

pub(crate) fn trim_session_payload(
  session: &mut SessionState,
  include_messages: bool,
  include_diffs: bool,
) {
  if !include_diffs {
    strip_diff_payloads(session);
  }
  if !include_messages {
    session.rows.clear();
    session.oldest_sequence = None;
    session.newest_sequence = None;
  }
}

pub(crate) async fn hydrate_subagents(state: &mut SessionState, session_id: &str) {
  if !state.subagents.is_empty() {
    return;
  }

  match load_subagents_for_session(session_id).await {
    Ok(subagents) => {
      state.subagents = subagents;
    }
    Err(err) => {
      warn!(
          component = "api",
          event = "api.get_session.subagents_load_failed",
          session_id = %session_id,
          error = %err,
          "Failed to load session subagents"
      );
    }
  }
}

fn direct_connector_attached(
  registry: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) -> bool {
  match provider {
    Provider::Codex => registry
      .get_codex_action_tx(session_id)
      .is_some_and(|tx| !tx.is_closed()),
    Provider::Claude => registry
      .get_claude_action_tx(session_id)
      .is_some_and(|tx| !tx.is_closed()),
  }
}

/// Hydrate runtime state from the live session actor.
/// The DB may lag batched writes, so the actor is the real-time source of truth
/// for control affordances and other active-session fields.
pub(crate) async fn hydrate_ephemeral_state(
  session: &mut SessionState,
  registry: &Arc<SessionRegistry>,
  session_id: &str,
) {
  if let Some(actor) = registry.get_session(session_id) {
    if let Ok(live) = actor.retained_state().await {
      let connector_attached = direct_connector_attached(registry, session_id, live.provider);

      session.revision = live.revision;
      session.status = live.status;
      session.work_status = live.work_status;
      session.control_mode = live.control_mode;
      session.lifecycle_state = live.lifecycle_state;
      session.connector_attached = connector_attached;
      session.accepts_user_input = live.accepts_user_input && connector_attached;
      session.steerable = live.steerable && connector_attached;
      session.can_interrupt = live.can_interrupt && connector_attached;
      session.pending_approval = live.pending_approval;
      session.permission_mode = live.permission_mode;
      session.pending_tool_name = live.pending_tool_name;
      session.pending_tool_input = live.pending_tool_input;
      session.pending_question = live.pending_question;
      session.pending_approval_id = live.pending_approval_id;
      session.approval_version = live.approval_version;
      session.current_turn_id = live.current_turn_id;
      session.git_branch = live.git_branch;
      session.current_cwd = live.current_cwd;
      session.token_usage = live.token_usage;
      session.token_usage_snapshot_kind = live.token_usage_snapshot_kind;
    }
  }
}

pub(crate) async fn load_persisted_session_state(
  session_id: &str,
  include_messages: bool,
  include_diffs: bool,
) -> Result<SessionState, SessionLoadError> {
  let restored_result: Result<Option<RestoredSession>, anyhow::Error> = if include_messages {
    load_session_by_id(session_id).await
  } else {
    load_session_metadata_by_id(session_id).await
  };

  match restored_result {
    Ok(Some(mut restored)) => {
      if include_messages {
        crate::runtime::restored_sessions::hydrate_restored_rows_if_missing(
          &mut restored,
          session_id,
        )
        .await;
      }

      let mut snapshot = restored_session_to_state(restored);
      trim_session_payload(&mut snapshot, include_messages, include_diffs);
      Ok(snapshot)
    }
    Ok(None) => Err(SessionLoadError::NotFound),
    Err(err) => Err(SessionLoadError::Db(err.to_string())),
  }
}

pub(crate) async fn load_full_session_state(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  include_messages: bool,
  include_diffs: bool,
) -> Result<SessionState, SessionLoadError> {
  match load_persisted_session_state(session_id, include_messages, include_diffs).await {
    Ok(mut snapshot) => {
      hydrate_ephemeral_state(&mut snapshot, state, session_id).await;
      hydrate_subagents(&mut snapshot, session_id).await;
      Ok(snapshot)
    }
    Err(SessionLoadError::NotFound) => {
      let Some(actor) = state.get_session(session_id) else {
        return Err(SessionLoadError::NotFound);
      };

      let mut snapshot = actor
        .retained_state()
        .await
        .map_err(SessionLoadError::Runtime)?;
      trim_session_payload(&mut snapshot, include_messages, include_diffs);
      hydrate_ephemeral_state(&mut snapshot, state, session_id).await;
      hydrate_subagents(&mut snapshot, session_id).await;
      Ok(snapshot)
    }
    Err(err) => Err(err),
  }
}

/// Load the light, client-facing session metadata projection.
///
/// This is the safe API boundary for endpoints that need session metadata but
/// not conversation rows or diff payloads. It keeps the transport payload cheap
/// and applies the same live affordance hydration as detail snapshots.
pub(crate) async fn load_light_session_state(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<SessionState, SessionLoadError> {
  match load_full_session_state(state, session_id, false, false).await {
    Ok(session) => Ok(session),
    Err(SessionLoadError::NotFound) => {
      let Some(actor) = state.get_session(session_id) else {
        return Err(SessionLoadError::NotFound);
      };

      let mut session = actor
        .retained_state()
        .await
        .map_err(SessionLoadError::Runtime)?;
      trim_session_payload(&mut session, false, false);
      session.total_row_count = 0;
      session.has_more_before = false;
      hydrate_ephemeral_state(&mut session, state, session_id).await;
      hydrate_subagents(&mut session, session_id).await;
      Ok(session)
    }
    Err(error) => Err(error),
  }
}
