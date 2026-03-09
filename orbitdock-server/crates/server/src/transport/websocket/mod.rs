//! WebSocket handling — connection lifecycle, message routing, and send helpers.
//!
//! Handler logic lives in `handlers/`, compaction in `support::snapshot_compaction`,
//! and transport-specific helpers in the sibling modules declared here.

mod connection;
pub(crate) mod handlers;
mod message_groups;
mod rest_only_policy;
mod router;
mod server_info;
#[cfg(test)]
pub(crate) mod test_support;
mod transport;

pub use connection::ws_handler;
pub(crate) use router::handle_client_message;
pub(crate) use server_info::server_info_message;
pub(crate) use transport::{
    send_json, send_replay_or_snapshot_fallback, send_rest_only_error, send_snapshot_if_requested,
    spawn_broadcast_forwarder, OutboundMessage,
};
