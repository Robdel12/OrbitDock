//! OrbitDock Connector Core
//!
//! Shared event and error types for OrbitDock connectors.
//! Provider-agnostic vocabulary used by both concrete connector
//! implementations and the server.

mod error;
mod event;
pub mod transition;

pub use error::ConnectorError;
pub use event::ConnectorEvent;

// Re-export ApprovalType from protocol so consumers don't need a
// separate protocol dependency just for this enum.
pub use orbitdock_protocol::ApprovalType;
