//! `orbitdock-server init` — bootstrap a fresh machine.
//!
//! Creates data dir structure, runs migrations, installs the hook script,
//! and prints helpful next-steps guidance.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::migration_runner;
use crate::paths;

const HOOK_TEMPLATE: &str = include_str!("../../../../scripts/hook.sh.template");

pub fn run(data_dir: &Path, server_url: &str) -> anyhow::Result<()> {
    println!();

    // 1. Create directory structure
    paths::ensure_dirs()?;
    println!("  Created {}/", data_dir.display());

    // 2. Run database migrations
    let db_path = paths::db_path();
    let mut conn = rusqlite::Connection::open(&db_path)?;
    migration_runner::run_migrations(&mut conn)?;
    println!("  Database initialized at {}", db_path.display());

    // 3. Install rendered hook script
    let spool_dir = paths::spool_dir();
    let hook_path = paths::hook_script_path();

    // Read auth token if it exists
    let token_path = paths::token_file_path();
    let auth_token = std::fs::read_to_string(&token_path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_default();

    let rendered = HOOK_TEMPLATE
        .replace("{{SERVER_URL}}", server_url)
        .replace("{{SPOOL_DIR}}", &spool_dir.to_string_lossy())
        .replace("{{AUTH_HEADER}}", &auth_token);

    std::fs::write(&hook_path, &rendered)?;
    std::fs::set_permissions(&hook_path, std::fs::Permissions::from_mode(0o755))?;
    println!("  Hook script installed to {}", hook_path.display());

    // 4. Detect Tailscale
    let ts_ip = detect_tailscale_ip();

    println!();
    if let Some(ip) = &ts_ip {
        println!("  Tailscale detected! Your IP: {}", ip);
        println!("  For remote access: orbitdock-server start --bind 0.0.0.0:4000");
        println!();
    }

    println!("  Next steps:");
    println!("    1. Install Claude Code hooks:  orbitdock-server install-hooks");
    println!("    2. Start the server:           orbitdock-server start");
    println!("    3. Install as a service:       orbitdock-server install-service --enable");
    println!();

    Ok(())
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
