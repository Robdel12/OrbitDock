//! Session runtime utility functions.
//!
//! Shared helpers for runtime-side state transitions and transcript
//! synchronization. Pure row/history helpers live in `session_row_history.rs`
//! and pure time/path helpers live in `support/`.

use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::time::Duration;

use futures::FutureExt;
use tokio::sync::{mpsc, oneshot};

use orbitdock_protocol::ServerMessage;
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionLifecycleState, SessionStatus,
  StateChanges, WorkStatus,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{
  load_messages_from_transcript_path, load_session_by_id, load_token_usage_from_transcript_path,
  PersistCommand,
};
use crate::runtime::restored_sessions::{
  hydrate_restored_rows_if_missing, restored_session_to_persisted_handle,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::transcript_sync_guard::{
  build_transcript_sync_guard_state, cached_transcript_sync_matches,
  next_transcript_sync_guard_state, remember_transcript_sync_guard,
};
#[cfg(test)]
pub(crate) use crate::runtime::transcript_sync_guard::{
  transcript_sync_guard_cache, TranscriptSyncGuardState, TranscriptSyncUsageSignature,
};
use crate::runtime::transcript_sync_policy::{
  plan_transcript_sync, TranscriptMessageSyncDecision, TranscriptSyncInputs,
};
use crate::support::session_time::parse_unix_z;
use orbitdock_connector_core::panic_payload_message;
#[cfg(test)]
pub(crate) use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
#[cfg(test)]
pub(crate) use orbitdock_protocol::TokenUsage;

pub(crate) const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;
pub(crate) const DIRECT_RUNTIME_STARTUP_GRACE: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectorLoopControl {
  Continue,
  Break,
}

pub(crate) async fn mark_session_working_after_send(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) {
  let Some(actor) = state.get_session(session_id) else {
    return;
  };

  crate::runtime::session_state_transitions::transition_work_status(
    &actor,
    session_id,
    WorkStatus::Working,
    None,
  )
  .await;
}

pub(crate) async fn claim_codex_thread_for_direct_session(
  state: &Arc<SessionRegistry>,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  thread_id: &str,
  cleanup_reason: &str,
) {
  state.register_codex_runtime_owner(thread_id, session_id);

  // Write goes through PersistCommand only — single mutation path with immutability guard.
  let persisted = persist_tx
    .send(PersistCommand::SetThreadId {
      session_id: session_id.to_string(),
      thread_id: thread_id.to_string(),
    })
    .await
    .is_ok();

  if !persisted {
    state.unregister_codex_runtime_owner(thread_id);
    tracing::warn!(
      component = "session",
      event = "session.direct.codex_thread_claim_failed",
      session_id = %session_id,
      thread_id = %thread_id,
      "Failed to persist direct Codex thread ownership mapping"
    );
  }

  if thread_id != session_id && state.remove_session(thread_id).is_some() {
    state.publish_active_session_removed(thread_id);
  }

  let _ = persist_tx
    .send(PersistCommand::CleanupThreadShadowSession {
      thread_id: thread_id.to_string(),
      reason: cleanup_reason.to_string(),
    })
    .await;
}

pub(crate) fn direct_mode_activation_changes(provider: Provider) -> StateChanges {
  let mut changes = StateChanges {
    status: Some(SessionStatus::Active),
    work_status: Some(WorkStatus::Waiting),
    lifecycle_state: Some(SessionLifecycleState::Open),
    ..Default::default()
  };

  match provider {
    Provider::Codex => {
      changes.codex_integration_mode = Some(Some(CodexIntegrationMode::Direct));
    }
    Provider::Claude => {
      changes.claude_integration_mode = Some(Some(ClaudeIntegrationMode::Direct));
    }
  }

  changes
}

pub(crate) fn direct_resume_failure_changes(provider: Provider) -> StateChanges {
  let mut changes = direct_mode_activation_changes(provider);
  changes.lifecycle_state = Some(SessionLifecycleState::Resumable);
  changes.work_status = Some(WorkStatus::Waiting);
  changes
}

fn connector_cleanup_changes(provider: Provider) -> StateChanges {
  let mut changes = StateChanges {
    lifecycle_state: Some(SessionLifecycleState::Resumable),
    work_status: Some(WorkStatus::Waiting),
    steerable: Some(false),
    ..Default::default()
  };

  match provider {
    Provider::Codex => {
      changes.codex_integration_mode = Some(Some(CodexIntegrationMode::Direct));
    }
    Provider::Claude => {
      changes.claude_integration_mode = Some(Some(ClaudeIntegrationMode::Direct));
    }
  }

  changes
}

async fn apply_connector_cleanup_transition(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) -> bool {
  let Some(actor) = state.get_session(session_id) else {
    return false;
  };

  if let Err(error) = actor
    .send_checked(SessionCommand::ApplyDelta {
      changes: Box::new(connector_cleanup_changes(provider)),
      persist_op: Some(PersistCommand::SessionUpdate {
        id: session_id.to_string(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        control_mode: None,
        lifecycle_state: Some(SessionLifecycleState::Resumable),
        last_activity_at: None,
        last_progress_at: None,
      }),
    })
    .await
  {
    tracing::warn!(
      component = "connector_cleanup",
      event = "connector_cleanup.session_update_failed",
      session_id = %session_id,
      provider = ?provider,
      error = %error,
      "Failed to queue connector cleanup update through the session actor"
    );
    return false;
  }

  true
}

pub(crate) fn should_detach_direct_connector_after_send_error(message: &str) -> bool {
  let normalized = message.to_ascii_lowercase();
  let has_not_found = normalized.contains("not found") || normalized.contains("not_found");
  let references_session = normalized.contains("session") || normalized.contains("thread");
  let has_explicit_session_not_found =
    normalized.contains("session_not_found") || normalized.contains("thread_not_found");

  (has_not_found && references_session) || has_explicit_session_not_found
}

pub(crate) fn verify_direct_runtime_ready_snapshot(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) -> Result<(), String> {
  let actor = state.get_session(session_id).ok_or_else(|| {
    format!("Connector started but session actor {session_id} was not registered")
  })?;
  let snapshot = actor.snapshot();
  if snapshot.status != SessionStatus::Active
    || snapshot.control_mode != orbitdock_protocol::SessionControlMode::Direct
    || snapshot.lifecycle_state != SessionLifecycleState::Open
  {
    return Err(format!(
      "Connector started but session {session_id} did not reach active/direct/open state"
    ));
  }

  let action_tx = match provider {
    Provider::Codex => state
      .get_codex_action_tx(session_id)
      .map(|tx| tx.is_closed()),
    Provider::Claude => state
      .get_claude_action_tx(session_id)
      .map(|tx| tx.is_closed()),
  }
  .ok_or_else(|| format!("Connector started but session {session_id} has no action channel"))?;

  if action_tx {
    return Err(format!(
      "Connector started but session {session_id} action channel is closed"
    ));
  }

  Ok(())
}

pub(crate) async fn verify_direct_runtime_ready_with_startup_grace(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
  startup_grace: Duration,
) -> Result<(), String> {
  verify_direct_runtime_ready_snapshot(state, session_id, provider)?;

  let closed_during_grace = match provider {
    Provider::Codex => {
      let tx = state.get_codex_action_tx(session_id).ok_or_else(|| {
        format!("Connector started but session {session_id} has no action channel")
      })?;
      tokio::time::timeout(startup_grace, tx.closed())
        .await
        .is_ok()
    }
    Provider::Claude => {
      let tx = state.get_claude_action_tx(session_id).ok_or_else(|| {
        format!("Connector started but session {session_id} has no action channel")
      })?;
      tokio::time::timeout(startup_grace, tx.closed())
        .await
        .is_ok()
    }
  };

  if closed_during_grace {
    return Err(format!(
      "Connector started but session {session_id} action channel closed during startup grace period"
    ));
  }

  verify_direct_runtime_ready_snapshot(state, session_id, provider)
}

pub(crate) async fn activate_direct_session_runtime(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) {
  let Some(actor) = state.get_session(session_id) else {
    return;
  };

  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(direct_mode_activation_changes(provider)),
      persist_op: Some(PersistCommand::SessionUpdate {
        id: session_id.to_string(),
        status: Some(SessionStatus::Active),
        work_status: Some(WorkStatus::Waiting),
        control_mode: None,
        lifecycle_state: Some(SessionLifecycleState::Open),
        last_activity_at: None,
        last_progress_at: None,
      }),
    })
    .await;
}

