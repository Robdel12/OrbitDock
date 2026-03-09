//! OrbitDock Server library.
//!
//! Exposes reusable server runtime and admin/setup operations so the single
//! `orbitdock` binary can move command ownership into `crates/cli` without
//! duplicating daemon logic.

mod app;
mod ai_naming;
pub mod admin;
mod auth;
mod auth_tokens;
mod claude_session;
mod codex_session;
pub(crate) mod crypto;
mod git;
mod git_refresh;
mod hook_handler;
mod http_api;
pub(crate) mod images;
mod logging;
mod metrics;
mod migration_runner;
mod normalization;
pub(crate) mod paths;
mod persistence;
mod rollout_watcher;
mod session;
mod session_actor;
mod session_command;
mod session_command_handler;
mod session_history;
mod session_naming;
mod session_utils;
mod shell;
mod snapshot_compaction;
mod state;
mod subagent_parser;
mod transition;
mod usage_probe;
mod websocket;
mod worktree_include;
mod worktree_service;
mod ws_handlers;

use std::path::{Path, PathBuf};

/// Server version, baked in at compile time.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub use app::{run_server, ServerRunOptions};

pub fn init_data_dir(explicit: Option<&Path>) -> PathBuf {
    paths::init_data_dir(explicit)
}
