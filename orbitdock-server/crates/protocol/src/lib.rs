//! OrbitDock Protocol
//!
//! Shared types for communication between OrbitDock server and clients.
//! These types are serialized as JSON over WebSocket.

use uuid::Uuid;

// Re-exports
pub mod client;
pub mod server;
pub mod types;

pub use client::ClientMessage;
pub use server::ServerMessage;
pub use types::*;

/// Generate a new unique ID
pub fn new_id() -> String {
    Uuid::new_v4().to_string()
}
