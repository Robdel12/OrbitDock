use super::*;
use crate::infrastructure::persistence::PersistCommand;
use orbitdock_connector_core::{
  ConnectorOutput, ConnectorRuntimeDirective, ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::{
  rows::MessageDeliveryStatus, ConversationRowEntry, MessageRowContent,
};
use orbitdock_protocol::{
  CodexIntegrationMode, Provider, SessionLifecycleState, SessionSurface, SteerOutcome,
};
use tokio::sync::mpsc;

fn user_entry(session_id: &str, row_id: &str, content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: row_id.to_string(),
      content: content.to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn assistant_entry(session_id: &str, row_id: &str, content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: row_id.to_string(),
      content: content.to_string(),
      turn_id: None,
      timestamp: Some("2026-03-20T12:00:00Z".to_string()),
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn steer_entry(
  session_id: &str,
  row_id: &str,
  content: &str,
  delivery_status: MessageDeliveryStatus,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Steer(MessageRowContent {
      id: row_id.to_string(),
      content: content.to_string(),
      turn_id: None,
      timestamp: Some("2026-03-20T12:00:00Z".to_string()),
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: Some(delivery_status),
    }),
  }
}

#[test]
fn classifies_tool_pty_created_as_transport_effect() {
  let dispatch = classify_connector_output(ConnectorOutput::Transport(
    ConnectorTransportEffect::ToolPtyCreated {
      tool_id: "tool-1".to_string(),
    },
  ));

  match dispatch {
    ConnectorDispatch::TransportEffect(ConnectorTransportEffect::ToolPtyCreated { tool_id }) => {
      assert_eq!(tool_id, "tool-1");
    }
    other => panic!("expected ToolPtyCreated transport effect, got {other:?}"),
  }
}

#[test]
fn classifies_hook_session_id_as_runtime_directive() {
  let dispatch = classify_connector_output(ConnectorOutput::Runtime(
    ConnectorRuntimeDirective::HookSessionId("hook-session-1".to_string()),
  ));

  match dispatch {
    ConnectorDispatch::RuntimeDirective(ConnectorRuntimeDirective::HookSessionId(
      hook_session_id,
    )) => {
      assert_eq!(hook_session_id, "hook-session-1");
    }
    other => panic!("expected HookSessionId runtime directive, got {other:?}"),
  }
}

#[tokio::test]
async fn turn_completed_derives_non_steerable_snapshot_and_delta() {
  let (persist_tx, mut persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  handle.set_status(SessionStatus::Active);
  handle.set_work_status(WorkStatus::Working);

  let mut rx = handle.subscribe();

  dispatch_connector_event(
    "session-1",
    ConnectorStateEvent::TurnCompleted,
    &mut handle,
    &persist_tx,
  )
  .await;

  let Some(PersistCommand::SessionUpdate {
    work_status: Some(WorkStatus::Waiting),
    ..
  }) = persist_rx.recv().await
  else {
    panic!("expected waiting SessionUpdate");
  };

  let snapshot = handle.to_snapshot();
  assert_eq!(snapshot.work_status, WorkStatus::Waiting);
  assert!(!snapshot.steerable);

  let msg = rx.recv().await.expect("expected session delta");
  let ServerMessage::SessionDelta { changes, .. } = msg else {
    panic!("expected session delta, got {msg:?}");
  };
  assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
  assert_eq!(changes.steerable, Some(false));
}

#[test]
fn suppresses_duplicate_codex_user_echo_for_direct_sessions() {
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  handle.add_row(user_entry("session-1", "user-http-1", "hello world"));

  let event = ConnectorStateEvent::ConversationRowCreated(user_entry(
    "session-1",
    "user-codex-1",
    "hello world",
  ));

  assert!(should_suppress_connector_user_echo(&handle, &event));
}

#[test]
fn does_not_suppress_distinct_user_message_content() {
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  handle.add_row(user_entry("session-1", "user-http-1", "hello world"));

  let event = ConnectorStateEvent::ConversationRowCreated(user_entry(
    "session-1",
    "user-codex-1",
    "different",
  ));

  assert!(!should_suppress_connector_user_echo(&handle, &event));
}

#[test]
fn does_not_suppress_user_echo_from_matching_steer_content() {
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));

  handle.add_row(ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Steer(MessageRowContent {
      id: "steer-http-1".to_string(),
      content: "hello world".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: Some(MessageDeliveryStatus::Pending),
    }),
  });

  let event = ConnectorStateEvent::ConversationRowCreated(user_entry(
    "session-1",
    "user-codex-1",
    "hello world",
  ));

  assert!(!should_suppress_connector_user_echo(&handle, &event));
}

