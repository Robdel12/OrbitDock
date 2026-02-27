//! OrbitDock Connector Core
//!
//! Provider-agnostic vocabulary shared by all connectors and the server.
//! Includes unified event/error types and the pure transition state machine.

mod error;
mod event;
pub mod transition;

pub use error::ConnectorError;
pub use event::ConnectorEvent;

// Re-export ApprovalType from protocol so consumers don't need a
// separate protocol dependency just for this enum.
pub use orbitdock_protocol::ApprovalType;
