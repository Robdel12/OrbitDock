//! Session actor — owns a SessionHandle and processes commands sequentially.
//!
//! Each session runs as an independent tokio task. External callers
//! communicate via `SessionActorHandle` which sends `SessionCommand`
//! messages over an mpsc channel. Lock-free reads go through `ArcSwap`.

use std::sync::Arc;

use arc_swap::ArcSwap;
use tokio::sync::mpsc;
use tracing::warn;

use crate::persistence::PersistCommand;
use crate::session::{SessionHandle, SessionSnapshot};
use crate::session_command::SessionCommand;

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
}

/// Simple actor loop for passive sessions (no CodexConnector).
/// Reuses the shared `handle_session_command` from codex_session.rs.
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
        crate::codex_session::handle_session_command(cmd, &mut handle, &persist_tx).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
            crate::session_command::SubscribeResult::Snapshot { state, .. } => {
                assert_eq!(state.as_ref().id, "test-session");
            }
            crate::session_command::SubscribeResult::Replay { .. } => {
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
                event: crate::transition::Input::TurnStarted,
            })
            .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let snap = actor_handle.snapshot();
        assert_eq!(snap.work_status, WorkStatus::Working);
    }
}
