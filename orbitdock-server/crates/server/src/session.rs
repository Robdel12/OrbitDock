//! Session management

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use arc_swap::ArcSwap;
use orbitdock_protocol::{
    ApprovalType, CodexIntegrationMode, Message, Provider, SessionState, SessionStatus,
    SessionSummary, StateChanges, TokenUsage, TurnDiff, WorkStatus,
};
use tokio::sync::broadcast;

use crate::transition::{TransitionState, WorkPhase};

/// Lightweight, lock-free snapshot of session metadata.
/// Used by `ArcSwap` so list subscribers and snapshot readers never block
/// the actor.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct SessionSnapshot {
    pub id: String,
    pub provider: Provider,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub project_path: String,
    pub project_name: Option<String>,
    pub transcript_path: Option<String>,
    pub custom_name: Option<String>,
    pub model: Option<String>,
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub message_count: usize,
    pub token_usage: TokenUsage,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub revision: u64,
    pub git_branch: Option<String>,
    pub git_sha: Option<String>,
    pub current_cwd: Option<String>,
}

const EVENT_LOG_CAPACITY: usize = 1000;
const BROADCAST_CAPACITY: usize = 512;

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
    current_turn_id: Option<String>,
    turn_count: u64,
    turn_diffs: Vec<TurnDiff>,
    started_at: Option<String>,
    last_activity_at: Option<String>,
    forked_from_session_id: Option<String>,
    git_branch: Option<String>,
    git_sha: Option<String>,
    current_cwd: Option<String>,
    broadcast_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,
    /// Track approval type by request_id so we can dispatch correctly
    pending_approval_types: HashMap<String, ApprovalType>,
    /// Store proposed amendment by request_id for "always allow" decisions
    pending_amendments: HashMap<String, Vec<String>>,
    /// Monotonic revision counter, incremented on every broadcast
    revision: u64,
    /// Ring buffer of (revision, pre-serialized JSON with revision injected)
    event_log: VecDeque<(u64, String)>,
    /// Lock-free snapshot for read-only access from outside the actor
    snapshot_handle: Arc<ArcSwap<SessionSnapshot>>,
}

