//! `orbitdock tunnel` — expose the server via Cloudflare Tunnel.
//!
//! Quick tunnel (no account): spins up a temporary `trycloudflare.com` URL.
//! Named tunnel (account required): uses an existing tunnel name.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const CLOUDFLARED_LABEL: &str = "com.orbitdock.cloudflare-tunnel";
const CLOUDFLARED_SERVICE_NAME: &str = "orbitdock-cloudflare-tunnel";
const CLOUDFLARED_STDOUT_LOG: &str = "cloudflared-stdout.log";
const CLOUDFLARED_STDERR_LOG: &str = "cloudflared-stderr.log";

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
      if is_tunnel_url_line(&line) {
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
           Install it: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        )
      }
    }
  }
}

/// Install and start a background Cloudflare tunnel service, then wait for the
/// generated public URL to appear in the service logs.
pub fn start_background_cloudflare_tunnel(port: u16) -> anyhow::Result<String> {
  let cloudflared = ensure_cloudflared()?;
  let logs_dir = tunnel_logs_dir();
  fs::create_dir_all(&logs_dir)?;
  clear_tunnel_logs(&logs_dir);

  install_cloudflared_service(&cloudflared, port, &logs_dir)?;
  start_cloudflared_service()?;

  wait_for_tunnel_url(&logs_dir)
}

fn install_cloudflared_service(
  cloudflared: &str,
  port: u16,
  logs_dir: &Path,
) -> anyhow::Result<()> {
  let service_file = tunnel_service_file_path();
  stop_existing_cloudflared_service(&service_file);

  let service = if cfg!(target_os = "macos") {
    render_launchd_tunnel_plist(cloudflared, port, logs_dir)
  } else {
    render_systemd_tunnel_unit(cloudflared, port, logs_dir)
  };

  if let Some(parent) = service_file.parent() {
    fs::create_dir_all(parent)?;
  }
  write_service_file(&service_file, &service)?;

  #[cfg(target_os = "macos")]
  validate_launchd_plist(&service_file)?;

  println!("  Wrote {}", service_file.display());
  Ok(())
}

fn start_cloudflared_service() -> anyhow::Result<()> {
  if cfg!(target_os = "macos") {
    let domain = launchd_domain();
    let service_path = tunnel_service_file_path();
    let bootstrap = Command::new("launchctl")
      .args(["bootstrap", &domain, &service_path.to_string_lossy()])
      .output()?;

    if !bootstrap.status.success() {
      let stderr = String::from_utf8_lossy(&bootstrap.stderr);
      anyhow::bail!("launchctl bootstrap failed: {}", stderr.trim());
    }

    let kickstart_target = format!("{domain}/{CLOUDFLARED_LABEL}");
    let kickstart = Command::new("launchctl")
      .args(["kickstart", "-k", &kickstart_target])
      .output()?;

    if !kickstart.status.success() {
      let stderr = String::from_utf8_lossy(&kickstart.stderr);
      anyhow::bail!("launchctl kickstart failed: {}", stderr.trim());
    }

    return Ok(());
  }

  let _ = Command::new("systemctl")
    .args(["--user", "daemon-reload"])
    .output();

  let output = Command::new("systemctl")
    .args(["--user", "enable", "--now", CLOUDFLARED_SERVICE_NAME])
    .output()?;

  if !output.status.success() {
    let stderr = String::from_utf8_lossy(&output.stderr);
    anyhow::bail!("systemctl enable failed: {}", stderr.trim());
  }

  Ok(())
}

fn wait_for_tunnel_url(logs_dir: &Path) -> anyhow::Result<String> {
  let deadline = Instant::now() + Duration::from_secs(60);
  let log_paths = [
    logs_dir.join(CLOUDFLARED_STDOUT_LOG),
    logs_dir.join(CLOUDFLARED_STDERR_LOG),
  ];

  while Instant::now() < deadline {
    for log_path in &log_paths {
      if let Ok(content) = fs::read_to_string(log_path) {
        for line in content.lines().rev() {
          if let Some(url) = extract_url(line) {
            return Ok(url);
          }
        }
      }
    }
    std::thread::sleep(Duration::from_millis(250));
  }

  anyhow::bail!(
    "Timed out waiting for cloudflared tunnel URL to appear in {}",
    logs_dir.display()
  )
}

