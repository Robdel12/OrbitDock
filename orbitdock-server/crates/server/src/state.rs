//! Application state

use std::collections::HashMap;

use orbitdock_protocol::SessionSummary;
use tokio::sync::mpsc;

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;

/// Shared application state
pub struct AppState {
    /// Active sessions
    sessions: HashMap<String, SessionHandle>,

    /// Subscribers to the session list
    list_subscribers: Vec<mpsc::Sender<orbitdock_protocol::ServerMessage>>,

    /// Persistence channel
    persist_tx: mpsc::Sender<PersistCommand>,
}

impl AppState {
    pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
        Self {
            sessions: HashMap::new(),
            list_subscribers: Vec::new(),
            persist_tx,
        }
    }

    /// Get persistence sender
    pub fn persist(&self) -> &mpsc::Sender<PersistCommand> {
        &self.persist_tx
    }

    /// Get all session summaries
    pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
        self.sessions
            .values()
            .map(|h| h.summary())
            .collect()
    }

    /// Get a session handle
    pub fn get_session(&self, id: &str) -> Option<&SessionHandle> {
        self.sessions.get(id)
    }

    /// Get a mutable session handle
    pub fn get_session_mut(&mut self, id: &str) -> Option<&mut SessionHandle> {
        self.sessions.get_mut(id)
    }

    /// Add a session
    pub fn add_session(&mut self, handle: SessionHandle) {
        let id = handle.id().to_string();
        self.sessions.insert(id, handle);
    }

    /// Remove a session
    pub fn remove_session(&mut self, id: &str) -> Option<SessionHandle> {
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
