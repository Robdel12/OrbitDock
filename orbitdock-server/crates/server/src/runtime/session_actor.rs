//! Session actor — owns a SessionHandle and processes commands sequentially.
//!
//! Each session runs as an independent tokio task. External callers
//! communicate via `SessionActorHandle` which sends `SessionCommand`
//! messages over an mpsc channel. Lock-free reads go through `ArcSwap`.

use std::sync::Arc;

use arc_swap::ArcSwap;
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
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
        if self.command_tx.send(cmd).await.is_err() {
            warn!(
                component = "session_actor",
                session_id = %self.id,
                "Actor channel closed, command dropped"
            );
        }
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
        self.send(SessionCommand::GetRetainedState { reply: reply_tx })
            .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn summary(&self) -> Result<SessionSummary, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::GetSummary { reply: reply_tx })
            .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn last_tool(&self) -> Result<Option<String>, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::GetLastTool { reply: reply_tx })
            .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn conversation_bootstrap(
        &self,
        limit: usize,
    ) -> Result<ConversationBootstrap, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::GetConversationBootstrap {
            limit,
            reply: reply_tx,
        })
        .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn conversation_page(
        &self,
        before_sequence: Option<u64>,
        limit: usize,
    ) -> Result<ConversationPage, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::GetConversationPage {
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
        self.send(SessionCommand::ResolveUserMessageId {
            num_turns_from_end,
            reply: reply_tx,
        })
        .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn mark_read(&self) -> Result<u64, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::MarkRead { reply: reply_tx })
            .await;
        reply_rx.await.map_err(|error| error.to_string())
    }

    pub async fn load_transcript_and_sync(
        &self,
        path: String,
        session_id: String,
    ) -> Result<Option<SessionState>, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send(SessionCommand::LoadTranscriptAndSync {
            path,
            session_id,
            reply: reply_tx,
        })
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
        crate::runtime::session_command_handler::handle_session_command(
            cmd,
            &mut handle,
            &persist_tx,
        )
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

        actor_handle
            .send(SessionCommand::SetCustomName {
                name: Some("Test Session".to_string()),
            })
            .await;

        let (tx, rx) = tokio::sync::oneshot::channel();
        actor_handle
            .send(SessionCommand::GetCustomName { reply: tx })
            .await;
        let name = rx.await.unwrap();
        assert_eq!(name.as_deref(), Some("Test Session"));
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
            crate::runtime::session_commands::SubscribeResult::Snapshot { state, .. } => {
                assert_eq!(state.as_ref().id, "test-session");
            }
            crate::runtime::session_commands::SubscribeResult::Replay { .. } => {
                panic!("expected snapshot, got replay")
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

    #[tokio::test]
    async fn actor_throttles_streaming_row_update_broadcasts_but_emits_final_row() {
        let (persist_tx, _persist_rx) = mpsc::channel(64);
        let actor_handle = SessionActorHandle::spawn(test_handle(), persist_tx);

        let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
        actor_handle
            .send(SessionCommand::Subscribe {
                since_revision: None,
                reply: reply_tx,
            })
            .await;

        let mut rx = match reply_rx.await.unwrap() {
            crate::runtime::session_commands::SubscribeResult::Snapshot { rx, .. } => rx,
            crate::runtime::session_commands::SubscribeResult::Replay { .. } => {
                panic!("expected snapshot, got replay")
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
            row: ConversationRow::Assistant(MessageRowContent {
                id: row_id.clone(),
                content: content.to_string(),
                turn_id: Some("turn-1".to_string()),
                timestamp: Some("2026-03-13T12:00:00Z".to_string()),
                is_streaming,
                images: vec![],
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
            if let orbitdock_protocol::ServerMessage::ConversationRowsChanged { upserted, .. } =
                message
            {
                for entry in upserted {
                    if entry.id() == row_id {
                        if let ConversationRowSummary::Assistant(message) = entry.row {
                            emitted_contents.push((message.content, message.is_streaming));
                        }
                    }
                }
            }
        }

        assert_eq!(
            emitted_contents,
            vec![("a".to_string(), true), ("abcd".to_string(), false)]
        );
    }
}
