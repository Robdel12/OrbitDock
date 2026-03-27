//! `orbitdock tunnel` — expose the server via Cloudflare Tunnel.
//!
//! Quick tunnel (no account): spins up a temporary `trycloudflare.com` URL.
//! Named tunnel (account required): uses an existing tunnel name.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::infrastructure::paths;

pub fn start_cloudflare_tunnel(port: u16, name: Option<&str>) -> anyhow::Result<()> {
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
          println!("    orbitdock setup client");
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

/// Check if cloudflared is available, offering to install it if not.
///
/// Returns the path to the cloudflared binary on success.
pub fn ensure_cloudflared() -> anyhow::Result<String> {
  match find_cloudflared() {
    Ok(path) => {
      println!("  cloudflared found: {}", path);
      Ok(path)
    }
    Err(_) => {
      if cfg!(target_os = "macos") {
        println!("  cloudflared not found.");
        print!("  Install via Homebrew? [Y/n] ");
        std::io::stdout().flush()?;

        let mut input = String::new();
        std::io::stdin().lock().read_line(&mut input)?;
        let trimmed = input.trim().to_ascii_lowercase();

        if trimmed.is_empty() || trimmed == "y" || trimmed == "yes" {
          println!("  Installing cloudflared...");
          let status = Command::new("brew")
            .args(["install", "cloudflared"])
            .status()?;
          if !status.success() {
            anyhow::bail!("brew install cloudflared failed");
          }
          find_cloudflared()
        } else {
          anyhow::bail!("cloudflared is required for Cloudflare Tunnel setup")
        }
      } else {
        anyhow::bail!(
          "cloudflared not found.\n\n\
           Install it:\n\
           curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
           -o ~/.orbitdock/bin/cloudflared && chmod +x ~/.orbitdock/bin/cloudflared\n\n\
           Or download from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        )
      }
    }
  }
}

/// Start a quick tunnel and extract the public URL.
///
/// Returns the child process (still running) and the extracted URL.
/// The caller is responsible for the child's lifetime.
pub fn start_tunnel_and_extract_url(port: u16) -> anyhow::Result<(Child, String)> {
  let cloudflared = find_cloudflared()?;
  let mut child = start_quick_tunnel(&cloudflared, port)?;

  let stderr = child
    .stderr
    .take()
    .ok_or_else(|| anyhow::anyhow!("no stderr from cloudflared"))?;

  // Read stderr on a background thread so we can apply a timeout.
  let (tx, rx) = mpsc::channel::<String>();
  std::thread::spawn(move || {
    let reader = BufReader::new(stderr);
    for line in reader.lines().map_while(Result::ok) {
      if tx.send(line).is_err() {
        break;
      }
    }
  });

  let deadline = Instant::now() + Duration::from_secs(60);
  while let Ok(line) = rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
    if line.contains("trycloudflare.com") || line.contains(".cloudflare") {
      if let Some(url) = extract_url(&line) {
        return Ok((child, url));
      }
    }
  }

  let _ = child.kill();
  anyhow::bail!("Timed out waiting for cloudflared to print tunnel URL (60s)")
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

pub(crate) fn extract_url(line: &str) -> Option<String> {
  // Find HTTPS URLs in the line
  for word in line.split_whitespace() {
    let candidate = word
      .trim_matches(|c: char| !c.is_alphanumeric() && c != ':' && c != '/' && c != '.' && c != '-');
    if candidate.starts_with("https://") {
      return Some(candidate.to_string());
    }
  }
  None
}

#[cfg(test)]
mod tests {
  use super::extract_url;

  #[test]
  fn extract_url_finds_trycloudflare_url() {
    let line =
      "2024-01-15T12:00:00Z INF +-----------------------------------------------------------+";
    assert_eq!(extract_url(line), None);

    let line = "2024-01-15T12:00:00Z INF |  https://abc-def.trycloudflare.com  |";
    assert_eq!(
      extract_url(line),
      Some("https://abc-def.trycloudflare.com".to_string())
    );
  }

  #[test]
  fn extract_url_handles_no_url() {
    assert_eq!(extract_url("just some text with no url"), None);
  }
}
