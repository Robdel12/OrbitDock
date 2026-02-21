//! `orbitdock-server status` — check if the server is running.
//! `orbitdock-server generate-token` — create a random auth token.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::paths;
use crate::VERSION;

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

    println!();

    if !pid_alive && !health_ok {
        println!("  Server is not running.");
        println!("  Start with: orbitdock-server start");
    }

    println!();
    Ok(())
}

pub fn generate_token(data_dir: &Path) -> anyhow::Result<()> {
    let token = uuid::Uuid::new_v4().to_string();
    let token_path = paths::token_file_path();

    // Ensure data dir exists
    std::fs::create_dir_all(data_dir)?;

    std::fs::write(&token_path, &token)?;
    std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600))?;

    println!();
    println!(
        "  Auth token generated and saved to {}",
        token_path.display()
    );
    println!();
    println!("  Token: {}", token);
    println!();
    println!("  Usage:");
    println!("    orbitdock-server start --auth-token {}", token);
    println!("  Or:");
    println!(
        "    orbitdock-server start --auth-token $(cat {})",
        token_path.display()
    );
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
