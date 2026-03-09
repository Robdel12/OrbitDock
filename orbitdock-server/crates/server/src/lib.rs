//! OrbitDock Server library.
//!
//! Exposes reusable server runtime and admin/setup operations so the single
//! `orbitdock` binary can move command ownership into `crates/cli` without
//! duplicating daemon logic.

pub mod admin;
mod app;
mod connectors;
mod domain;
mod infrastructure;
mod support;
mod transport;

pub(crate) use connectors::{
    claude_session, codex_session, hook_handler, rollout_watcher, subagent_parser,
};
pub(crate) use domain::git::{git, git_refresh};
pub(crate) use domain::sessions::{
    session, session_actor, session_command, session_command_handler, session_history,
    session_naming, session_utils, state, transition,
};
pub(crate) use domain::worktrees::{worktree_include, worktree_service};
pub(crate) use infrastructure::{
    auth, auth_tokens, crypto, images, logging, metrics, migration_runner, paths, persistence,
    shell, usage_probe,
};
pub(crate) use support::{ai_naming, normalization, snapshot_compaction};
pub(crate) use transport::http as http_api;
pub(crate) use transport::websocket;
pub(crate) use transport::websocket::handlers as ws_handlers;

use std::path::{Path, PathBuf};

/// Server version, baked in at compile time.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub use app::{run_server, ServerRunOptions};

pub fn init_data_dir(explicit: Option<&Path>) -> PathBuf {
    paths::init_data_dir(explicit)
}
