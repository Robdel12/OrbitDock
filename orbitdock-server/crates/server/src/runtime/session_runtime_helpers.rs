//! Session runtime utility functions.
//!
//! Shared helpers for runtime-side state transitions and transcript
//! synchronization. Pure time/path helpers live in `support/`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, UNIX_EPOCH};

use tokio::sync::{mpsc, oneshot};

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::ServerMessage;
use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionLifecycleState, SessionStatus,
  StateChanges, TokenUsage, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{
  load_messages_for_session, load_messages_from_transcript_path,
  load_token_usage_from_transcript_path, PersistCommand,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::transcript_sync_policy::{
  plan_transcript_sync, TranscriptMessageSyncDecision, TranscriptSyncInputs,
};
use crate::support::session_time::parse_unix_z;

pub(crate) const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;
pub(crate) const DIRECT_RUNTIME_STARTUP_GRACE: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TranscriptSyncUsageSignature {
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
  context_window: u64,
}

impl From<&TokenUsage> for TranscriptSyncUsageSignature {
  fn from(value: &TokenUsage) -> Self {
    Self {
      input_tokens: value.input_tokens,
      output_tokens: value.output_tokens,
      cached_tokens: value.cached_tokens,
      context_window: value.context_window,
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TranscriptSyncGuardState {
  transcript_path: String,
  newest_known_id: Option<String>,
  usage: TranscriptSyncUsageSignature,
  file_size: u64,
  modified_at_nanos: Option<u128>,
}

static TRANSCRIPT_SYNC_GUARD_CACHE: OnceLock<Mutex<HashMap<String, TranscriptSyncGuardState>>> =
  OnceLock::new();

fn transcript_sync_guard_cache() -> &'static Mutex<HashMap<String, TranscriptSyncGuardState>> {
  TRANSCRIPT_SYNC_GUARD_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

async fn build_transcript_sync_guard_state(
  transcript_path: &str,
  newest_known_id: Option<String>,
  usage: &TokenUsage,
) -> Option<TranscriptSyncGuardState> {
  let metadata = tokio::fs::metadata(transcript_path).await.ok()?;
  let modified_at_nanos = metadata
    .modified()
    .ok()
    .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
    .map(|value| value.as_nanos());

  Some(TranscriptSyncGuardState {
    transcript_path: transcript_path.to_string(),
    newest_known_id,
    usage: usage.into(),
    file_size: metadata.len(),
    modified_at_nanos,
  })
}

fn cached_transcript_sync_matches(session_id: &str, candidate: &TranscriptSyncGuardState) -> bool {
  transcript_sync_guard_cache()
    .lock()
    .ok()
    .and_then(|cache| cache.get(session_id).cloned())
    .is_some_and(|previous| previous == *candidate)
}

fn remember_transcript_sync_guard(session_id: &str, state: TranscriptSyncGuardState) {
  if let Ok(mut cache) = transcript_sync_guard_cache().lock() {
    cache.insert(session_id.to_string(), state);
  }
}

fn next_transcript_sync_guard_state(
  candidate: &TranscriptSyncGuardState,
  current_usage: &TokenUsage,
  plan: &crate::runtime::transcript_sync_policy::TranscriptSyncPlan,
  transcript_rows: &[ConversationRowEntry],
) -> TranscriptSyncGuardState {
  let newest_known_id = match plan.message_sync_decision {
    TranscriptMessageSyncDecision::AppendNewMessages
    | TranscriptMessageSyncDecision::ForceResync => {
      transcript_rows.last().map(|row| row.id().to_string())
    }
    TranscriptMessageSyncDecision::SkipNoNewMessages => candidate.newest_known_id.clone(),
  };
  let usage = plan
    .usage_update
    .as_ref()
    .map(|update| TranscriptSyncUsageSignature::from(&update.usage))
    .unwrap_or_else(|| current_usage.into());

  TranscriptSyncGuardState {
    transcript_path: candidate.transcript_path.clone(),
    newest_known_id,
    usage,
    file_size: candidate.file_size,
    modified_at_nanos: candidate.modified_at_nanos,
  }
}

fn normalize_row_sequences(rows: &mut [ConversationRowEntry]) {
  let mut next_sequence = 0_u64;
  for entry in rows {
    if entry.sequence == 0 && next_sequence > 0 {
      entry.sequence = next_sequence;
    }
    next_sequence = entry.sequence + 1;
  }
}

pub(crate) fn merge_rows_by_sequence(
  mut base: Vec<ConversationRowEntry>,
  mut overlay: Vec<ConversationRowEntry>,
) -> Vec<ConversationRowEntry> {
  normalize_row_sequences(&mut base);
  normalize_row_sequences(&mut overlay);

  let mut merged = BTreeMap::<u64, ConversationRowEntry>::new();
  for entry in base {
    merged.insert(entry.sequence, entry);
  }
  for entry in overlay {
    merged.insert(entry.sequence, entry);
  }
  merged.into_values().collect()
}

pub(crate) async fn hydrate_full_row_history(
  session_id: &str,
  retained_rows: Vec<ConversationRowEntry>,
  total_row_count: Option<u64>,
) -> Vec<ConversationRowEntry> {
  let expected_count = total_row_count.unwrap_or(retained_rows.len() as u64);
  if retained_rows.len() as u64 >= expected_count {
    return retained_rows;
  }

  match load_messages_for_session(session_id).await {
    Ok(db_rows) if !db_rows.is_empty() => merge_rows_by_sequence(db_rows, retained_rows),
    _ => retained_rows,
  }
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
    let _ = state
      .list_tx()
      .send(orbitdock_protocol::ServerMessage::DashboardItemRemoved {
        session_id: thread_id.to_string(),
      });
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
      persist_op: Some(PersistOp::SessionUpdate {
        id: session_id.to_string(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
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
      persist_op: Some(PersistOp::SessionUpdate {
        id: session_id.to_string(),
        status: Some(SessionStatus::Active),
        work_status: Some(WorkStatus::Waiting),
        lifecycle_state: Some(SessionLifecycleState::Open),
        last_activity_at: None,
        last_progress_at: None,
      }),
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

  let transcript_row_count = all_rows.len();
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

  tracing::info!(
      component = "transcript_sync",
      event = "transcript_sync.planned",
      session_id = %session_id,
      transcript_rows = transcript_row_count,
      newest_known_id = ?newest_known_id,
      decision = ?plan.message_sync_decision,
      new_rows = plan.new_rows.len(),
      updated_rows = plan.updated_rows.len(),
      "Transcript sync planned"
  );

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

    tracing::info!(
      component = "connector_cleanup",
      event = "connector_cleanup.session_marked_resumable",
      session_id = %cleanup_session_id,
      provider = ?provider,
      "Cleanup monitor marked session as resumable after connector exit"
    );
  });

  ConnectorCleanupGuard {
    drop_tx: Some(drop_tx),
    session_id,
  }
}

enum ConnectorCleanupDisposition {
  HandledInLoop,
}

/// Guard that triggers cleanup when dropped. Hold this for the lifetime of the
/// connector event loop.
pub(crate) struct ConnectorCleanupGuard {
  drop_tx: Option<oneshot::Sender<ConnectorCleanupDisposition>>,
  #[allow(dead_code)]
  session_id: String,
}

impl ConnectorCleanupGuard {
  pub(crate) fn disarm(&mut self) {
    if let Some(drop_tx) = self.drop_tx.take() {
      let _ = drop_tx.send(ConnectorCleanupDisposition::HandledInLoop);
    }
  }
}

#[cfg(test)]
mod tests {
  use std::sync::Arc;

  use crate::infrastructure::persistence::PersistCommand;
  use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
  use orbitdock_protocol::{
    ClaudeIntegrationMode, SessionLifecycleState, SessionStatus, TokenUsageSnapshotKind, WorkStatus,
  };
  use tokio::sync::mpsc;

  use super::*;
  use crate::support::test_support::ensure_server_test_data_dir;

  #[test]
  fn direct_mode_activation_changes_open_the_lifecycle() {
    let changes = direct_mode_activation_changes(Provider::Codex);

    assert_eq!(changes.status, Some(SessionStatus::Active));
    assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
    assert_eq!(changes.lifecycle_state, Some(SessionLifecycleState::Open));
    assert_eq!(
      changes.codex_integration_mode,
      Some(Some(CodexIntegrationMode::Direct))
    );
  }

  #[test]
  fn direct_resume_failure_changes_downgrade_to_resumable() {
    let changes = direct_resume_failure_changes(Provider::Claude);

    assert_eq!(changes.status, Some(SessionStatus::Active));
    assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
    assert_eq!(
      changes.lifecycle_state,
      Some(SessionLifecycleState::Resumable)
    );
    assert_eq!(
      changes.claude_integration_mode,
      Some(Some(ClaudeIntegrationMode::Direct))
    );
  }

  #[test]
  fn connector_cleanup_changes_keep_direct_sessions_resumable() {
    let codex_changes = connector_cleanup_changes(Provider::Codex);
    assert_eq!(
      codex_changes.lifecycle_state,
      Some(SessionLifecycleState::Resumable)
    );
    assert_eq!(codex_changes.work_status, Some(WorkStatus::Waiting));
    assert_eq!(codex_changes.steerable, Some(false));
    assert_eq!(
      codex_changes.codex_integration_mode,
      Some(Some(CodexIntegrationMode::Direct))
    );

    let claude_changes = connector_cleanup_changes(Provider::Claude);
    assert_eq!(
      claude_changes.lifecycle_state,
      Some(SessionLifecycleState::Resumable)
    );
    assert_eq!(claude_changes.work_status, Some(WorkStatus::Waiting));
    assert_eq!(claude_changes.steerable, Some(false));
    assert_eq!(
      claude_changes.claude_integration_mode,
      Some(Some(ClaudeIntegrationMode::Direct))
    );
  }

  #[test]
  fn detach_classifier_matches_missing_session_signals() {
    assert!(should_detach_direct_connector_after_send_error(
      "Failed to send message: Session abc not found"
    ));
    assert!(should_detach_direct_connector_after_send_error(
      "httpStatus(429, code: Optional(\"session_not_found\"), message: Optional(\"session not found\"))"
    ));
    assert!(should_detach_direct_connector_after_send_error(
      "Thread not found"
    ));
  }

  #[test]
  fn detach_classifier_ignores_non_session_not_found_errors() {
    assert!(!should_detach_direct_connector_after_send_error(
      "Failed to list plugin marketplaces: timeout"
    ));
    assert!(!should_detach_direct_connector_after_send_error(
      "Permission denied while running command"
    ));
  }

  fn user_row(id: &str, sequence: u64) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::User(MessageRowContent {
        id: id.to_string(),
        content: format!("row-{sequence}"),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    }
  }

  fn clear_guard_cache() {
    if let Ok(mut cache) = transcript_sync_guard_cache().lock() {
      cache.clear();
    }
  }

  fn direct_codex_session(session_id: &str) -> crate::domain::sessions::session::SessionHandle {
    let mut session = crate::domain::sessions::session::SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/orbitdock-direct".to_string(),
    );
    session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Waiting);
    session.refresh_snapshot();
    session
  }

  #[test]
  fn cached_transcript_sync_only_skips_identical_inputs() {
    clear_guard_cache();
    let session_id = "session-cache-test";
    let candidate = TranscriptSyncGuardState {
      transcript_path: "/tmp/transcript.jsonl".to_string(),
      newest_known_id: Some("row-2".to_string()),
      usage: TranscriptSyncUsageSignature {
        input_tokens: 1,
        output_tokens: 2,
        cached_tokens: 3,
        context_window: 4,
      },
      file_size: 128,
      modified_at_nanos: Some(42),
    };

    remember_transcript_sync_guard(session_id, candidate.clone());
    assert!(cached_transcript_sync_matches(session_id, &candidate));
    assert!(!cached_transcript_sync_matches(
      session_id,
      &TranscriptSyncGuardState {
        file_size: 129,
        ..candidate
      }
    ));
    clear_guard_cache();
  }

  #[test]
  fn next_guard_state_advances_newest_row_and_usage_after_append() {
    let current_usage = TokenUsage {
      input_tokens: 10,
      output_tokens: 20,
      cached_tokens: 30,
      context_window: 40,
    };
    let next_usage = TokenUsage {
      input_tokens: 11,
      output_tokens: 22,
      cached_tokens: 33,
      context_window: 44,
    };
    let candidate = TranscriptSyncGuardState {
      transcript_path: "/tmp/transcript.jsonl".to_string(),
      newest_known_id: Some("row-1".to_string()),
      usage: TranscriptSyncUsageSignature::from(&current_usage),
      file_size: 128,
      modified_at_nanos: Some(42),
    };
    let transcript_rows = vec![user_row("row-1", 0), user_row("row-2", 1)];
    let plan = crate::runtime::transcript_sync_policy::TranscriptSyncPlan {
      usage_update: Some(
        crate::runtime::transcript_sync_policy::TranscriptUsageUpdate {
          usage: next_usage.clone(),
          snapshot_kind: TokenUsageSnapshotKind::MixedLegacy,
        },
      ),
      message_sync_decision: TranscriptMessageSyncDecision::AppendNewMessages,
      new_rows: vec![transcript_rows[1].clone()],
      updated_rows: vec![],
    };

    let next =
      next_transcript_sync_guard_state(&candidate, &current_usage, &plan, &transcript_rows);

    assert_eq!(next.newest_known_id.as_deref(), Some("row-2"));
    assert_eq!(next.usage, TranscriptSyncUsageSignature::from(&next_usage));
    assert_eq!(next.file_size, candidate.file_size);
    assert_eq!(next.modified_at_nanos, candidate.modified_at_nanos);
  }

  #[tokio::test]
  async fn connector_cleanup_monitor_updates_actor_snapshot_and_persists_resumable_state() {
    ensure_server_test_data_dir();

    let (persist_tx, mut persist_rx) = mpsc::channel(8);
    let registry = Arc::new(
      crate::runtime::session_registry::SessionRegistry::new_with_primary(persist_tx.clone(), true),
    );
    let actor = registry.add_session(direct_codex_session("cleanup-session"));
    let (action_tx, _action_rx) = mpsc::channel(8);
    registry.set_codex_action_tx("cleanup-session", action_tx);

    let mut list_rx = registry.list_tx().subscribe();
    let guard = spawn_connector_cleanup_monitor(
      "cleanup-session".to_string(),
      persist_tx.clone(),
      registry.clone(),
      Provider::Codex,
    );

    drop(guard);

    let Some(PersistCommand::SessionUpdate {
      id,
      status,
      work_status,
      control_mode,
      lifecycle_state,
      ..
    }) = persist_rx.recv().await
    else {
      panic!("expected resumable session update from cleanup monitor");
    };

    assert_eq!(id, "cleanup-session");
    assert_eq!(status, None);
    assert_eq!(work_status, Some(WorkStatus::Waiting));
    assert_eq!(control_mode, None);
    assert_eq!(lifecycle_state, Some(SessionLifecycleState::Resumable));

    let snapshot = actor.snapshot();
    assert_eq!(snapshot.status, SessionStatus::Active);
    assert_eq!(snapshot.work_status, WorkStatus::Waiting);
    assert_eq!(snapshot.lifecycle_state, SessionLifecycleState::Resumable);
    assert!(!snapshot.steerable);
    assert!(registry.get_codex_action_tx("cleanup-session").is_none());

    let Some(orbitdock_protocol::ServerMessage::DashboardConversationUpdated { item, .. }) =
      list_rx.recv().await.ok()
    else {
      panic!("expected dashboard update from actor-applied cleanup");
    };
    assert_eq!(item.session_id, "cleanup-session");
    assert_eq!(item.lifecycle_state, SessionLifecycleState::Resumable);
    assert_eq!(item.work_status, WorkStatus::Waiting);
  }
}
