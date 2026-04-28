use super::*;
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, ConversationRowSummary, MessageRowContent,
};
use orbitdock_protocol::{Provider, ServerMessage, SessionSurface, WorkStatus};

fn test_handle() -> SessionHandle {
  SessionHandle::new(
    "test-session".to_string(),
    Provider::Codex,
    "/tmp/test".to_string(),
  )
}

#[tokio::test]
async fn actor_applies_back_to_back_commands_in_order() {
  let (persist_tx, _persist_rx) = mpsc::channel(64);
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);
  let (reply_tx, _reply_rx) = tokio::sync::oneshot::channel();

  actor_handle
    .send(SessionCommand::SetCustomNameAndNotify {
      name: Some("Test Session".to_string()),
      persist_op: None,
      reply: reply_tx,
    })
    .await;

  actor_handle
    .send(SessionCommand::SetWorkStatus {
      status: WorkStatus::Working,
    })
    .await;

  let summary = actor_handle.summary().await.unwrap();
  assert_eq!(summary.custom_name.as_deref(), Some("Test Session"));
  assert_eq!(summary.work_status, WorkStatus::Working);
}

#[tokio::test]
async fn actor_snapshot_updates_after_mutation() {
  let (persist_tx, _persist_rx) = mpsc::channel(64);
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  let snap = actor_handle.snapshot();
  assert_eq!(snap.work_status, WorkStatus::Waiting);

  actor_handle
    .send(SessionCommand::SetWorkStatus {
      status: WorkStatus::Working,
    })
    .await;

  let _ = actor_handle.summary().await.unwrap();

  let snap = actor_handle.snapshot();
  assert_eq!(snap.work_status, WorkStatus::Working);
}

#[tokio::test]
async fn actor_subscribe_without_revision_streams_live_updates() {
  let (persist_tx, _writer_handle) = spawn_mock_writer();
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  let (tx, rx) = tokio::sync::oneshot::channel();
  actor_handle
    .send(SessionCommand::Subscribe {
      since_revision: None,
      reply: tx,
    })
    .await;

  let result = rx.await.unwrap();
  let mut rx = match result {
    crate::runtime::session_commands::SubscribeResult::Replay { events, rx } => {
      assert!(events.is_empty());
      rx
    }
    crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {
      panic!("expected replay, got resync-required")
    }
  };

  actor_handle
    .send(SessionCommand::AddRowAndBroadcast {
      entry: user_row("row-live"),
    })
    .await;

  loop {
    if let ServerMessage::ConversationRowsChanged {
      upserted,
      total_row_count,
      ..
    } = rx.recv().await.expect("live update after subscribe")
    {
      let row = upserted.iter().find(|entry| entry.id() == "row-live");
      assert!(row.is_some());
      assert_eq!(total_row_count, 1);
      break;
    }
  }
}

#[tokio::test]
async fn actor_subscribe_with_revision_replays_existing_rows_and_stays_live() {
  let (persist_tx, _writer_handle) = spawn_mock_writer();
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  actor_handle
    .send(SessionCommand::AddRowAndBroadcast {
      entry: user_row("row-replayed"),
    })
    .await;

  let page = actor_handle.conversation_page(None, 10).await.unwrap();
  assert_eq!(page.rows.len(), 1);

  let (tx, rx) = tokio::sync::oneshot::channel();
  actor_handle
    .send(SessionCommand::Subscribe {
      since_revision: Some(0),
      reply: tx,
    })
    .await;

  let result = rx.await.unwrap();
  match result {
    crate::runtime::session_commands::SubscribeResult::Replay { events, rx } => {
      let row_event = events
        .iter()
        .find(|event| event.contains("row-replayed"))
        .expect("expected replay to include the row append event");
      let replay: serde_json::Value =
        serde_json::from_str(row_event).expect("replay event should be valid json");
      assert_eq!(
        replay.get("revision").and_then(|value| value.as_u64()),
        Some(1)
      );
      assert!(row_event.contains("row-replayed"));

      actor_handle
        .send(SessionCommand::AddRowAndBroadcast {
          entry: user_row("row-follow-up"),
        })
        .await;

      let mut rx = rx;
      loop {
        if let ServerMessage::ConversationRowsChanged { upserted, .. } =
          rx.recv().await.expect("live update after replay")
        {
          assert!(upserted.iter().any(|entry| entry.id() == "row-follow-up"));
          break;
        }
      }
    }
    crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {
      panic!("expected replay, got resync-required")
    }
  }
}

#[tokio::test]
async fn actor_processes_connector_events_via_transition() {
  let (persist_tx, _persist_rx) = mpsc::channel(64);
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::TurnStarted,
    })
    .await;

  let _ = actor_handle.summary().await.unwrap();

  let snap = actor_handle.snapshot();
  assert_eq!(snap.work_status, WorkStatus::Working);
}

