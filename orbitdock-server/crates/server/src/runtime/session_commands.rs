//! Commands sent to a session actor from websocket/rollout_watcher callers.

use orbitdock_protocol::{
    conversation_contracts::ConversationRowEntry, ApprovalRequest, ApprovalType,
    ClaudeIntegrationMode, CodexIntegrationMode, ServerMessage, SessionState, SessionStatus,
    SessionSummary, StateChanges, SubagentInfo, WorkStatus,
};
use tokio::sync::{broadcast, oneshot};

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};

/// A persistence operation that the actor executes on behalf of the caller.
/// The actor already holds `persist_tx`, so callers don't need to pass it.
#[allow(clippy::large_enum_variant)]
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
        approval_policy: Option<Option<String>>,
        sandbox_mode: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        collaboration_mode: Option<Option<String>>,
        multi_agent: Option<Option<bool>>,
        personality: Option<Option<String>>,
        service_tier: Option<Option<String>>,
        developer_instructions: Option<Option<String>>,
        model: Option<Option<String>>,
        effort: Option<Option<String>>,
        codex_config_mode: Option<orbitdock_protocol::CodexConfigMode>,
        codex_config_profile: Option<String>,
        codex_model_provider: Option<String>,
        codex_config_source: Option<orbitdock_protocol::CodexConfigSource>,
        codex_config_overrides_json: Option<String>,
    },
}

/// A command that can be sent to a session actor.
#[allow(dead_code)]
#[allow(clippy::large_enum_variant)]
pub enum SessionCommand {
    // -- Queries (use oneshot reply channels) --
    /// Get the retained in-memory session snapshot.
    GetRetainedState {
        reply: oneshot::Sender<SessionState>,
    },

    /// Get a session summary
    GetSummary {
        reply: oneshot::Sender<SessionSummary>,
    },

    /// Subscribe to session updates.
    /// Returns (Option<SessionState>, broadcast::Receiver, Vec<String> for replay).
    /// If `since_revision` is provided and replay is possible, state is None and
    /// replay events are returned. Otherwise state is the retained session snapshot.
    Subscribe {
        since_revision: Option<u64>,
        reply: oneshot::Sender<SubscribeResult>,
    },

    // -- Connector event processing --
    /// Process a connector event through the transition function
    ProcessEvent {
        event: crate::domain::sessions::transition::Input,
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
    SetSubagents {
        subagents: Vec<SubagentInfo>,
    },
    SetPendingAttention {
        pending_tool_name: Option<String>,
        pending_tool_input: Option<String>,
        pending_question: Option<String>,
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

    // -- Row operations --
    AddRow {
        entry: ConversationRowEntry,
    },
    ReplaceRows {
        rows: Vec<ConversationRowEntry>,
    },
    /// Add a row and broadcast ConversationRowsChanged
    AddRowAndBroadcast {
        entry: ConversationRowEntry,
    },
    /// Upsert an existing row (replace by ID) and broadcast.
    /// Does NOT increment message count when replacing.
    UpsertRowAndBroadcast {
        entry: ConversationRowEntry,
    },
    /// Record a question answer on the most recent unanswered question tool row.
    /// Finds the newest AskUserQuestion tool row with no result and sets its
    /// output to the provided answer text.
    RecordQuestionAnswer {
        answer_text: String,
    },

    // -- Approval --
    /// Resolve a pending approval request and promote the next one if present.
    ResolvePendingApproval {
        request_id: String,
        fallback_work_status: WorkStatus,
        reply: oneshot::Sender<PendingApprovalResolution>,
    },
    SetPendingApproval {
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
        tool_name: Option<String>,
        tool_input: Option<String>,
        question: Option<String>,
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
    GetConversationBootstrap {
        limit: usize,
        reply: oneshot::Sender<ConversationBootstrap>,
    },
    GetConversationPage {
        before_sequence: Option<u64>,
        limit: usize,
        reply: oneshot::Sender<ConversationPage>,
    },
    /// Resolve the Nth user message from the end of the conversation.
    /// Returns the message ID if found.
    ResolveUserMessageId {
        num_turns_from_end: u32,
        reply: oneshot::Sender<Option<String>>,
    },

    /// Extract the owned SessionHandle from a passive actor, stopping its loop.
    /// Used for upgrading a passive session to one with a live connector.
    TakeHandle {
        reply: oneshot::Sender<crate::domain::sessions::session::SessionHandle>,
    },

    /// Mark the session as read and broadcast the updated unread count.
    MarkRead {
        reply: oneshot::Sender<u64>,
    },
}

pub struct PendingApprovalResolution {
    pub approval_type: Option<ApprovalType>,
    pub proposed_amendment: Option<Vec<String>>,
    pub next_pending_approval: Option<ApprovalRequest>,
    pub work_status: WorkStatus,
    pub approval_version: u64,
}

/// Result of a Subscribe command
pub enum SubscribeResult {
    /// Retained session snapshot (when replay not possible)
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
