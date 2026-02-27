//! `orbitdock-server setup` — interactive setup wizard.
//!
//! Combines `init` + `install-hooks` + `generate-token` + `install-service`
//! into a single guided flow for both local and remote deployments.

use std::io::{self, BufRead, Write};
use std::net::SocketAddr;
use std::path::Path;

use crate::{cmd_init, cmd_install_hooks, cmd_install_service, cmd_status};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mode {
    Local,
    Remote,
}

pub struct SetupOptions {
    pub mode: Option<Mode>,
    pub bind: Option<SocketAddr>,
    pub server_url: Option<String>,
    pub skip_service: bool,
    pub skip_hooks: bool,
}

pub fn run(data_dir: &Path, opts: SetupOptions) -> anyhow::Result<()> {
    println!();
    println!("  OrbitDock Server Setup");
    println!("  =====================");
    println!();

    // 1. Determine mode
    let mode = match opts.mode {
        Some(m) => m,
        None => prompt_mode()?,
    };

    let bind = opts.bind.unwrap_or_else(|| match mode {
        Mode::Local => "127.0.0.1:4000".parse().unwrap(),
        Mode::Remote => "0.0.0.0:4000".parse().unwrap(),
    });

    // 2. For remote mode, generate auth token
    let auth_token = if mode == Mode::Remote {
        println!("  Generating auth token...");
        let token = cmd_status::create_token(data_dir)?;
        println!("  Auth token: {}", token);
        println!();
        Some(token)
    } else {
        None
    };

    // 3. Resolve server URL for hooks
    let server_url = if let Some(url) = opts.server_url {
        url
    } else {
        match mode {
            Mode::Local => format!("http://{}", bind),
            Mode::Remote => {
                println!("  \x1b[33m[WARN]\x1b[0m No --server-url provided for remote mode.");
                println!(
                    "         Using http://{} — replace with your public URL",
                    bind
                );
                println!("         when running install-hooks on remote machines.");
                println!();
                format!("http://{}", bind)
            }
        }
    };

    // 4. Run init
    println!("  Running init...");
    cmd_init::run(data_dir, &server_url)?;

    // 5. Install hooks
    if !opts.skip_hooks {
        println!("  Installing Claude Code hooks...");
        let hook_auth = auth_token.as_deref();
        let hook_url = if mode == Mode::Remote {
            Some(server_url.as_str())
        } else {
            None
        };
        cmd_install_hooks::run(None, hook_url, hook_auth)?;
    } else {
        println!("  Skipping hook installation.");
    }

    // 6. Install service
    if !opts.skip_service {
        println!("  Installing system service...");
        cmd_install_service::run(data_dir, bind, true)?;
    } else {
        println!("  Skipping service installation.");
    }

    // 7. Print summary
    println!();
    println!("  Setup complete!");
    println!("  ──────────────");
    println!();
    match mode {
        Mode::Local => {
            println!("  Mode:    Local");
            println!("  Bind:    {}", bind);
            println!("  Health:  http://{}/health", bind);
            println!();
            println!("  Your Claude Code sessions will auto-report to this server.");
        }
        Mode::Remote => {
            println!("  Mode:    Remote");
            println!("  Bind:    {}", bind);
            if let Some(ref token) = auth_token {
                println!("  Token:   {}", token);
            }
            println!();
            println!("  Start the server:");
            if let Some(ref token) = auth_token {
                println!(
                    "    orbitdock-server start --bind {} --auth-token {}",
                    bind, token
                );
            } else {
                println!("    orbitdock-server start --bind {}", bind);
            }
            println!();
            println!("  Connect a remote developer machine (hooks only):");
            if let Some(ref token) = auth_token {
                println!(
                    "    orbitdock-server install-hooks --server-url {} --auth-token {}",
                    server_url, token
                );
            } else {
                println!(
                    "    orbitdock-server install-hooks --server-url {}",
                    server_url
                );
            }
        }
    }
    println!();

    Ok(())
}

fn prompt_mode() -> anyhow::Result<Mode> {
    println!("  How will you use this server?");
    println!();
    println!("    1) Local    — runs on this machine, localhost only");
    println!("    2) Remote   — accessible from other machines (generates auth token)");
    println!();
    print!("  Choice [1]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let trimmed = input.trim();

    match trimmed {
        "" | "1" | "local" => Ok(Mode::Local),
        "2" | "remote" => Ok(Mode::Remote),
        _ => {
            println!("  Invalid choice, defaulting to local.");
            Ok(Mode::Local)
        }
    }
}
