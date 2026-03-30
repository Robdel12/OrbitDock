//! Claude Code hook ingestion and passive session materialization.

mod approval;
mod handler;
mod session_materialization;

pub use handler::{
  handle_hook_message,
};
