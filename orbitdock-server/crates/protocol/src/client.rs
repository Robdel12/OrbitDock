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
    },
    ApproveTool {
        session_id: String,
        request_id: String,
        approved: bool,
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

    // Session management
    CreateSession {
        provider: Provider,
        cwd: String,
        model: Option<String>,
    },
}