fn user_row(id: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
      content: format!("msg-{id}"),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn assistant_row(id: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: id.to_string(),
      content: format!("response-{id}"),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

/// Spawn a mock persistence writer that simulates DB-assigned sequences.
/// Returns the persist_tx for the actor and a join handle that resolves
/// to all (row_id, db_assigned_sequence) pairs once the sender is dropped.
fn spawn_mock_writer() -> (
  mpsc::Sender<PersistCommand>,
  tokio::task::JoinHandle<Vec<(String, u64)>>,
) {
  let (persist_tx, mut persist_rx) = mpsc::channel::<PersistCommand>(64);
  let handle = tokio::spawn(async move {
    let mut seq_counters: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
    // Track assigned sequences for upsert lookups
    let mut assigned: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
    let mut result = Vec::new();

    while let Some(cmd) = persist_rx.recv().await {
      match cmd {
        PersistCommand::RowAppend {
          session_id,
          entry,
          viewer_present: _,
          sequence_tx,
          ..
        } => {
          let counter = seq_counters.entry(session_id).or_insert(0);
          let db_seq = *counter;
          *counter += 1;
          assigned.insert(entry.id().to_string(), db_seq);
          result.push((entry.id().to_string(), db_seq));
          if let Some(tx) = sequence_tx {
            let _ = tx.send(db_seq);
          }
        }
        PersistCommand::RowUpsert {
          session_id,
          entry,
          viewer_present: _,
          sequence_tx,
          ..
        } => {
          let row_id = entry.id().to_string();
          // Preserve original sequence on conflict (like the real DB)
          let db_seq = if let Some(&existing) = assigned.get(&row_id) {
            existing
          } else {
            let counter = seq_counters.entry(session_id).or_insert(0);
            let seq = *counter;
            *counter += 1;
            assigned.insert(row_id.clone(), seq);
            seq
          };
          result.push((row_id, db_seq));
          if let Some(tx) = sequence_tx {
            let _ = tx.send(db_seq);
          }
        }
        _ => {} // Ignore non-row commands
      }
    }
    result
  });
  (persist_tx, handle)
}

#[tokio::test]
async fn add_row_and_broadcast_assigns_contiguous_sequences() {
  let (persist_tx, writer_handle) = spawn_mock_writer();
  let actor = SessionActorHandle::spawn(test_handle(), persist_tx);

  // Send a burst of rows all with sequence=0 (the pattern that caused the bug)
  for i in 0..5 {
    actor
      .send(SessionCommand::AddRowAndBroadcast {
        entry: user_row(&format!("row-{i}")),
      })
      .await;
  }

  // Drop the actor so the persist channel closes and the mock writer finishes
  drop(actor);
  let persisted = writer_handle.await.unwrap();

  assert_eq!(persisted.len(), 5);
  for (i, (id, seq)) in persisted.iter().enumerate() {
    assert_eq!(id, &format!("row-{i}"));
    assert_eq!(*seq, i as u64, "row {id} should have sequence {i}");
  }
}

#[tokio::test]
async fn add_row_and_broadcast_reply_returns_db_assigned_sequence() {
  let (persist_tx, _writer_handle) = spawn_mock_writer();
  let actor = SessionActorHandle::spawn(test_handle(), persist_tx);

  actor
    .send(SessionCommand::AddRowAndBroadcast {
      entry: user_row("row-existing"),
    })
    .await;

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
  actor
    .send(SessionCommand::AddRowAndBroadcastAndReply {
      entry: user_row("row-authoritative"),
      reply: reply_tx,
    })
    .await;

  let returned = reply_rx.await.expect("authoritative row");
  assert_eq!(returned.id(), "row-authoritative");
  assert_eq!(returned.sequence, 1);

  let page = actor.conversation_page(None, 10).await.unwrap();
  let stored = page
    .rows
    .into_iter()
    .find(|row| row.id() == "row-authoritative")
    .expect("stored row");
  assert_eq!(stored.sequence, 1);
}

#[tokio::test]
async fn burst_of_mixed_row_types_has_monotonic_sequences() {
  let (persist_tx, writer_handle) = spawn_mock_writer();
  let actor = SessionActorHandle::spawn(test_handle(), persist_tx);

  // Simulate a realistic burst: user message, then rapid assistant + user
  actor
    .send(SessionCommand::AddRowAndBroadcast {
      entry: user_row("user-1"),
    })
    .await;
  for i in 0..3 {
    actor
      .send(SessionCommand::AddRowAndBroadcast {
        entry: assistant_row(&format!("assistant-{i}")),
      })
      .await;
  }
  actor
    .send(SessionCommand::AddRowAndBroadcast {
      entry: user_row("user-2"),
    })
    .await;

  // Query in-memory state before dropping
  let page = actor.conversation_page(None, 100).await.unwrap();
  let in_memory_seqs: Vec<u64> = page.rows.iter().map(|r| r.sequence).collect();

  drop(actor);
  let persisted = writer_handle.await.unwrap();
  let persisted_seqs: Vec<u64> = persisted.iter().map(|(_, seq)| *seq).collect();

  // Both must be strictly increasing
  for pair in in_memory_seqs.windows(2) {
    assert!(
      pair[1] > pair[0],
      "in-memory sequences must be strictly increasing: got {in_memory_seqs:?}"
    );
  }
  // In-memory sequences match what the mock DB assigned
  assert_eq!(in_memory_seqs, persisted_seqs);
}

#[tokio::test]
async fn in_memory_sequences_match_db_assigned_sequences() {
  let (persist_tx, writer_handle) = spawn_mock_writer();
  let actor = SessionActorHandle::spawn(test_handle(), persist_tx);

  for i in 0..3 {
    actor
      .send(SessionCommand::AddRowAndBroadcast {
        entry: user_row(&format!("row-{i}")),
      })
      .await;
  }

  let page = actor.conversation_page(None, 100).await.unwrap();
  let in_memory: Vec<(String, u64)> = page
    .rows
    .iter()
    .map(|r| (r.id().to_string(), r.sequence))
    .collect();

  drop(actor);
  let persisted = writer_handle.await.unwrap();

  // In-memory and DB-assigned must be identical
  assert_eq!(in_memory, persisted);
}

#[tokio::test]
async fn actor_emits_detail_invalidation_for_state_only_transition() {
  let (persist_tx, _writer_handle) = spawn_mock_writer();
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
  actor_handle
    .send(SessionCommand::Subscribe {
      since_revision: None,
      reply: reply_tx,
    })
    .await;

  let mut rx = match reply_rx.await.unwrap() {
    crate::runtime::session_commands::SubscribeResult::Replay { rx, .. } => rx,
    crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {
      panic!("fresh actor subscribe should not require resync")
    }
  };

  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::TurnStarted,
    })
    .await;

  let _ = actor_handle.summary().await.unwrap();

  let mut emitted_detail_invalidation = false;
  while let Ok(message) = rx.try_recv() {
    if let ServerMessage::SessionSurfaceInvalidated { surface, .. } = message {
      if surface == SessionSurface::Detail {
        emitted_detail_invalidation = true;
      }
    }
  }

  assert!(emitted_detail_invalidation);
}

