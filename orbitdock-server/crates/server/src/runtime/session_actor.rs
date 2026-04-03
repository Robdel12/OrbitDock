//! Session actor — owns a SessionHandle and processes commands sequentially.
//!
//! Each session runs as an independent tokio task. External callers
//! communicate via `SessionActorHandle` which sends `SessionCommand`
//! messages over an mpsc channel. Lock-free reads go through `ArcSwap`.

use std::sync::Arc;

use arc_swap::ArcSwap;
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

#[cfg(test)]
use crate::domain::sessions::conversation::ConversationPage;
use crate::domain::sessions::session::{SessionHandle, SessionSnapshot};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use orbitdock_protocol::{SessionState, SessionSummary};

/// Handle to a running session actor (cheap to Clone).
#[derive(Clone)]
pub struct SessionActorHandle {
  pub id: String,
  command_tx: mpsc::Sender<SessionCommand>,
  snapshot: Arc<ArcSwap<SessionSnapshot>>,
}

impl SessionActorHandle {
  /// Create a handle from pre-built parts (used by CodexSession event loop).
  pub fn new(
    id: String,
    command_tx: mpsc::Sender<SessionCommand>,
    snapshot: Arc<ArcSwap<SessionSnapshot>>,
  ) -> Self {
    Self {
      id,
      command_tx,
      snapshot,
    }
  }

  /// Spawn a passive session actor (no CodexConnector), returning a handle.
  pub fn spawn(
    handle: SessionHandle,
    persist_tx: mpsc::Sender<PersistCommand>,
  ) -> SessionActorHandle {
    let (command_tx, command_rx) = mpsc::channel(256);
    let snapshot = handle.snapshot_arc();
    let id = handle.id().to_string();
    handle.refresh_snapshot();

    tokio::spawn(passive_actor_loop(handle, command_rx, persist_tx));

    SessionActorHandle {
      id,
      command_tx,
      snapshot,
    }
  }

  /// Send a command to the actor (fire-and-forget).
  pub async fn send(&self, cmd: SessionCommand) {
    if self.send_checked(cmd).await.is_err() {
      warn!(
          component = "session_actor",
          session_id = %self.id,
          "Actor channel closed, command dropped"
      );
    }
  }

  /// Send a command to the actor and return an error when delivery fails.
  pub async fn send_checked(&self, cmd: SessionCommand) -> Result<(), String> {
    self
      .command_tx
      .send(cmd)
      .await
      .map_err(|error| error.to_string())
  }

  /// Try to send a command without awaiting (for non-async contexts).
  #[allow(dead_code)]
  pub fn try_send(&self, cmd: SessionCommand) {
    if self.command_tx.try_send(cmd).is_err() {
      warn!(
          component = "session_actor",
          session_id = %self.id,
          "Actor channel full or closed"
      );
    }
  }

  /// Lock-free snapshot read.
  pub fn snapshot(&self) -> Arc<SessionSnapshot> {
    self.snapshot.load_full()
  }

  /// Get the raw ArcSwap (for passing to list-level operations).
  #[allow(dead_code)]
  pub fn snapshot_swap(&self) -> &Arc<ArcSwap<SessionSnapshot>> {
    &self.snapshot
  }

  /// Get a clone of the command sender (for passing to spawned tasks).
  #[allow(dead_code)]
  pub fn command_tx(&self) -> mpsc::Sender<SessionCommand> {
    self.command_tx.clone()
  }

  pub async fn retained_state(&self) -> Result<SessionState, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::GetRetainedState { reply: reply_tx })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }

  pub async fn summary(&self) -> Result<SessionSummary, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::GetSummary { reply: reply_tx })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }

  pub async fn last_tool(&self) -> Result<Option<String>, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::GetLastTool { reply: reply_tx })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }

  #[cfg(test)]
  pub async fn conversation_page(
    &self,
    before_sequence: Option<u64>,
    limit: usize,
  ) -> Result<ConversationPage, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::GetConversationPage {
        before_sequence,
        limit,
        reply: reply_tx,
      })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }

  pub async fn resolve_user_message_id(
    &self,
    num_turns_from_end: u32,
  ) -> Result<Option<String>, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::ResolveUserMessageId {
        num_turns_from_end,
        reply: reply_tx,
      })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }

  pub async fn mark_read(&self) -> Result<u64, String> {
    let (reply_tx, reply_rx) = oneshot::channel();
    self
      .send(SessionCommand::MarkRead { reply: reply_tx })
      .await;
    reply_rx.await.map_err(|error| error.to_string())
  }
}

