//! Client → Server messages

use serde::{Deserialize, Serialize};

use crate::types::Provider;

/// Messages sent from client to server
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // Subscriptions
    SubscribeSession {
        session_id: String,
    },
    UnsubscribeSession {
        session_id: String,
    },
    SubscribeList,

    // Actions
    SendMessage {
        session_id: String,
        content: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        effort: Option<String>,
    },
    ApproveTool {
        session_id: String,
        request_id: String,
        decision: String,
    },
    AnswerQuestion {
        session_id: String,
        request_id: String,
        answer: String,
    },
    InterruptSession {
        session_id: String,
    },
    EndSession {
        session_id: String,
    },

    // Session config
    UpdateSessionConfig {
        session_id: String,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },

    // Session naming
    RenameSession {
        session_id: String,
        name: Option<String>,
    },

    // Session management
    CreateSession {
        provider: Provider,
        cwd: String,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },
    ResumeSession {
        session_id: String,
    },

    // Approval history
    ListApprovals {
        session_id: Option<String>,
        limit: Option<u32>,
    },
    DeleteApproval {
        approval_id: i64,
    },

    // Codex models
    ListModels,
}
