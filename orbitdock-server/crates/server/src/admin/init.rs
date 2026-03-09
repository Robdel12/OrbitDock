//! `orbitdock init` — bootstrap a fresh machine.
//!
//! Creates data dir structure, runs migrations, and prints helpful next-steps
//! guidance.

use std::path::Path;

use crate::migration_runner;
use crate::paths;

pub fn run(data_dir: &Path, _server_url: &str) -> anyhow::Result<()> {
    let installer_mode = installer_mode();
    println!();

    // 1. Create directory structure
    paths::ensure_dirs()?;
    println!("  Created {}/", data_dir.display());

    // 2. Ensure encryption key exists
    crate::crypto::ensure_key();
    println!(
        "  Encryption key ready at {}",
        paths::encryption_key_path().display()
    );

    // 2. Run database migrations
    let db_path = paths::db_path();
    let mut conn = rusqlite::Connection::open(&db_path)?;
    migration_runner::run_migrations(&mut conn)?;
    println!("  Database initialized at {}", db_path.display());

    // 3. Detect Tailscale
    let ts_ip = detect_tailscale_ip();

    if !installer_mode {
        println!();
        if let Some(ip) = &ts_ip {
            println!("  Tailscale detected! Your IP: {}", ip);
            println!("  For remote access (secure by default):");
            println!("    orbitdock generate-token");
            println!("    orbitdock start --bind 0.0.0.0:4000");
            println!();
        }

        println!("  Next steps:");
        println!("    1. Install Claude Code hooks:  orbitdock install-hooks");
        println!("    2. Start the server:           orbitdock start");
        println!("    3. Install as a service:       orbitdock install-service --enable");
        println!();
    }

    Ok(())
}

fn installer_mode() -> bool {
    std::env::var_os("ORBITDOCK_INSTALLER_MODE").is_some()
}

fn detect_tailscale_ip() -> Option<String> {
    let output = std::process::Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let self_node = json.get("Self")?;
    let addrs = self_node.get("TailscaleIPs")?.as_array()?;
    // Prefer IPv4
    addrs
        .iter()
        .find(|a| a.as_str().map(|s| !s.contains(':')).unwrap_or(false))
        .or_else(|| addrs.first())
        .and_then(|a| a.as_str())
        .map(|s| s.to_string())
}
