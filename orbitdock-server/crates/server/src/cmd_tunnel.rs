//! `orbitdock-server tunnel` — expose the server via Cloudflare Tunnel.
//!
//! Quick tunnel (no account): spins up a temporary `trycloudflare.com` URL.
//! Named tunnel (account required): uses an existing tunnel name.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

use crate::paths;

pub fn run(port: u16, name: Option<&str>) -> anyhow::Result<()> {
    let cloudflared = find_cloudflared()?;

    println!();
    println!("  Starting Cloudflare Tunnel...");
    println!("  Binary: {}", cloudflared);
    println!();

    let mut child = if let Some(tunnel_name) = name {
        println!("  Named tunnel: {}", tunnel_name);
        start_named_tunnel(&cloudflared, port, tunnel_name)?
    } else {
        println!("  Quick tunnel (temporary URL, no account needed)");
        start_quick_tunnel(&cloudflared, port)?
    };

    // Parse stderr for the tunnel URL
    if let Some(stderr) = child.stderr.take() {
        let reader = BufReader::new(stderr);
        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => continue,
            };

            // cloudflared prints the URL to stderr in a line like:
            // "... https://xxx-yyy.trycloudflare.com ..."
            if line.contains("trycloudflare.com") || line.contains(".cloudflare") {
                if let Some(url) = extract_url(&line) {
                    println!();
                    println!("  ══════════════════════════════════════════");
                    println!("  Tunnel URL: {}", url);
                    println!("  ══════════════════════════════════════════");
                    println!();
                    println!("  Connect a remote machine:");
                    println!("    orbitdock-server install-hooks --server-url {}", url);
                    println!();
                    println!("  Press Ctrl+C to stop the tunnel.");
                    println!();
                }
            }

            // Forward all cloudflared output
            eprintln!("  [cloudflared] {}", line);
        }
    }

    // Wait for the child process
    let status = child.wait()?;
    if !status.success() {
        anyhow::bail!("cloudflared exited with status {}", status);
    }

    Ok(())
}

fn find_cloudflared() -> anyhow::Result<String> {
    // 1. Check PATH
    if let Ok(output) = Command::new("which").arg("cloudflared").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return Ok(path);
            }
        }
    }

    // 2. Check ~/.orbitdock/bin/cloudflared
    let local_path = paths::cloudflared_binary_path();
    if local_path.exists() {
        return Ok(local_path.to_string_lossy().to_string());
    }

    anyhow::bail!(
        "cloudflared not found. Install it:\n\
         \n\
         macOS:   brew install cloudflared\n\
         Linux:   curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o ~/.orbitdock/bin/cloudflared && chmod +x ~/.orbitdock/bin/cloudflared\n\
         \n\
         Or download from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    )
}

fn start_quick_tunnel(cloudflared: &str, port: u16) -> anyhow::Result<Child> {
    let child = Command::new(cloudflared)
        .args(["tunnel", "--url", &format!("http://localhost:{}", port)])
        .stderr(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to start cloudflared: {}", e))?;

    Ok(child)
}

fn start_named_tunnel(cloudflared: &str, port: u16, name: &str) -> anyhow::Result<Child> {
    let child = Command::new(cloudflared)
        .args([
            "tunnel",
            "run",
            "--url",
            &format!("http://localhost:{}", port),
            name,
        ])
        .stderr(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to start cloudflared: {}", e))?;

    Ok(child)
}

fn extract_url(line: &str) -> Option<String> {
    // Find HTTPS URLs in the line
    for word in line.split_whitespace() {
        let candidate = word.trim_matches(|c: char| {
            !c.is_alphanumeric() && c != ':' && c != '/' && c != '.' && c != '-'
        });
        if candidate.starts_with("https://") {
            return Some(candidate.to_string());
        }
    }
    None
}
