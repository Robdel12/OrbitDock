//! Session management

use std::collections::HashMap;

use orbitdock_protocol::{
    ApprovalType, CodexIntegrationMode, Message, Provider, SessionState, SessionStatus,
    SessionSummary, TokenUsage, WorkStatus,
};
use tokio::sync::mpsc;

/// Handle to a running session
pub struct SessionHandle {
    id: String,
    provider: Provider,
    project_path: String,
    transcript_path: Option<String>,
    project_name: Option<String>,
    model: Option<String>,
    custom_name: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    codex_integration_mode: Option<CodexIntegrationMode>,
    status: SessionStatus,
    work_status: WorkStatus,
    last_tool: Option<String>,
    messages: Vec<Message>,
    token_usage: TokenUsage,
    current_diff: Option<String>,
    current_plan: Option<String>,
    started_at: Option<String>,
    last_activity_at: Option<String>,
    subscribers: Vec<mpsc::Sender<orbitdock_protocol::ServerMessage>>,
    /// Track approval type by request_id so we can dispatch correctly
    pending_approval_types: HashMap<String, ApprovalType>,
    /// Store proposed amendment by request_id for "always allow" decisions
    pending_amendments: HashMap<String, Vec<String>>,
}

impl SessionHandle {
    /// Create a new session handle
    pub fn new(id: String, provider: Provider, project_path: String) -> Self {
        let now = chrono_now();
        Self {
            id,
            provider,
            project_path,
            transcript_path: None,
            project_name: None,
            model: None,
            custom_name: None,
            approval_policy: None,
            sandbox_mode: None,
            codex_integration_mode: None,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            last_tool: None,
            messages: Vec::new(),
            token_usage: TokenUsage::default(),
            current_diff: None,
            current_plan: None,
            started_at: Some(now.clone()),
            last_activity_at: Some(now),
            subscribers: Vec::new(),
            pending_approval_types: HashMap::new(),
            pending_amendments: HashMap::new(),
        }
    }

    /// Restore a session from the database (for server restart recovery)
    #[allow(clippy::too_many_arguments)]
    pub fn restore(
        id: String,
        provider: Provider,
        project_path: String,
        transcript_path: Option<String>,
        project_name: Option<String>,
        model: Option<String>,
        custom_name: Option<String>,
        status: SessionStatus,
        work_status: WorkStatus,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        token_usage: TokenUsage,
        started_at: Option<String>,
        last_activity_at: Option<String>,
        messages: Vec<Message>,
    ) -> Self {
        Self {
            id,
            provider,
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            approval_policy,
            sandbox_mode,
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            status,
            work_status,
            last_tool: None,
            messages,
            token_usage,
            current_diff: None,
            current_plan: None,
            started_at,
            last_activity_at,
            subscribers: Vec::new(),
            pending_approval_types: HashMap::new(),
            pending_amendments: HashMap::new(),
        }
    }

    /// Get session ID
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Get session project path
    pub fn project_path(&self) -> &str {
        &self.project_path
    }

    /// Get provider
    pub fn provider(&self) -> Provider {
        self.provider
    }

    /// Get a summary of this session
    pub fn summary(&self) -> SessionSummary {
        SessionSummary {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            transcript_path: self.transcript_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            custom_name: self.custom_name.clone(),
            status: self.status,
            work_status: self.work_status,
            has_pending_approval: false, // TODO
            codex_integration_mode: self.codex_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
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
            transcript_path: self.transcript_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            custom_name: self.custom_name.clone(),
            status: self.status,
            work_status: self.work_status,
            messages: self.messages.clone(),
            pending_approval: None, // TODO
            token_usage: self.token_usage.clone(),
            current_diff: self.current_diff.clone(),
            current_plan: self.current_plan.clone(),
            codex_integration_mode: self.codex_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
        }
    }

    /// Subscribe to session updates
    pub fn subscribe(&mut self, tx: mpsc::Sender<orbitdock_protocol::ServerMessage>) {
        self.subscribers.push(tx);
    }

    /// Clean up any closed subscriber channels
    pub fn unsubscribe_by_closed(&mut self) {
        self.subscribers.retain(|tx| !tx.is_closed());
    }

    /// Set the custom name for this session
    pub fn set_custom_name(&mut self, name: Option<String>) {
        self.custom_name = name;
        self.last_activity_at = Some(chrono_now());
    }

    /// Get custom name
    pub fn custom_name(&self) -> Option<&str> {
        self.custom_name.as_deref()
    }

    /// Set codex integration mode
    pub fn set_codex_integration_mode(&mut self, mode: Option<CodexIntegrationMode>) {
        self.codex_integration_mode = mode;
    }

    /// Set project name
    pub fn set_project_name(&mut self, project_name: Option<String>) {
        self.project_name = project_name;
    }

    /// Set transcript path
    pub fn set_transcript_path(&mut self, transcript_path: Option<String>) {
        self.transcript_path = transcript_path;
    }

    /// Set model
    pub fn set_model(&mut self, model: Option<String>) {
        self.model = model;
    }

    /// Set autonomy configuration
    pub fn set_config(&mut self, approval_policy: Option<String>, sandbox_mode: Option<String>) {
        self.approval_policy = approval_policy;
        self.sandbox_mode = sandbox_mode;
    }

    /// Set status
    pub fn set_status(&mut self, status: SessionStatus) {
        self.status = status;
        self.last_activity_at = Some(chrono_now());
    }

    /// Set started_at timestamp
    pub fn set_started_at(&mut self, started_at: Option<String>) {
        self.started_at = started_at;
    }

    /// Set last_activity_at timestamp
    pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
        self.last_activity_at = last_activity_at;
    }

    /// Set work status
    pub fn set_work_status(&mut self, status: WorkStatus) {
        self.work_status = status;
        self.last_activity_at = Some(chrono_now());
    }

    /// Get work status
    pub fn work_status(&self) -> WorkStatus {
        self.work_status
    }

    /// Set last tool name
    pub fn set_last_tool(&mut self, tool: Option<String>) {
        self.last_tool = tool;
        self.last_activity_at = Some(chrono_now());
    }

    /// Get last tool name
    pub fn last_tool(&self) -> Option<&str> {
        self.last_tool.as_deref()
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

    /// Register a pending approval with optional proposed amendment
    pub fn set_pending_approval(
        &mut self,
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    ) {
        self.pending_approval_types
            .insert(request_id.clone(), approval_type);
        if let Some(amendment) = proposed_amendment {
            self.pending_amendments.insert(request_id, amendment);
        }
    }

    /// Get and remove the approval type for a request
    pub fn take_pending_approval(&mut self, request_id: &str) -> Option<ApprovalType> {
        self.pending_approval_types.remove(request_id)
    }

    /// Get and remove the proposed amendment for a request
    pub fn take_pending_amendment(&mut self, request_id: &str) -> Option<Vec<String>> {
        self.pending_amendments.remove(request_id)
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