pub(crate) struct AttachClaudeDirectRuntimeRequest {
  pub session_id: String,
  pub handle: SessionHandle,
  pub claude_session: ClaudeSession,
  pub permission_mode: Option<String>,
  pub permission_persist_op: Option<PersistCommand>,
  pub apply_permission_before_activate: bool,
}

async fn apply_claude_permission_mode_update(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  permission_mode: Option<String>,
  permission_persist_op: Option<PersistCommand>,
) {
  let Some(mode) = permission_mode else {
    return;
  };
  let Some(actor) = state.get_session(session_id) else {
    return;
  };

  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        permission_mode: Some(Some(mode)),
        ..Default::default()
      }),
      persist_op: permission_persist_op,
    })
    .await;
}

pub(crate) async fn attach_claude_direct_runtime(
  state: &Arc<SessionRegistry>,
  request: AttachClaudeDirectRuntimeRequest,
) {
  let AttachClaudeDirectRuntimeRequest {
    session_id,
    mut handle,
    claude_session,
    permission_mode,
    permission_persist_op,
    apply_permission_before_activate,
  } = request;

  state.prepare_session_handle(&mut handle);
  let persist_tx = state.persist().clone();
  let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
    claude_session,
    handle,
    persist_tx.clone(),
    state.list_tx(),
    state.clone(),
  );
  state.add_session_actor(actor_handle);
  state.set_claude_action_tx(&session_id, action_tx);

  let mut pending_persist_op = permission_persist_op;
  if apply_permission_before_activate {
    apply_claude_permission_mode_update(
      state,
      &session_id,
      permission_mode.clone(),
      pending_persist_op.take(),
    )
    .await;
  }

  activate_direct_session_runtime(state, &session_id, Provider::Claude).await;

  if !apply_permission_before_activate {
    apply_claude_permission_mode_update(state, &session_id, permission_mode, pending_persist_op)
      .await;
  }

  let _ = persist_tx
    .send(PersistCommand::SetIntegrationMode {
      session_id,
      codex_mode: None,
      claude_mode: Some("direct".into()),
    })
    .await;
}

