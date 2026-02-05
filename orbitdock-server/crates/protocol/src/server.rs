//! Server → Client messages

use serde::{Deserialize, Serialize};

use crate::types::*;

/// Messages sent from server to client
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    // Full state sync
    SessionsList {
        sessions: Vec<SessionSummary>,
    },
    SessionSnapshot {
        session: SessionState,
    },

    // Incremental updates
    SessionDelta {
        session_id: String,
        changes: StateChanges,
    },
    MessageAppended {
        session_id: String,
        message: Message,
    },
    MessageUpdated {
        session_id: String,
        message_id: String,
        changes: MessageChanges,
    },
    ApprovalRequested {
        session_id: String,
        request: ApprovalRequest,
    },
    TokensUpdated {
        session_id: String,
        usage: TokenUsage,
    },

    // Lifecycle
    SessionCreated {
        session: SessionSummary,
    },
    SessionEnded {
        session_id: String,
        reason: String,
    },

    // Errors
    Error {
        code: String,
        message: String,
        session_id: Option<String>,
    },
}
