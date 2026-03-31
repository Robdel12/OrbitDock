//! OrbitDock Server library.
//!
//! Exposes reusable server runtime and admin/setup operations so the single
//! `orbitdock` binary can move command ownership into `crates/cli` without
//! duplicating daemon logic.

pub mod admin;
mod app;
pub(crate) mod connectors;
pub(crate) mod domain;
pub(crate) mod infrastructure;
pub(crate) mod runtime;
pub(crate) mod support;
pub(crate) mod transport;

use std::path::{Path, PathBuf};

/// Server version, baked in at compile time.
pub const VERSION: &str = match option_env!("ORBITDOCK_BUILD_VERSION") {
  Some(version) => version,
  None => env!("CARGO_PKG_VERSION"),
};

/// Oldest client version this server binary will accept.
/// Keep this explicit so compatibility behavior stays predictable across builds.
pub const MINIMUM_CLIENT_VERSION: &str = "0.7.0";

pub use app::{run_server, ManagedSyncRunOptions, ServerRunOptions};
pub use infrastructure::logging::{ServerLogEvent, ServerLoggingOptions, StderrLogMode};

pub fn init_data_dir(explicit: Option<&Path>) -> PathBuf {
  infrastructure::paths::init_data_dir(explicit)
}

// ── Public re-exports for CLI subcommands ───────────────────────────

/// Mission tool definitions (shared schemas used by MCP server and Codex dynamic tools).
pub mod mission_tools {
  pub use crate::domain::mission_control::executor::execute_mission_tool;
  pub use crate::domain::mission_control::executor::MissionToolResult;
  pub use crate::domain::mission_control::tools::{
    mission_tool_definitions, MissionToolContext, MissionToolDef,
  };
}

/// Linear client for direct API access (used by the MCP mission-tools server).
pub mod linear {
  pub use crate::infrastructure::linear::client::LinearClient;
}

/// GitHub client for direct API access (used by the MCP mission-tools server).
pub mod github {
  pub use crate::infrastructure::github::client::GitHubClient;
}

/// Tracker trait for pluggable issue trackers.
pub mod tracker {
  pub use crate::domain::mission_control::tracker::Tracker;
}