pub(crate) async fn mark_direct_session_connector_detached(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: Provider,
) {
  let Some(actor) = state.get_session(session_id) else {
    return;
  };

  let snapshot = actor.snapshot();
  let control_mode = snapshot.control_mode;

  if snapshot.status != SessionStatus::Active
    || control_mode != orbitdock_protocol::SessionControlMode::Direct
    || snapshot.lifecycle_state != SessionLifecycleState::Open
  {
    return;
  }

  let _ = apply_connector_cleanup_transition(state, session_id, provider).await;
}

/// Apply connector-detached state directly on the `SessionHandle` currently
/// owned by an active connector event loop.
pub(crate) async fn apply_connector_detached_directly(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  provider: Provider,
) {
  let snapshot = handle.to_snapshot();
  let control_mode = snapshot.control_mode;

  if snapshot.status != SessionStatus::Active
    || control_mode != orbitdock_protocol::SessionControlMode::Direct
    || snapshot.lifecycle_state != SessionLifecycleState::Open
  {
    return;
  }

  let changes = connector_cleanup_changes(provider);

  handle.apply_changes(&changes);
  handle.refresh_snapshot();

  let _ = persist_tx
    .send(PersistCommand::SessionUpdate {
      id: session_id.to_string(),
      status: None,
      work_status: Some(WorkStatus::Waiting),
      control_mode: None,
      lifecycle_state: Some(SessionLifecycleState::Resumable),
      last_activity_at: None,
      last_progress_at: None,
    })
    .await;

  handle.broadcast(ServerMessage::SessionDelta {
    session_id: session_id.to_string(),
    changes: Box::new(changes),
  });
}

pub(crate) async fn run_connector_loop_step<F>(
  component: &'static str,
  event: &'static str,
  session_id: &str,
  branch: &'static str,
  future: F,
) -> ConnectorLoopControl
where
  F: Future<Output = ConnectorLoopControl>,
{
  match AssertUnwindSafe(future).catch_unwind().await {
    Ok(control) => control,
    Err(payload) => {
      tracing::error!(
        component = component,
        event = event,
        session_id = %session_id,
        branch = branch,
        panic = %panic_payload_message(payload.as_ref()),
        "Connector loop step panicked; downgrading runtime to resumable"
      );
      ConnectorLoopControl::Break
    }
  }
}

pub(crate) fn rebind_session_as_passive_actor(
  state: &Arc<SessionRegistry>,
  handle: SessionHandle,
) -> SessionActorHandle {
  let session_id = handle.id().to_string();
  let actor = state.add_session(handle);
  tracing::debug!(
    component = "connector_cleanup",
    event = "connector_cleanup.passive_actor_rebound",
    session_id = %session_id,
    "Rebound detached direct runtime to a passive session actor"
  );
  actor
}

