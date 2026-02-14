//! Application state

use std::collections::HashMap;

use orbitdock_protocol::SessionSummary;
use tokio::sync::{broadcast, mpsc};

use crate::codex_session::CodexAction;
use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;

/// Shared application state
pub struct AppState {
    /// Active sessions stored as actor handles
    sessions: HashMap<String, SessionActorHandle>,

    /// Action channels for Codex sessions
    codex_actions: HashMap<String, mpsc::Sender<CodexAction>>,
    /// Map codex-core thread_id -> session_id for direct sessions
    codex_threads: HashMap<String, String>,

    /// Broadcast channel for session list updates
    list_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,

    /// Persistence channel
    persist_tx: mpsc::Sender<PersistCommand>,
}

impl AppState {
    pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
        let (list_tx, _) = broadcast::channel(64);
        Self {
            sessions: HashMap::new(),
            codex_actions: HashMap::new(),
            codex_threads: HashMap::new(),
            list_tx,
            persist_tx,
        }
    }

    /// Get persistence sender
    pub fn persist(&self) -> &mpsc::Sender<PersistCommand> {
        &self.persist_tx
    }

    /// Store a Codex action sender
    pub fn set_codex_action_tx(&mut self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
        self.codex_actions.insert(session_id.to_string(), tx);
    }

    /// Get a Codex action sender
    pub fn get_codex_action_tx(&self, session_id: &str) -> Option<&mpsc::Sender<CodexAction>> {
        self.codex_actions.get(session_id)
    }

    /// Get all session summaries (lock-free via snapshots)
    pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
        self.sessions
            .values()
            .map(|actor| {
                let snap = actor.snapshot();
                SessionSummary {
                    id: snap.id.clone(),
                    provider: snap.provider,
                    project_path: snap.project_path.clone(),
                    transcript_path: snap.transcript_path.clone(),
                    project_name: snap.project_name.clone(),
                    model: snap.model.clone(),
                    custom_name: snap.custom_name.clone(),
                    status: snap.status,
                    work_status: snap.work_status,
                    has_pending_approval: false,
                    codex_integration_mode: snap.codex_integration_mode,
                    approval_policy: snap.approval_policy.clone(),
                    sandbox_mode: snap.sandbox_mode.clone(),
                    started_at: snap.started_at.clone(),
                    last_activity_at: snap.last_activity_at.clone(),
                }
            })
            .collect()
    }

    /// Get a session actor handle (cheap Clone)
    pub fn get_session(&self, id: &str) -> Option<SessionActorHandle> {
        self.sessions.get(id).cloned()
    }

    /// Add a session by spawning an actor
    pub fn add_session(&mut self, handle: SessionHandle) -> SessionActorHandle {
        let id = handle.id().to_string();
        let actor = SessionActorHandle::spawn(handle, self.persist_tx.clone());
        self.sessions.insert(id, actor.clone());
        actor
    }

    /// Add a pre-spawned actor handle (e.g. from CodexSession event loop)
    pub fn add_session_actor(&mut self, actor: SessionActorHandle) {
        self.sessions.insert(actor.id.clone(), actor);
    }

    /// Remove a session
    pub fn remove_session(&mut self, id: &str) -> Option<SessionActorHandle> {
        self.codex_actions.remove(id);
        self.codex_threads.retain(|_, session_id| session_id != id);
        self.sessions.remove(id)
    }

    /// Register codex-core thread ID for a direct session
    pub fn register_codex_thread(&mut self, session_id: &str, thread_id: &str) {
        self.codex_threads
            .insert(thread_id.to_string(), session_id.to_string());
    }

    /// Check whether thread ID is managed by a direct server session
    pub fn is_managed_codex_thread(&self, thread_id: &str) -> bool {
        self.codex_threads.contains_key(thread_id)
    }

    /// Subscribe to list updates
    pub fn subscribe_list(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
        self.list_tx.subscribe()
    }

    /// Broadcast a message to all list subscribers
    pub fn broadcast_to_list(&self, msg: orbitdock_protocol::ServerMessage) {
        let _ = self.list_tx.send(msg);
    }
}

// Note: No Default impl - requires persist_tx
