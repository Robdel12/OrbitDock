//! `orbitdock init` — bootstrap a fresh machine.
//!
//! Creates data dir structure, runs migrations, auto-provisions a local auth
//! token (encrypted in `hook-forward.json`), and prints helpful next-steps
//! guidance.

use std::path::Path;

use orbitdock_protocol::WorkspaceProviderKind;

use crate::infrastructure::auth_tokens;
use crate::infrastructure::migration_runner;
use crate::infrastructure::paths;

use super::hook_forward;

pub fn initialize_data_dir(
    data_dir: &Path,
    _server_url: &str,
    workspace_provider: WorkspaceProviderKind,
) -> anyhow::Result<()> {
    let installer_mode = installer_mode();
    println!();

    // 1. Create directory structure
    paths::ensure_dirs()?;
    println!("  Created {}/", data_dir.display());

    // 2. Ensure encryption key exists
    crate::infrastructure::crypto::ensure_key();
    println!(
        "  Encryption key ready at {}",
        paths::encryption_key_path().display()
    );

    // 3. Run database migrations
    let db_path = paths::db_path();
    let mut conn = rusqlite::Connection::open(&db_path)?;
    migration_runner::run_migrations(&mut conn)?;
    conn.execute(
        "INSERT INTO config (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params!["workspace_provider", workspace_provider.as_str()],
    )?;
    println!("  Database initialized at {}", db_path.display());
    println!(
        "  Workspace provider set to {}",
        workspace_provider.as_str()
    );

    // 4. Auto-provision local auth token (idempotent — skips if tokens exist)
    // Check both DB tokens and the encrypted hook config — if the config lost
    // its token (e.g., install-hooks clobbered it), issue a fresh one.
    let active_tokens = auth_tokens::active_token_count().unwrap_or(0);
    let hook_config_has_token = hook_forward::read_transport_config()
        .ok()
        .flatten()
        .and_then(|cfg| cfg.auth_token())
        .is_some();

    if active_tokens == 0 || !hook_config_has_token {
        let issued = auth_tokens::issue_token(Some("local"))?;
        hook_forward::write_transport_config("http://127.0.0.1:4000", Some(&issued.token))?;
        println!(
            "  Auth token provisioned (encrypted in {})",
            paths::hook_transport_config_path().display()
        );
    } else {
        println!(
            "  Auth tokens already configured ({} active)",
            active_tokens
        );
    }

    // 5. Detect Tailscale
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