pub(crate) async fn restore_passive_session_actor_from_persistence(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> bool {
  let restored = match load_session_by_id(session_id).await {
    Ok(Some(restored)) => restored,
    Ok(None) => {
      tracing::warn!(
        component = "connector_cleanup",
        event = "connector_cleanup.passive_actor_restore_missing",
        session_id = %session_id,
        "Cannot restore passive actor because the persisted session was not found"
      );
      return false;
    }
    Err(error) => {
      tracing::warn!(
        component = "connector_cleanup",
        event = "connector_cleanup.passive_actor_restore_failed",
        session_id = %session_id,
        error = %error,
        "Failed to load persisted session for passive actor restore"
      );
      return false;
    }
  };

  let mut restored = restored;
  hydrate_restored_rows_if_missing(&mut restored, session_id).await;
  rebind_session_as_passive_actor(state, restored_session_to_persisted_handle(restored));
  true
}

pub(crate) fn is_stale_empty_claude_shell(
  summary: &orbitdock_protocol::SessionSummary,
  current_session_id: &str,
  cwd: &str,
  now_secs: u64,
) -> bool {
  if summary.id == current_session_id {
    return false;
  }
  if summary.provider != Provider::Claude {
    return false;
  }
  if summary.project_path != cwd {
    return false;
  }
  if summary.status != orbitdock_protocol::SessionStatus::Active {
    return false;
  }
  if summary.work_status != orbitdock_protocol::WorkStatus::Waiting {
    return false;
  }
  if summary.custom_name.is_some() {
    return false;
  }

  let started_at = parse_unix_z(summary.started_at.as_deref());
  let last_activity_at = parse_unix_z(summary.last_activity_at.as_deref()).or(started_at);
  let Some(last_activity_at) = last_activity_at else {
    return false;
  };

  now_secs.saturating_sub(last_activity_at) >= CLAUDE_EMPTY_SHELL_TTL_SECS
}

/// Re-read a session's transcript and broadcast any new rows to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
///
/// Uses ID-based comparison: tracks the newest row ID we've synced rather than
/// a count. This is immune to `total_row_count` inflation from upserts.
pub(crate) async fn sync_transcript_messages(
  actor: &SessionActorHandle,
  persist_tx: &tokio::sync::mpsc::Sender<crate::infrastructure::persistence::PersistCommand>,
) {
  let snap = actor.snapshot();
  let transcript_path = match snap.transcript_path.as_deref() {
    Some(p) => p.to_string(),
    None => return,
  };
  let session_id = snap.id.clone();
  let newest_known_id = snap.newest_synced_row_id.clone();
  let guard_candidate =
    build_transcript_sync_guard_state(&transcript_path, newest_known_id.clone(), &snap.token_usage)
      .await;

  if let Some(candidate) = guard_candidate.as_ref() {
    if cached_transcript_sync_matches(&session_id, candidate) {
      tracing::debug!(
          component = "transcript_sync",
          event = "transcript_sync.skipped_cached",
          session_id = %session_id,
          newest_known_id = ?newest_known_id,
          "Skipping transcript sync because the transcript inputs are unchanged"
      );
      return;
    }
  }

  let all_rows = match load_messages_from_transcript_path(&transcript_path, &session_id).await {
    Ok(rows) => rows,
    Err(_) => return,
  };

  let transcript_rows_for_guard = guard_candidate.as_ref().map(|_| all_rows.clone());
  let plan = plan_transcript_sync(TranscriptSyncInputs {
    provider: snap.provider,
    current_usage: snap.token_usage.clone(),
    transcript_usage: load_token_usage_from_transcript_path(&transcript_path)
      .await
      .ok()
      .flatten(),
    transcript_rows: all_rows,
    newest_known_id: newest_known_id.clone(),
  });
  let next_guard_state = match (guard_candidate.as_ref(), transcript_rows_for_guard.as_ref()) {
    (Some(candidate), Some(transcript_rows)) => Some(next_transcript_sync_guard_state(
      candidate,
      &snap.token_usage,
      &plan,
      transcript_rows,
    )),
    _ => None,
  };

  if let Some(usage_update) = plan.usage_update {
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::TokensUpdated {
          usage: usage_update.usage,
          snapshot_kind: usage_update.snapshot_kind,
        },
      })
      .await;
  }

  match plan.message_sync_decision {
    TranscriptMessageSyncDecision::AppendNewMessages => {
      // Upsert existing rows that got results attached by the transcript parser.
      for entry in plan.updated_rows {
        actor
          .send(SessionCommand::ProcessEvent {
            event: crate::domain::sessions::transition::Input::RowUpdated {
              row_id: entry.id().to_string(),
              entry,
            },
          })
          .await;
      }

      for entry in plan.new_rows {
        actor
          .send(SessionCommand::ProcessEvent {
            event: crate::domain::sessions::transition::Input::RowCreated(entry),
          })
          .await;
      }
    }
    TranscriptMessageSyncDecision::ForceResync => {
      // Full resync — normalize sequences before persisting (matching
      // what replace_rows() does internally), then replace in-memory and
      // let the session actor emit a lightweight resync hint.
      let mut rows = plan.new_rows;
      for (i, entry) in rows.iter_mut().enumerate() {
        entry.sequence = i as u64;
      }
      for entry in &rows {
        let _ = persist_tx
          .send(
            crate::infrastructure::persistence::PersistCommand::RowUpsert {
              session_id: session_id.clone(),
              entry: entry.clone(),
              viewer_present: false,
              assigned_sequence: Some(entry.sequence),
              sequence_tx: None,
            },
          )
          .await;
      }
      actor.send(SessionCommand::ReplaceRows { rows }).await;
    }
    TranscriptMessageSyncDecision::SkipNoNewMessages => {}
  }

  if let Some(state) = next_guard_state {
    remember_transcript_sync_guard(&session_id, state);
  }
}

