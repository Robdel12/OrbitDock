//! Session actor — owns a SessionHandle and processes commands sequentially.
//!
//! Each session runs as an independent tokio task. External callers
//! communicate via `SessionActorHandle` which sends `SessionCommand`
//! messages over an mpsc channel. Lock-free reads go through `ArcSwap`.

use std::sync::Arc;

use arc_swap::ArcSwap;
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

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

  /// Lock-free snapshot read.
  pub fn snapshot(&self) -> Arc<SessionSnapshot> {
    self.snapshot.load_full()
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
#[path = "session_actor_tests.rs"]
mod session_actor_tests;
