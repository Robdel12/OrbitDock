//! `orbitdock remote-setup` — deprecated, delegates to `orbitdock setup server`.

use std::path::Path;

use super::setup::{self, SetupOptions, SetupPath};

pub fn guide_remote_setup(data_dir: &Path) -> anyhow::Result<()> {
  println!();
  println!("  \x1b[33m[DEPRECATED]\x1b[0m `remote-setup` has been merged into `orbitdock setup`.");
  println!("  Running `orbitdock setup server`...");

  setup::run_setup_wizard(
    data_dir,
    SetupOptions {
      path: Some(SetupPath::Server),
    },
  )
}