/// Spawns a cleanup monitor that guarantees session cleanup even if the main
/// event loop panics or is cancelled. Returns a guard that must be held for the
/// lifetime of the event loop — when dropped, the monitor marks the session resumable.
///
/// This solves the "stuck session" problem where a connector crash could leave
/// sessions in `lifecycle_state=open` with no active connector.
pub(crate) fn spawn_connector_cleanup_monitor(
  session_id: String,
  persist_tx: mpsc::Sender<PersistCommand>,
  state: Arc<SessionRegistry>,
  provider: Provider,
) -> ConnectorCleanupGuard {
  let (drop_tx, drop_rx) = oneshot::channel::<ConnectorCleanupDisposition>();

  let cleanup_session_id = session_id.clone();
  tokio::spawn(async move {
    match drop_rx.await {
      Ok(ConnectorCleanupDisposition::HandledInLoop) => {
        tracing::debug!(
          component = "connector_cleanup",
          event = "connector_cleanup.handled_in_loop",
          session_id = %cleanup_session_id,
          "Connector loop already applied cleanup"
        );
        return;
      }
      Err(_) => {}
    }

    // Fallback path for panic/cancel where the loop cannot update in-memory
    // state before exiting. Route the mutation through the session actor so
    // there is still one authoritative state transition path.
    let updated_via_actor =
      apply_connector_cleanup_transition(&state, &cleanup_session_id, provider).await;
    if !updated_via_actor {
      tracing::warn!(
        component = "connector_cleanup",
        event = "connector_cleanup.persist_fallback",
        session_id = %cleanup_session_id,
        provider = ?provider,
        "Actor cleanup transition unavailable; persisting resumable state directly"
      );
      let _ = persist_tx
        .send(PersistCommand::SessionUpdate {
          id: cleanup_session_id.clone(),
          status: None,
          work_status: Some(WorkStatus::Waiting),
          control_mode: None,
          lifecycle_state: Some(SessionLifecycleState::Resumable),
          last_activity_at: None,
          last_progress_at: None,
        })
        .await;
    }

    // Remove action channel from registry
    match provider {
      Provider::Codex => state.remove_codex_action_tx(&cleanup_session_id),
      Provider::Claude => state.remove_claude_action_tx(&cleanup_session_id),
    }

    if !updated_via_actor {
      restore_passive_session_actor_from_persistence(&state, &cleanup_session_id).await;
    }
  });

  ConnectorCleanupGuard {
    drop_tx: Some(drop_tx),
  }
}

enum ConnectorCleanupDisposition {
  HandledInLoop,
}

/// Guard that triggers cleanup when dropped. Hold this for the lifetime of the
/// connector event loop.
pub(crate) struct ConnectorCleanupGuard {
  drop_tx: Option<oneshot::Sender<ConnectorCleanupDisposition>>,
}

impl ConnectorCleanupGuard {
  pub(crate) fn disarm(&mut self) {
    if let Some(drop_tx) = self.drop_tx.take() {
      let _ = drop_tx.send(ConnectorCleanupDisposition::HandledInLoop);
    }
  }
}

#[cfg(test)]
#[path = "session_runtime_helpers_tests.rs"]
mod session_runtime_helpers_tests;
