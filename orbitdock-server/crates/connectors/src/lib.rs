//! OrbitDock Connectors
//!
//! Connectors for different AI providers (Claude, Codex).
//! Each connector handles communication with its respective provider
//! and translates events to the common OrbitDock protocol.

pub mod claude;
pub mod codex;

pub use claude::ClaudeConnector;
pub use codex::{discover_models, CodexConnector, SteerOutcome};

// Re-export shared types from connector-core so existing consumers don't break.
pub use orbitdock_connector_core::{ApprovalType, ConnectorError, ConnectorEvent};
