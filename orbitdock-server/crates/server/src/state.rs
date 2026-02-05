//! Application state

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_protocol::SessionSummary;
use tokio::sync::{mpsc, Mutex};

use crate::codex_session::CodexAction;
use crate::persistence::PersistCommand;
use crate::session::SessionHandle;

/// Shared application state
pub struct AppState {
    /// Active sessions (wrapped in Arc<Mutex> for shared access)
    sessions: HashMap<String, Arc<Mutex<SessionHandle>>>,

    /// Action channels for Codex sessions
    codex_actions: HashMap<String, mpsc::Sender<CodexAction>>,

    /// Subscribers to the session list
    list_subscribers: Vec<mpsc::Sender<orbitdock_protocol::ServerMessage>>,

    /// Persistence channel
    persist_tx: mpsc::Sender<PersistCommand>,
}

impl AppState {
    pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
        Self {
            sessions: HashMap::new(),
            codex_actions: HashMap::new(),
            list_subscribers: Vec::new(),
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

    /// Get all session summaries
    pub async fn get_session_summaries(&self) -> Vec<SessionSummary> {
        let mut summaries = Vec::new();
        for session in self.sessions.values() {
            let session = session.lock().await;
            summaries.push(session.summary());
        }
        summaries
    }

    /// Get a session handle (Arc for shared access)
    pub fn get_session(&self, id: &str) -> Option<Arc<Mutex<SessionHandle>>> {
        self.sessions.get(id).cloned()
    }

    /// Add a session
    pub fn add_session(&mut self, handle: SessionHandle) -> Arc<Mutex<SessionHandle>> {
        let id = handle.id().to_string();
        let arc = Arc::new(Mutex::new(handle));
        self.sessions.insert(id, arc.clone());
        arc
    }

    /// Remove a session
    pub fn remove_session(&mut self, id: &str) -> Option<Arc<Mutex<SessionHandle>>> {
        self.codex_actions.remove(id);
        self.sessions.remove(id)
    }

    /// Subscribe to list updates
    pub fn subscribe_list(&mut self, tx: mpsc::Sender<orbitdock_protocol::ServerMessage>) {
        self.list_subscribers.push(tx);
    }

    /// Broadcast a message to all list subscribers
    pub async fn broadcast_to_list(&mut self, msg: orbitdock_protocol::ServerMessage) {
        // Remove closed channels
        self.list_subscribers.retain(|tx| !tx.is_closed());

        for tx in &self.list_subscribers {
            let _ = tx.send(msg.clone()).await;
        }
    }
}

// Note: No Default impl - requires persist_tx
