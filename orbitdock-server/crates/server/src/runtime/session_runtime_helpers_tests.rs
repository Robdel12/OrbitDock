use std::sync::Arc;

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SubscribeResult;
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent};
use orbitdock_protocol::{
  ClaudeIntegrationMode, SessionLifecycleState, SessionStatus, TokenUsageSnapshotKind, WorkStatus,
};
use tokio::sync::{mpsc, oneshot};

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
        snapshot_kind: TokenUsageSnapshotKind::Mixed,
      },
    ),
    message_sync_decision: TranscriptMessageSyncDecision::AppendNewMessages,
    new_rows: vec![transcript_rows[1].clone()],
    updated_rows: vec![],
  };

  let next = next_transcript_sync_guard_state(&candidate, &current_usage, &plan, &transcript_rows);

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

  let revision = loop {
    let Some(message) = list_rx.recv().await.ok() else {
      panic!("expected dashboard update from actor-applied cleanup");
    };
    if let orbitdock_protocol::ServerMessage::ActiveSessionsInvalidated { revision } = message {
      break revision;
    }
  };
  assert!(revision > 0);
}

#[tokio::test]
async fn connector_loop_step_breaks_on_panic() {
  let control = run_connector_loop_step(
    "test_connector",
    "test_connector.loop_step_panicked",
    "panic-session",
    "unit_test",
    async {
      panic!("boom");
    },
  )
  .await;

  assert_eq!(control, ConnectorLoopControl::Break);
}

#[tokio::test]
async fn rebound_passive_actor_keeps_session_subscribable() {
  ensure_server_test_data_dir();

  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry =
    Arc::new(crate::runtime::session_registry::SessionRegistry::new_with_primary(persist_tx, true));

  let mut handle = direct_codex_session("rebind-session");
  handle.apply_changes(&StateChanges {
    lifecycle_state: Some(SessionLifecycleState::Resumable),
    work_status: Some(WorkStatus::Waiting),
    steerable: Some(false),
    ..Default::default()
  });

  rebind_session_as_passive_actor(&registry, handle);

  let actor = registry
    .get_session("rebind-session")
    .expect("passive actor should be registered");
  let (reply_tx, reply_rx) = oneshot::channel();
  actor
    .send_checked(SessionCommand::Subscribe {
      since_revision: None,
      reply: reply_tx,
    })
    .await
    .expect("passive actor should accept subscribe commands");

  match reply_rx.await.expect("subscribe result") {
    SubscribeResult::ResyncRequired { .. } | SubscribeResult::Replay { .. } => {}
  }

  let snapshot = actor.snapshot();
  assert_eq!(snapshot.lifecycle_state, SessionLifecycleState::Resumable);
  assert_eq!(snapshot.work_status, WorkStatus::Waiting);
}
