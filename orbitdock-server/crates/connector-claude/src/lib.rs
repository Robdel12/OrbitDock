//! Claude CLI Direct connector
//!
//! Spawns the `claude` CLI as a subprocess and communicates via stdin/stdout
//! using the NDJSON stream-json protocol. No Node.js bridge needed.

pub mod session;

mod connector;
mod images;
mod protocol;
mod rows;
mod stdout;

pub use connector::{is_accept_edits_tool, ClaudeConnector, ACCEPT_EDITS_TOOLS};

#[cfg(test)]
mod lib_tests;
