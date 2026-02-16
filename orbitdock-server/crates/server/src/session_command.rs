//! Commands sent to a session actor from websocket/rollout_watcher callers.

use orbitdock_protocol::{
    ApprovalType, ClaudeIntegrationMode, CodexIntegrationMode, Message, ServerMessage,
    SessionState, SessionStatus, SessionSummary, StateChanges, WorkStatus,
};
use tokio::sync::{broadcast, oneshot};

/// A persistence operation that the actor executes on behalf of the caller.
/// The actor already holds `persist_tx`, so callers don't need to pass it.
pub enum PersistOp {
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
    },
    SetCustomName {
        session_id: String,
        name: Option<String>,
    },
    SetSessionConfig {
        session_id: String,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },
}

/// A command that can be sent to a session actor.
#[allow(dead_code)]
pub enum SessionCommand {
    // -- Queries (use oneshot reply channels) --
    /// Get the full session state
    GetState {
        reply: oneshot::Sender<SessionState>,
    },

    /// Get a session summary
    GetSummary {
        reply: oneshot::Sender<SessionSummary>,
    },

    /// Subscribe to session updates.
    /// Returns (Option<SessionState>, broadcast::Receiver, Vec<String> for replay).
    /// If `since_revision` is provided and replay is possible, state is None and
    /// replay events are returned. Otherwise state is a full snapshot.
    Subscribe {
        since_revision: Option<u64>,
        reply: oneshot::Sender<SubscribeResult>,
    },

    // -- Connector event processing --
    /// Process a connector event through the transition function
    ProcessEvent {
        event: crate::transition::Input,
    },

    // -- Simple mutations (fire-and-forget) --
    SetCustomName {
        name: Option<String>,
    },
    SetWorkStatus {
        status: WorkStatus,
    },
    SetModel {
        model: Option<String>,
    },
    SetConfig {
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },
    SetTranscriptPath {
        path: Option<String>,
    },
    SetProjectName {
        name: Option<String>,
    },
    SetStatus {
        status: SessionStatus,
    },
    SetStartedAt {
        ts: Option<String>,
    },
    SetLastActivityAt {
        ts: Option<String>,
    },
    SetCodexIntegrationMode {
        mode: Option<CodexIntegrationMode>,
    },
    SetClaudeIntegrationMode {
        mode: Option<ClaudeIntegrationMode>,
    },
    SetForkedFrom {
        source_id: String,
    },
    SetLastTool {
        tool: Option<String>,
    },

    // -- Compound operations --
    /// Apply a StateChanges delta, optionally persist, and broadcast SessionDelta.
    ApplyDelta {
        changes: StateChanges,
        persist_op: Option<PersistOp>,
    },

    /// Mark session ended locally: status=Ended, work_status=Ended, broadcast delta.
    EndLocally,

    /// Set custom name, optionally persist, broadcast delta, and return summary.
    SetCustomNameAndNotify {
        name: Option<String>,
        persist_op: Option<PersistOp>,
        reply: oneshot::Sender<SessionSummary>,
    },

    // -- Message operations --
    AddMessage {
        message: Message,
    },
    ReplaceMessages {
        messages: Vec<Message>,
    },
    /// Add a message and broadcast MessageAppended
    AddMessageAndBroadcast {
        message: Message,
    },

    // -- Approval --
    /// Get and remove the approval type + amendment for a request
    TakePendingApproval {
        request_id: String,
        reply: oneshot::Sender<(Option<ApprovalType>, Option<Vec<String>>)>,
    },
    SetPendingApproval {
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    },

    // -- Broadcast --
    /// Broadcast an arbitrary ServerMessage to session subscribers
    Broadcast {
        msg: ServerMessage,
    },

    // -- Complex operations --
    /// Load transcript from path and sync messages into session
    LoadTranscriptAndSync {
        path: String,
        session_id: String,
        reply: oneshot::Sender<Option<SessionState>>,
    },

    // -- Queries that read fields --
    GetWorkStatus {
        reply: oneshot::Sender<WorkStatus>,
    },
    GetLastTool {
        reply: oneshot::Sender<Option<String>>,
    },
    GetCustomName {
        reply: oneshot::Sender<Option<String>>,
    },
    GetProvider {
        reply: oneshot::Sender<orbitdock_protocol::Provider>,
    },
    GetProjectPath {
        reply: oneshot::Sender<String>,
    },
    GetMessageCount {
        reply: oneshot::Sender<usize>,
    },
}

/// Result of a Subscribe command
pub enum SubscribeResult {
    /// Full snapshot (when replay not possible)
    Snapshot {
        state: Box<SessionState>,
        rx: broadcast::Receiver<ServerMessage>,
    },
    /// Replay events (when revision is close enough)
    Replay {
        events: Vec<String>,
        rx: broadcast::Receiver<ServerMessage>,
    },
}