#[test]
fn does_not_suppress_codex_user_rows_for_passive_sessions() {
  let handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );

  let event = ConnectorStateEvent::ConversationRowCreated(user_entry(
    "session-1",
    "user-codex-1",
    "hello world",
  ));

  assert!(!should_suppress_connector_user_echo(&handle, &event));
}

#[test]
fn does_not_suppress_user_rows_when_local_copy_is_missing() {
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));

  let event = ConnectorStateEvent::ConversationRowCreated(user_entry(
    "session-1",
    "user-codex-1",
    "hello world",
  ));

  assert!(!should_suppress_connector_user_echo(&handle, &event));
}

#[tokio::test]
async fn duplicate_row_created_does_not_refresh_activity_or_unread() {
  let (persist_tx, mut persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  let entry = assistant_entry("session-1", "assistant-1", "already synced");
  handle.add_row(entry.clone());
  handle.mark_read();
  handle.set_last_activity_at(Some("2026-03-20T12:34:56Z".to_string()));
  handle.refresh_snapshot();

  dispatch_transition_input(
    "session-1",
    transition::Input::RowCreated(entry),
    &mut handle,
    &persist_tx,
  )
  .await;

  assert_eq!(handle.unread_count(), 0);
  assert_eq!(
    handle.to_snapshot().last_activity_at.as_deref(),
    Some("2026-03-20T12:34:56Z")
  );
  assert!(persist_rx.try_recv().is_err());
}

#[tokio::test]
async fn subscribe_without_cursor_attaches_live_stream_without_resync() {
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();

  handle_session_command(
    SessionCommand::Subscribe {
      since_revision: None,
      reply: reply_tx,
    },
    &mut handle,
    &persist_tx,
  )
  .await;

  let result = reply_rx.await.expect("subscribe result");
  match result {
    SubscribeResult::Replay { events, .. } => assert!(events.is_empty()),
    SubscribeResult::ResyncRequired { .. } => {
      panic!("fresh subscribe without cursor should not require resync")
    }
  }
}

#[tokio::test]
async fn row_updated_does_not_increment_unread_count() {
  let (persist_tx, mut persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.add_row(assistant_entry("session-1", "assistant-1", "draft"));
  handle.mark_read();
  handle.refresh_snapshot();

  let persist_task = tokio::spawn(async move {
    let Some(PersistCommand::RowUpsert { sequence_tx, .. }) = persist_rx.recv().await else {
      panic!("expected row upsert persist command");
    };
    let Some(sequence_tx) = sequence_tx else {
      panic!("expected row upsert sequence response channel");
    };
    let _ = sequence_tx.send(0);
  });

  dispatch_transition_input(
    "session-1",
    transition::Input::RowUpdated {
      row_id: "assistant-1".to_string(),
      entry: assistant_entry("session-1", "assistant-1", "final"),
    },
    &mut handle,
    &persist_tx,
  )
  .await;
  persist_task.await.expect("persist task should complete");

  assert_eq!(handle.unread_count(), 0);
  let Some(updated) = handle.row_by_id("assistant-1") else {
    panic!("expected updated assistant row");
  };
  let ConversationRow::Assistant(message) = &updated.row else {
    panic!("expected assistant row");
  };
  assert_eq!(message.content, "final");
}

#[tokio::test]
async fn update_steer_outcome_marks_pending_steer_accepted_and_invalidates_detail_surface() {
  let (persist_tx, mut persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.add_row(steer_entry(
    "session-1",
    "steer-1",
    "nudge it",
    MessageDeliveryStatus::Pending,
  ));
  handle.refresh_snapshot();

  let mut rx = handle.subscribe();
  let persist_task = tokio::spawn(async move {
    let Some(PersistCommand::RowUpsert { sequence_tx, .. }) = persist_rx.recv().await else {
      panic!("expected row upsert persist command");
    };
    let Some(sequence_tx) = sequence_tx else {
      panic!("expected row upsert sequence response channel");
    };
    let _ = sequence_tx.send(0);
  });

  handle_session_command(
    SessionCommand::UpdateSteerOutcome {
      message_id: "steer-1".to_string(),
      outcome: SteerOutcome::Accepted,
    },
    &mut handle,
    &persist_tx,
  )
  .await;
  persist_task.await.expect("persist task should complete");

  let Some(updated) = handle.row_by_id("steer-1") else {
    panic!("expected updated steer row");
  };
  let ConversationRow::Steer(message) = &updated.row else {
    panic!("expected steer row");
  };
  assert_eq!(
    message.delivery_status,
    Some(MessageDeliveryStatus::Accepted)
  );

  let mut saw_row_update = false;
  let mut saw_detail_invalidation = false;
  let mut saw_steer_outcome = false;
  while let Ok(message) = rx.try_recv() {
    match message {
      ServerMessage::ConversationRowsChanged { upserted, .. } => {
        saw_row_update = upserted.iter().any(|entry| entry.id() == "steer-1");
      }
      ServerMessage::SteerOutcome {
        message_id,
        outcome,
        ..
      } => {
        saw_steer_outcome = message_id == "steer-1" && outcome == SteerOutcome::Accepted;
      }
      ServerMessage::SessionSurfaceInvalidated {
        surface: SessionSurface::Detail,
        ..
      } => {
        saw_detail_invalidation = true;
      }
      _ => {}
    }
  }

  assert!(saw_row_update);
  assert!(saw_steer_outcome);
  assert!(saw_detail_invalidation);
}

#[tokio::test]
async fn apply_delta_updates_actor_snapshot_and_persists_the_same_transition() {
  let (persist_tx, mut persist_rx) = mpsc::channel(8);
  let mut handle = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  handle.refresh_snapshot();

  handle_session_command(
    SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        lifecycle_state: Some(SessionLifecycleState::Resumable),
        work_status: Some(WorkStatus::Waiting),
        steerable: Some(false),
        ..Default::default()
      }),
      persist_op: Some(PersistCommand::SessionUpdate {
        id: "session-1".to_string(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        control_mode: None,
        lifecycle_state: Some(SessionLifecycleState::Resumable),
        last_activity_at: None,
        last_progress_at: None,
      }),
    },
    &mut handle,
    &persist_tx,
  )
  .await;

  let Some(PersistCommand::SessionUpdate {
    id,
    status,
    work_status,
    lifecycle_state,
    ..
  }) = persist_rx.recv().await
  else {
    panic!("expected cleanup SessionUpdate persist command");
  };

  assert_eq!(id, "session-1");
  assert_eq!(status, None);
  assert_eq!(work_status, Some(WorkStatus::Waiting));
  assert_eq!(lifecycle_state, Some(SessionLifecycleState::Resumable));

  let snapshot = handle.to_snapshot();
  assert_eq!(snapshot.status, SessionStatus::Active);
  assert_eq!(snapshot.work_status, WorkStatus::Waiting);
  assert_eq!(snapshot.lifecycle_state, SessionLifecycleState::Resumable);
  assert!(!snapshot.steerable);
}
