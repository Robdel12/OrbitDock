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
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub use app::{run_server, ServerRunOptions};

pub fn init_data_dir(explicit: Option<&Path>) -> PathBuf {
    infrastructure::paths::init_data_dir(explicit)
}
