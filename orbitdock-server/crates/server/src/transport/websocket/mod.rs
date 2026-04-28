//! WebSocket handling — connection lifecycle, message routing, and send helpers.
//!
//! Handler logic lives in `handlers/`, compaction in `support::snapshot_compaction`,
//! and transport-specific helpers in the sibling modules declared here.

mod connection;
pub(crate) mod handlers;
mod message_groups;
mod router;
mod transport;

pub(crate) use crate::runtime::server_info::{server_hello_message, server_info_message};
pub use connection::ws_handler;
pub(crate) use router::handle_client_message;
pub(crate) use transport::{
  send_json, send_replay_or_resync_fallback, spawn_filtered_broadcast_forwarder, OutboundMessage,
};
