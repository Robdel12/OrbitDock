//! Commands sent to a session actor from websocket/rollout_watcher callers.

use orbitdock_protocol::{
  conversation_contracts::ConversationRowEntry, ApprovalRequest, ApprovalType, ServerMessage,
  SessionState, SessionSummary, StateChanges, WorkStatus,
};
use tokio::sync::{broadcast, oneshot};

use crate::domain::sessions::conversation::ConversationPage;
use crate::infrastructure::persistence::PersistCommand;

/// A command that can be sent to a session actor.
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
  /// Returns replay events when possible, otherwise a resync-required hint
  /// with the live receiver attached.
  Subscribe {
    since_revision: Option<u64>,
    reply: oneshot::Sender<SubscribeResult>,
  },

  // -- Connector event processing --
  /// Process a connector event through the transition function
  ProcessEvent {
    event: crate::domain::sessions::transition::Input,
  },

  // -- Simple mutations (test-only) --
  #[cfg(test)]
  SetWorkStatus {
    status: WorkStatus,
  },

  // -- Compound operations --
  /// Apply a StateChanges delta, optionally persist, and broadcast SessionDelta.
  ApplyDelta {
    changes: Box<StateChanges>,
    persist_op: Option<PersistCommand>,
  },

  /// Apply a StateChanges delta, optionally persist, broadcast, and notify the
  /// caller once processing is complete.
  ApplyDeltaAndWait {
    changes: Box<StateChanges>,
    persist_op: Option<PersistCommand>,
    reply: oneshot::Sender<()>,
  },

  /// Mark session ended locally: status=Ended, work_status=Ended, broadcast delta.
  EndLocally,

  /// Set custom name, optionally persist, broadcast delta, and return summary.
  SetCustomNameAndNotify {
    name: Option<String>,
    persist_op: Option<PersistCommand>,
    reply: oneshot::Sender<SessionSummary>,
  },

  // -- Row operations --
  ReplaceRows {
    rows: Vec<ConversationRowEntry>,
  },
  /// Add a row and broadcast ConversationRowsChanged
  AddRowAndBroadcast {
    entry: ConversationRowEntry,
  },
  /// Add a row, persist it, broadcast it, and return the DB-authoritative row.
  AddRowAndBroadcastAndReply {
    entry: ConversationRowEntry,
    reply: oneshot::Sender<ConversationRowEntry>,
  },
  /// Update a steer row's delivery status after the provider resolves it.
  UpdateSteerOutcome {
    message_id: String,
    outcome: orbitdock_protocol::SteerOutcome,
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
  // -- Broadcast --
  /// Broadcast an arbitrary ServerMessage to session subscribers
  Broadcast {
    msg: ServerMessage,
  },

  // -- Queries that read fields --
  GetLastTool {
    reply: oneshot::Sender<Option<String>>,
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
  pub approval_version: u64,
}

/// Result of a Subscribe command
pub enum SubscribeResult {
  /// Replay events (when revision is close enough)
  Replay {
    events: Vec<String>,
    rx: broadcast::Receiver<ServerMessage>,
  },
  /// Replay is unavailable; caller should refetch the matching HTTP surface.
  ResyncRequired {
    rx: broadcast::Receiver<ServerMessage>,
  },
}
