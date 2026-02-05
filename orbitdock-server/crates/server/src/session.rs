//! Session management

use orbitdock_protocol::{
    Message, Provider, SessionState, SessionStatus, SessionSummary, TokenUsage, WorkStatus,
};
use tokio::sync::mpsc;
// Note: debug, info will be used when connectors are wired up

/// Handle to a running session
pub struct SessionHandle {
    id: String,
    provider: Provider,
    project_path: String,
    project_name: Option<String>,
    model: Option<String>,
    status: SessionStatus,
    work_status: WorkStatus,
    messages: Vec<Message>,
    token_usage: TokenUsage,
    current_diff: Option<String>,
    current_plan: Option<String>,
    started_at: Option<String>,
    last_activity_at: Option<String>,
    subscribers: Vec<mpsc::Sender<orbitdock_protocol::ServerMessage>>,
}

impl SessionHandle {
    /// Create a new session handle
    pub fn new(id: String, provider: Provider, project_path: String) -> Self {
        let now = chrono_now();
        Self {
            id,
            provider,
            project_path,
            project_name: None,
            model: None,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            messages: Vec::new(),
            token_usage: TokenUsage::default(),
            current_diff: None,
            current_plan: None,
            started_at: Some(now.clone()),
            last_activity_at: Some(now),
            subscribers: Vec::new(),
        }
    }

    /// Get session ID
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Get a summary of this session
    pub fn summary(&self) -> SessionSummary {
        SessionSummary {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            status: self.status,
            work_status: self.work_status,
            has_pending_approval: false, // TODO
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
        }
    }

    /// Get the full session state
    pub fn state(&self) -> SessionState {
        SessionState {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            status: self.status,
            work_status: self.work_status,
            messages: self.messages.clone(),
            pending_approval: None, // TODO
            token_usage: self.token_usage.clone(),
            current_diff: self.current_diff.clone(),
            current_plan: self.current_plan.clone(),
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
        }
    }

    /// Subscribe to session updates
    pub fn subscribe(&mut self, tx: mpsc::Sender<orbitdock_protocol::ServerMessage>) {
        self.subscribers.push(tx);
    }

    /// Unsubscribe from session updates
    pub fn unsubscribe(&mut self, tx: &mpsc::Sender<orbitdock_protocol::ServerMessage>) {
        self.subscribers.retain(|s| !s.same_channel(tx));
    }

    /// Clean up any closed subscriber channels
    pub fn unsubscribe_by_closed(&mut self) {
        self.subscribers.retain(|tx| !tx.is_closed());
    }

    /// Set work status
    pub fn set_work_status(&mut self, status: WorkStatus) {
        self.work_status = status;
        self.last_activity_at = Some(chrono_now());
    }

    /// Update token usage
    pub fn update_tokens(&mut self, usage: TokenUsage) {
        self.token_usage = usage;
    }

    /// Add a message
    pub fn add_message(&mut self, message: Message) {
        self.messages.push(message);
        self.last_activity_at = Some(chrono_now());
    }

    /// Update aggregated diff
    pub fn update_diff(&mut self, diff: String) {
        self.current_diff = Some(diff);
    }

    /// Update plan
    pub fn update_plan(&mut self, plan: String) {
        self.current_plan = Some(plan);
    }

    /// Broadcast a message to all subscribers
    pub async fn broadcast(&mut self, msg: orbitdock_protocol::ServerMessage) {
        // Remove closed channels
        self.subscribers.retain(|tx| !tx.is_closed());

        for tx in &self.subscribers {
            let _ = tx.send(msg.clone()).await;
        }
    }
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    // Using a simple format for now
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}Z", duration.as_secs())
}