/// Simple actor loop for passive sessions (no CodexConnector).
/// Reuses the shared `handle_session_command` from session_command_handler.
/// Exits early on `TakeHandle` — the handle is sent back to the caller
/// so it can be handed off to a connector's event loop.
async fn passive_actor_loop(
  mut handle: SessionHandle,
  mut command_rx: mpsc::Receiver<SessionCommand>,
  persist_tx: mpsc::Sender<PersistCommand>,
) {
  while let Some(cmd) = command_rx.recv().await {
    if let SessionCommand::TakeHandle { reply } = cmd {
      let _ = reply.send(handle);
      return; // Stop the passive loop — handle is now owned by the caller
    }
    crate::runtime::session_command_handler::handle_session_command(cmd, &mut handle, &persist_tx)
      .await;
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, ConversationRowSummary, MessageRowContent,
  };
  use orbitdock_protocol::{Provider, WorkStatus};

  fn test_handle() -> SessionHandle {
    SessionHandle::new(
      "test-session".to_string(),
      Provider::Codex,
      "/tmp/test".to_string(),
    )
  }

  #[tokio::test]
  async fn actor_processes_commands_sequentially() {
    let (persist_tx, _persist_rx) = mpsc::channel(64);
    let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

    let (tx, rx) = tokio::sync::oneshot::channel();
    actor_handle
      .send(SessionCommand::SetCustomNameAndNotify {
        name: Some("Test Session".to_string()),
        persist_op: None,
        reply: tx,
      })
      .await;
    let summary = rx.await.unwrap();
    assert_eq!(summary.custom_name.as_deref(), Some("Test Session"));
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

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    let snap = actor_handle.snapshot();
    assert_eq!(snap.work_status, WorkStatus::Working);
  }

  #[tokio::test]
  async fn actor_subscribe_returns_state_and_receiver() {
    let (persist_tx, _persist_rx) = mpsc::channel(64);
    let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

    let (tx, rx) = tokio::sync::oneshot::channel();
    actor_handle
      .send(SessionCommand::Subscribe {
        since_revision: None,
        reply: tx,
      })
      .await;

    let result = rx.await.unwrap();
    match result {
      crate::runtime::session_commands::SubscribeResult::Replay { .. } => {
        panic!("expected resync-required, got replay")
      }
      crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {}
    }
  }

  #[tokio::test]
  async fn actor_subscribe_with_revision_returns_resync_required() {
    let (persist_tx, _persist_rx) = mpsc::channel(64);
    let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

    let (tx, rx) = tokio::sync::oneshot::channel();
    actor_handle
      .send(SessionCommand::Subscribe {
        since_revision: Some(0),
        reply: tx,
      })
      .await;

    let result = rx.await.unwrap();
    match result {
      crate::runtime::session_commands::SubscribeResult::ResyncRequired { .. } => {}
      crate::runtime::session_commands::SubscribeResult::Replay { .. } => {
        panic!("expected resync-required, got replay")
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

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

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
      let mut seq_counters: std::collections::HashMap<String, u64> =
        std::collections::HashMap::new();
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
      crate::runtime::session_commands::SubscribeResult::ResyncRequired { rx } => rx,
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

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    let mut emitted_contents = Vec::new();
    while let Ok(message) = rx.try_recv() {
      if let orbitdock_protocol::ServerMessage::ConversationRowsChanged { upserted, .. } = message {
        for entry in upserted {
          if entry.id() == row_id {
            if let ConversationRowSummary::Assistant(message) = entry.row {
              emitted_contents.push((message.content, message.is_streaming));
            }
          }
        }
      }
    }

    assert_eq!(emitted_contents, vec![("abcd".to_string(), false)]);
  }
}