fn find_cloudflared() -> anyhow::Result<String> {
  if let Ok(output) = Command::new("which").arg("cloudflared").output() {
    if output.status.success() {
      let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
      if !path.is_empty() {
        return Ok(path);
      }
    }
  }

  anyhow::bail!(
    "cloudflared not found. Install it:\n\
     \n\
     macOS:   brew install cloudflared\n\
     Linux:   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/\n"
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
  // Find HTTPS URLs in the line.
  // This is intentionally strict: Cloudflared logs can include unrelated
  // Cloudflare links (like website terms), and we only want the tunnel URL.
  for word in line.split_whitespace() {
    let candidate = word
      .trim_matches(|c: char| !c.is_alphanumeric() && c != ':' && c != '/' && c != '.' && c != '-');
    if is_tunnel_url(candidate) {
      return Some(candidate.to_string());
    }
  }
  None
}

fn is_tunnel_url_line(line: &str) -> bool {
  line.contains(".trycloudflare.com") || line.contains(".cfargotunnel.com")
}

fn is_tunnel_url(candidate: &str) -> bool {
  candidate.starts_with("https://")
    && (candidate.contains(".trycloudflare.com") || candidate.contains(".cfargotunnel.com"))
}

fn tunnel_logs_dir() -> PathBuf {
  dirs::home_dir()
    .expect("HOME not found")
    .join(".orbitdock/logs")
}

fn tunnel_service_file_path() -> PathBuf {
  let home = dirs::home_dir().expect("HOME not found");
  if cfg!(target_os = "macos") {
    home.join("Library/LaunchAgents/com.orbitdock.cloudflare-tunnel.plist")
  } else {
    home.join(".config/systemd/user/orbitdock-cloudflare-tunnel.service")
  }
}

fn clear_tunnel_logs(logs_dir: &Path) {
  let _ = fs::remove_file(logs_dir.join(CLOUDFLARED_STDOUT_LOG));
  let _ = fs::remove_file(logs_dir.join(CLOUDFLARED_STDERR_LOG));
}

fn stop_existing_cloudflared_service(service_file: &Path) {
  if cfg!(target_os = "macos") {
    let domain = launchd_domain();
    let target = format!("{domain}/{CLOUDFLARED_LABEL}");
    let _ = Command::new("launchctl")
      .args(["bootout", &target])
      .output();
    let _ = Command::new("launchctl")
      .args(["bootout", &domain, &service_file.to_string_lossy()])
      .output();
  } else {
    let _ = Command::new("systemctl")
      .args(["--user", "disable", "--now", CLOUDFLARED_SERVICE_NAME])
      .output();
  }
}

fn render_launchd_tunnel_plist(cloudflared: &str, port: u16, logs_dir: &Path) -> String {
  let stdout_path = logs_dir.join(CLOUDFLARED_STDOUT_LOG);
  let stderr_path = logs_dir.join(CLOUDFLARED_STDERR_LOG);
  format!(
    r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{cloudflared}</string>
        <string>tunnel</string>
        <string>--no-autoupdate</string>
        <string>--url</string>
        <string>http://127.0.0.1:{port}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{stdout}</string>
    <key>StandardErrorPath</key>
    <string>{stderr}</string>
</dict>
</plist>
"#,
    label = CLOUDFLARED_LABEL,
    cloudflared = escape_xml(cloudflared),
    port = port,
    stdout = escape_xml(&stdout_path.to_string_lossy()),
    stderr = escape_xml(&stderr_path.to_string_lossy()),
  )
}

fn render_systemd_tunnel_unit(cloudflared: &str, port: u16, logs_dir: &Path) -> String {
  let stdout_path = logs_dir.join(CLOUDFLARED_STDOUT_LOG);
  let stderr_path = logs_dir.join(CLOUDFLARED_STDERR_LOG);
  format!(
    r#"[Unit]
Description=OrbitDock Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart={cloudflared} tunnel --no-autoupdate --url http://127.0.0.1:{port}
Restart=always
RestartSec=5
StandardOutput=append:{stdout}
StandardError=append:{stderr}

[Install]
WantedBy=default.target
"#,
    cloudflared = cloudflared,
    port = port,
    stdout = stdout_path.to_string_lossy(),
    stderr = stderr_path.to_string_lossy(),
  )
}

fn write_service_file(path: &Path, content: &str) -> anyhow::Result<()> {
  #[cfg(unix)]
  {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let mut file = fs::OpenOptions::new()
      .write(true)
      .create(true)
      .truncate(true)
      .mode(0o600)
      .open(path)?;
    std::io::Write::write_all(&mut file, content.as_bytes())?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
  }

  #[cfg(not(unix))]
  {
    fs::write(path, content)?;
    Ok(())
  }
}

#[cfg(target_os = "macos")]
fn validate_launchd_plist(plist_path: &Path) -> anyhow::Result<()> {
  let output = Command::new("plutil")
    .args(["-lint", &plist_path.to_string_lossy()])
    .output()?;

  if output.status.success() {
    return Ok(());
  }

  let stderr = String::from_utf8_lossy(&output.stderr);
  let stdout = String::from_utf8_lossy(&output.stdout);
  let detail = stderr.trim();
  let fallback = stdout.trim();
  anyhow::bail!(
    "launchd plist validation failed: {}",
    if detail.is_empty() { fallback } else { detail }
  );
}

#[cfg(not(target_os = "macos"))]
fn validate_launchd_plist(_plist_path: &Path) -> anyhow::Result<()> {
  Ok(())
}

fn launchd_domain() -> String {
  format!("gui/{}", unsafe { libc::geteuid() })
}

fn escape_xml(value: &str) -> String {
  value
    .replace('&', "&amp;")
    .replace('<', "&lt;")
    .replace('>', "&gt;")
    .replace('"', "&quot;")
    .replace('\'', "&apos;")
}

#[cfg(test)]
#[path = "tunnel_tests.rs"]
mod tests;