#[tokio::test]
async fn actor_skips_tiny_initial_streaming_broadcasts_and_emits_final_row() {
  let (persist_tx, _writer_handle) = spawn_mock_writer();
  let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
  actor_handle
    .send(SessionCommand::Subscribe {
      since_revision: None,
      reply: reply_tx,
    })
    .await;

  let mut rx = match reply_rx.await.unwrap() {
    crate::runtime::session_commands::SubscribeResult::Replay { rx, .. } => rx,
    crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {
      panic!("fresh actor subscribe should not require resync")
    }
  };

  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::TurnStarted,
    })
    .await;

  let row_id = "assistant-stream".to_string();
  let row = |content: &str, is_streaming: bool| ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence: 0,
    turn_id: Some("turn-1".to_string()),
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: row_id.clone(),
      content: content.to_string(),
      turn_id: Some("turn-1".to_string()),
      timestamp: Some("2026-03-13T12:00:00Z".to_string()),
      is_streaming,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  };

  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::RowCreated(row("a", true)),
    })
    .await;
  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::RowUpdated {
        row_id: row_id.clone(),
        entry: row("ab", true),
      },
    })
    .await;
  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::RowUpdated {
        row_id: row_id.clone(),
        entry: row("abc", true),
      },
    })
    .await;
  actor_handle
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::RowUpdated {
        row_id: row_id.clone(),
        entry: row("abcd", false),
      },
    })
    .await;

  let _ = actor_handle.summary().await.unwrap();

  let mut emitted_contents = Vec::new();
  let mut invalidated_surfaces = Vec::new();
  while let Ok(message) = rx.try_recv() {
    match message {
      ServerMessage::ConversationRowsChanged { upserted, .. } => {
        for entry in upserted {
          if entry.id() == row_id {
            if let ConversationRowSummary::Assistant(message) = entry.row {
              emitted_contents.push((message.content, message.is_streaming));
            }
          }
        }
      }
      ServerMessage::SessionSurfaceInvalidated { surface, .. } => {
        invalidated_surfaces.push(surface);
      }
      _ => {}
    }
  }

  assert_eq!(emitted_contents, vec![("abcd".to_string(), false)]);
  assert_eq!(
    invalidated_surfaces
      .iter()
      .filter(|surface| **surface == SessionSurface::Conversation)
      .count(),
    1
  );
}
