//! `orbitdock status` — check if the server is running.
//! `orbitdock generate-token` — create a secure auth token.

use std::path::Path;

use crate::VERSION;
use crate::{auth_tokens, paths};

pub fn run(data_dir: &Path) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Server v{}", VERSION);
    println!("  Data dir: {}", data_dir.display());

    // Check PID file
    let pid_path = paths::pid_file_path();
    let pid_alive = if pid_path.exists() {
        let pid_str = std::fs::read_to_string(&pid_path).unwrap_or_default();
        let pid: u32 = pid_str.trim().parse().unwrap_or(0);
        if pid > 0 && process_alive(pid) {
            println!("  PID: {} (running)", pid);
            true
        } else {
            println!("  PID file: {} (stale — process not found)", pid);
            false
        }
    } else {
        println!("  PID file: not found");
        false
    };

    // Try HTTP health check
    let health_ok = check_health();
    if health_ok {
        println!("  Health: OK (http://127.0.0.1:4000/health)");
    } else if pid_alive {
        println!("  Health: unreachable (server may be binding to a different address)");
    } else {
        println!("  Health: unreachable");
    }

    // DB size
    let db_path = paths::db_path();
    if db_path.exists() {
        let size = std::fs::metadata(&db_path).map(|m| m.len()).unwrap_or(0);
        println!("  Database: {} ({} KB)", db_path.display(), size / 1024);
    } else {
        println!("  Database: not found");
    }

    match auth_tokens::active_token_count() {
        Ok(count) if count > 0 => {
            println!("  Auth tokens: {} active", count);
        }
        Ok(_) => {
            println!("  Auth tokens: none");
        }
        Err(_) => {
            println!("  Auth tokens: unavailable");
        }
    }

    println!();

    if !pid_alive && !health_ok {
        println!("  Server is not running.");
        println!("  Start with: orbitdock start");
    }

    println!();
    Ok(())
}

/// Create a new auth token and store its hash in the database. Returns the token string.
pub fn create_token(data_dir: &Path) -> anyhow::Result<String> {
    let _ = data_dir;
    let issued = auth_tokens::issue_token(None)?;
    Ok(issued.token)
}

pub fn generate_token(data_dir: &Path) -> anyhow::Result<()> {
    let _ = data_dir;
    let issued = auth_tokens::issue_token(None)?;

    println!();
    println!("  Secure auth token generated and stored (hashed) in the database.");
    println!("  Copy it now and store it somewhere secure.");
    println!();
    println!("  Token ID: {}", issued.id);
    println!("  Token: {}", issued.token);
    println!();
    println!("  Usage:");
    println!("    # Start server (token store mode)");
    println!("    orbitdock start --bind 0.0.0.0:4000");
    println!("    # Configure hooks or clients with the token shown above");
    println!("    # `orbitdock install-hooks --server-url ...` will prompt for it");
    println!("    # Or set ORBITDOCK_AUTH_TOKEN before running client commands");
    println!();

    Ok(())
}

pub fn list_tokens() -> anyhow::Result<()> {
    let tokens = auth_tokens::list_tokens()?;

    println!();
    println!("  Auth Tokens");
    println!("  ───────────");
    println!();

    if tokens.is_empty() {
        println!("  No tokens found.");
        println!();
        return Ok(());
    }

    for token in tokens {
        let status = if token.revoked_at.is_some() {
            "revoked"
        } else {
            "active"
        };
        let label = token.label.as_deref().unwrap_or("(no label)");
        println!("  {}  [{}]  {}", token.id, status, label);
        println!("    created: {}", token.created_at);
        if let Some(ref used) = token.last_used_at {
            println!("    last used: {}", used);
        }
        if let Some(ref expires) = token.expires_at {
            println!("    expires: {}", expires);
        }
        if let Some(ref revoked) = token.revoked_at {
            println!("    revoked: {}", revoked);
        }
        println!();
    }

    Ok(())
}

pub fn revoke_token(token_id: &str) -> anyhow::Result<()> {
    let revoked = auth_tokens::revoke_token(token_id)?;
    println!();
    if revoked {
        println!("  Revoked token {}", token_id.trim());
    } else {
        println!(
            "  Token {} was not found or already revoked",
            token_id.trim()
        );
    }
    println!();
    Ok(())
}

fn process_alive(pid: u32) -> bool {
    // kill -0 checks if process exists without sending a signal
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn check_health() -> bool {
    // Use a quick blocking HTTP check (this runs outside tokio)
    std::process::Command::new("curl")
        .args([
            "-s",
            "--connect-timeout",
            "1",
            "--max-time",
            "2",
            "http://127.0.0.1:4000/health",
        ])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
