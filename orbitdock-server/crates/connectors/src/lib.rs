//! OrbitDock Connectors
//!
//! Connectors for different AI providers (Claude, Codex).
//! Each connector handles communication with its respective provider
//! and translates events to the common OrbitDock protocol.

pub mod codex;

pub use codex::CodexConnector;
use orbitdock_protocol::TokenUsage;
use thiserror::Error;

/// Errors that can occur in connectors
#[derive(Debug, Error)]
pub enum ConnectorError {
    #[error("Failed to spawn process: {0}")]
    SpawnError(String),

    #[error("Process communication error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("JSON serialization error: {0}")]
    JsonError(#[from] serde_json::Error),

    #[error("Channel closed")]
    ChannelClosed,

    #[error("Provider error: {0}")]
    ProviderError(String),
}

/// Events emitted by connectors
#[derive(Debug, Clone)]
pub enum ConnectorEvent {
    /// Turn started
    TurnStarted,

    /// Turn completed
    TurnCompleted,

    /// Turn aborted
    TurnAborted { reason: String },

    /// New message created
    MessageCreated(orbitdock_protocol::Message),

    /// Message updated
    MessageUpdated {
        message_id: String,
        content: Option<String>,
        tool_output: Option<String>,
        is_error: Option<bool>,
        duration_ms: Option<u64>,
    },

    /// Approval requested
    ApprovalRequested {
        request_id: String,
        approval_type: ApprovalType,
        command: Option<String>,
        file_path: Option<String>,
        diff: Option<String>,
        question: Option<String>,
    },

    /// Token usage updated
    TokensUpdated(TokenUsage),

    /// Aggregated diff updated
    DiffUpdated(String),

    /// Plan updated
    PlanUpdated(String),

    /// Session ended
    SessionEnded { reason: String },

    /// Error occurred
    Error(String),
}

/// Type of approval request
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalType {
    Exec,
    Patch,
    Question,
}