impl SessionHandle {
    /// Create a new session handle
    pub fn new(id: String, provider: Provider, project_path: String) -> Self {
        let now = chrono_now();
        let (broadcast_tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        let snapshot = SessionSnapshot {
            id: id.clone(),
            provider,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            project_path: project_path.clone(),
            project_name: None,
            transcript_path: None,
            custom_name: None,
            model: None,
            codex_integration_mode: None,
            approval_policy: None,
            sandbox_mode: None,
            message_count: 0,
            token_usage: TokenUsage::default(),
            started_at: Some(now.clone()),
            last_activity_at: Some(now.clone()),
            revision: 0,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
        };
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
            current_turn_id: None,
            turn_count: 0,
            turn_diffs: Vec::new(),
            started_at: Some(now.clone()),
            last_activity_at: Some(now),
            forked_from_session_id: None,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            broadcast_tx,
            pending_approval_types: HashMap::new(),
            pending_amendments: HashMap::new(),
            revision: 0,
            event_log: VecDeque::new(),
            snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
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
        current_diff: Option<String>,
        current_plan: Option<String>,
        turn_diffs: Vec<TurnDiff>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        current_cwd: Option<String>,
    ) -> Self {
        let (broadcast_tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        let snapshot = SessionSnapshot {
            id: id.clone(),
            provider,
            status,
            work_status,
            project_path: project_path.clone(),
            project_name: project_name.clone(),
            transcript_path: transcript_path.clone(),
            custom_name: custom_name.clone(),
            model: model.clone(),
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            approval_policy: approval_policy.clone(),
            sandbox_mode: sandbox_mode.clone(),
            message_count: messages.len(),
            token_usage: token_usage.clone(),
            started_at: started_at.clone(),
            last_activity_at: last_activity_at.clone(),
            revision: 0,
            git_branch: git_branch.clone(),
            git_sha: git_sha.clone(),
            current_cwd: current_cwd.clone(),
        };
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
            current_diff,
            current_plan,
            current_turn_id: None,
            turn_count: turn_diffs.len() as u64,
            turn_diffs,
            started_at,
            last_activity_at,
            forked_from_session_id: None,
            git_branch,
            git_sha,
            current_cwd,
            broadcast_tx,
            pending_approval_types: HashMap::new(),
            pending_amendments: HashMap::new(),
            revision: 0,
            event_log: VecDeque::new(),
            snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
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
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
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
            forked_from_session_id: self.forked_from_session_id.clone(),
            revision: Some(self.revision),
            current_turn_id: self.current_turn_id.clone(),
            turn_count: self.turn_count,
            turn_diffs: self.turn_diffs.clone(),
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
        }
    }

    /// Subscribe to session updates
    pub fn subscribe(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
        self.broadcast_tx.subscribe()
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

    #[allow(dead_code)]
    pub fn transcript_path(&self) -> Option<&str> {
        self.transcript_path.as_deref()
    }

    pub fn message_count(&self) -> usize {
        self.messages.len()
    }

    /// Check if a user message with this content already exists (dedup for connector echo)
    #[allow(dead_code)]
    pub fn has_user_message_with_content(&self, content: &str) -> bool {
        use orbitdock_protocol::MessageType;
        self.messages
            .iter()
            .rev()
            .take(5)
            .any(|m| m.message_type == MessageType::User && m.content == content)
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

    /// Set fork origin
    pub fn set_forked_from(&mut self, source_session_id: String) {
        self.forked_from_session_id = Some(source_session_id);
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
    #[allow(dead_code)]
    pub fn update_tokens(&mut self, usage: TokenUsage) {
        self.token_usage = usage;
    }

    /// Add a message
    pub fn add_message(&mut self, message: Message) {
        self.messages.push(message);
        self.last_activity_at = Some(chrono_now());
    }

    /// Replace all messages (used for snapshot hydration from transcript fallback)
    pub fn replace_messages(&mut self, messages: Vec<Message>) {
        self.messages = messages;
    }

    /// Update aggregated diff
    #[allow(dead_code)]
    pub fn update_diff(&mut self, diff: String) {
        self.current_diff = Some(diff);
    }

    /// Update plan
    #[allow(dead_code)]
    pub fn update_plan(&mut self, plan: String) {
        self.current_plan = Some(plan);
    }

    /// Register a pending approval with optional proposed amendment
    #[allow(dead_code)]
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

    /// Apply a `StateChanges` delta to the handle fields.
    /// Each `Some` field overwrites the corresponding handle field.
    pub fn apply_changes(&mut self, changes: &StateChanges) {
        if let Some(status) = changes.status {
            self.status = status;
        }
        if let Some(work_status) = changes.work_status {
            self.work_status = work_status;
        }
        if let Some(ref custom_name) = changes.custom_name {
            self.custom_name = custom_name.clone();
        }
        if let Some(ref approval_policy) = changes.approval_policy {
            self.approval_policy = approval_policy.clone();
        }
        if let Some(ref sandbox_mode) = changes.sandbox_mode {
            self.sandbox_mode = sandbox_mode.clone();
        }
        if let Some(ref codex_integration_mode) = changes.codex_integration_mode {
            self.codex_integration_mode = *codex_integration_mode;
        }
        if let Some(ref last_activity_at) = changes.last_activity_at {
            self.last_activity_at = Some(last_activity_at.clone());
        }
        if let Some(ref token_usage) = changes.token_usage {
            self.token_usage = token_usage.clone();
        }
        if let Some(ref current_diff) = changes.current_diff {
            self.current_diff = current_diff.clone();
        }
        if let Some(ref current_plan) = changes.current_plan {
            self.current_plan = current_plan.clone();
        }
        if let Some(ref current_turn_id) = changes.current_turn_id {
            self.current_turn_id = current_turn_id.clone();
        }
        if let Some(turn_count) = changes.turn_count {
            self.turn_count = turn_count;
        }
        if let Some(ref git_branch) = changes.git_branch {
            self.git_branch = git_branch.clone();
        }
        if let Some(ref git_sha) = changes.git_sha {
            self.git_sha = git_sha.clone();
        }
        if let Some(ref current_cwd) = changes.current_cwd {
            self.current_cwd = current_cwd.clone();
        }
    }

    /// Create a snapshot of current session metadata
    pub fn to_snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            id: self.id.clone(),
            provider: self.provider,
            status: self.status,
            work_status: self.work_status,
            project_path: self.project_path.clone(),
            project_name: self.project_name.clone(),
            transcript_path: self.transcript_path.clone(),
            custom_name: self.custom_name.clone(),
            model: self.model.clone(),
            codex_integration_mode: self.codex_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
            message_count: self.messages.len(),
            token_usage: self.token_usage.clone(),
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
            revision: self.revision,
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
        }
    }

    /// Update the ArcSwap snapshot (call after mutations)
    pub fn refresh_snapshot(&self) {
        self.snapshot_handle.store(Arc::new(self.to_snapshot()));
    }

    /// Get the ArcSwap handle for lock-free reads
    pub fn snapshot_arc(&self) -> Arc<ArcSwap<SessionSnapshot>> {
        self.snapshot_handle.clone()
    }

    /// Broadcast a message to all subscribers
    pub fn broadcast(&mut self, msg: orbitdock_protocol::ServerMessage) {
        self.revision += 1;
        let rev = self.revision;

        // Pre-serialize with revision for event log
        if let Ok(json) = serialize_with_revision(&msg, rev) {
            self.event_log.push_back((rev, json));
            if self.event_log.len() > EVENT_LOG_CAPACITY {
                self.event_log.pop_front();
            }
        }

        // Non-blocking fan-out to all receivers
        let _ = self.broadcast_tx.send(msg);

        // Update lock-free snapshot
        self.refresh_snapshot();
    }

    /// Replay events since a given revision.
    /// Returns `None` if the gap is too large (caller should send full snapshot).
    pub fn replay_since(&self, since_revision: u64) -> Option<Vec<String>> {
        let oldest = self.event_log.front().map(|(rev, _)| *rev)?;
        if oldest > since_revision + 1 {
            return None; // Gap too large, need full snapshot
        }
        let events: Vec<String> = self
            .event_log
            .iter()
            .filter(|(rev, _)| *rev > since_revision)
            .map(|(_, json)| json.clone())
            .collect();
        Some(events)
    }

    // -- Transition bridge (temporary until Phase 4 actor model) ---------------

    /// Extract a pure data snapshot for the transition function
    pub fn extract_state(&self) -> TransitionState {
        let phase = match self.work_status {
            WorkStatus::Working => WorkPhase::Working,
            WorkStatus::Permission => WorkPhase::AwaitingApproval {
                request_id: String::new(),
                approval_type: ApprovalType::Exec,
                proposed_amendment: None,
            },
            WorkStatus::Question => WorkPhase::AwaitingApproval {
                request_id: String::new(),
                approval_type: ApprovalType::Question,
                proposed_amendment: None,
            },
            WorkStatus::Ended => WorkPhase::Ended {
                reason: String::new(),
            },
            _ => WorkPhase::Idle,
        };

        TransitionState {
            id: self.id.clone(),
            revision: self.revision,
            phase,
            messages: self.messages.clone(),
            token_usage: self.token_usage.clone(),
            current_diff: self.current_diff.clone(),
            current_plan: self.current_plan.clone(),
            custom_name: self.custom_name.clone(),
            project_path: self.project_path.clone(),
            last_activity_at: self.last_activity_at.clone(),
            current_turn_id: self.current_turn_id.clone(),
            turn_count: self.turn_count,
            turn_diffs: self.turn_diffs.clone(),
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
        }
    }

    /// Apply the transition result back to this handle
    pub fn apply_state(&mut self, state: TransitionState) {
        self.work_status = state.phase.to_work_status();
        self.messages = state.messages;
        self.token_usage = state.token_usage;
        self.current_diff = state.current_diff;
        self.current_plan = state.current_plan;
        self.custom_name = state.custom_name;
        self.last_activity_at = state.last_activity_at;
        self.current_turn_id = state.current_turn_id;
        self.turn_count = state.turn_count;
        self.turn_diffs = state.turn_diffs;
        self.git_branch = state.git_branch;
        self.git_sha = state.git_sha;
        self.current_cwd = state.current_cwd;

        // Sync pending approval tracking from phase
        if let WorkPhase::AwaitingApproval {
            request_id,
            approval_type,
            proposed_amendment,
        } = &state.phase
        {
            if !request_id.is_empty() {
                self.pending_approval_types
                    .insert(request_id.clone(), *approval_type);
                if let Some(amendment) = proposed_amendment {
                    self.pending_amendments
                        .insert(request_id.clone(), amendment.clone());
                }
            }
        }
    }
}

/// Serialize a ServerMessage with a revision field injected at the top level
fn serialize_with_revision(
    msg: &orbitdock_protocol::ServerMessage,
    revision: u64,
) -> Result<String, serde_json::Error> {
    let mut val = serde_json::to_value(msg)?;
    if let Some(obj) = val.as_object_mut() {
        obj.insert("revision".to_string(), serde_json::json!(revision));
    }
    serde_json::to_string(&val)
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
