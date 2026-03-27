//! `orbitdock setup` — interactive setup wizard.
//!
//! Three paths:
//!   - **Local**  — server + Claude Code on this machine
//!   - **Server** — other devices connect to this machine
//!   - **Client** — connect to an existing OrbitDock server (hooks only)

use std::fs;
use std::io::{self, BufRead, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::infrastructure::auth_tokens;
use crate::infrastructure::paths;

use super::{init, install_hooks, install_service, pair, status, tunnel};

// ── Public types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SetupPath {
  Local,
  Server,
  Client,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SetupOptions {
  pub path: Option<SetupPath>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExposureMode {
  Cloudflare,
  Tailscale,
  ReverseProxy,
  Direct,
}

impl ExposureMode {
  #[cfg(test)]
  fn desired_bind(self) -> SocketAddr {
    match self {
      Self::Cloudflare | Self::ReverseProxy => "127.0.0.1:4000".parse().unwrap(),
      Self::Tailscale | Self::Direct => "0.0.0.0:4000".parse().unwrap(),
    }
  }
}

// ── Existing-state detection ────────────────────────────────────────────────

#[derive(Debug)]
struct ExistingState {
  db_exists: bool,
  service_installed: bool,
  service_bind: Option<SocketAddr>,
  hooks_installed: bool,
  active_token_count: i64,
}

impl ExistingState {
  fn is_configured(&self) -> bool {
    self.db_exists
  }
}

fn detect_existing_state() -> ExistingState {
  let db_exists = paths::db_path().exists();

  let (service_installed, service_bind) = match detect_service_state() {
    Ok(state) => (state.installed, state.bind),
    Err(_) => (false, None),
  };

  let hooks_installed = check_hooks_installed();

  let active_token_count = if db_exists {
    auth_tokens::active_token_count().unwrap_or(0)
  } else {
    0
  };

  ExistingState {
    db_exists,
    service_installed,
    service_bind,
    hooks_installed,
    active_token_count,
  }
}

fn check_hooks_installed() -> bool {
  let settings_path = dirs::home_dir()
    .map(|h| h.join(".claude/settings.json"))
    .unwrap_or_default();
  if !settings_path.exists() {
    return false;
  }
  let content = fs::read_to_string(&settings_path).unwrap_or_default();
  content.contains("orbitdock") || content.contains("hook-forward")
}

fn show_existing_state(state: &ExistingState) {
  println!("  Existing installation detected:");
  println!();
  if state.service_installed {
    let bind = state
      .service_bind
      .map(|b| b.to_string())
      .unwrap_or_else(|| "unknown".into());
    println!("    Service:  running (bind {})", bind);
  } else {
    println!("    Service:  not installed");
  }
  println!(
    "    Hooks:    {}",
    if state.hooks_installed {
      "installed"
    } else {
      "not installed"
    }
  );
  println!("    Tokens:   {} active", state.active_token_count);
  println!();
}

// ── Service state detection ──────────────────────────────────────────────────

#[derive(Debug)]
struct ServiceState {
  installed: bool,
  bind: Option<SocketAddr>,
}

fn detect_service_state() -> anyhow::Result<ServiceState> {
  let path = service_file_path();
  if !path.exists() {
    return Ok(ServiceState {
      installed: false,
      bind: None,
    });
  }

  let content = fs::read_to_string(&path)?;
  let bind = if cfg!(target_os = "macos") {
    parse_launchd_bind(&content)
  } else {
    parse_systemd_bind(&content)
  };

  Ok(ServiceState {
    installed: true,
    bind,
  })
}

fn service_file_path() -> PathBuf {
  let home = dirs::home_dir().expect("HOME not found");
  if cfg!(target_os = "macos") {
    home.join("Library/LaunchAgents/com.orbitdock.server.plist")
  } else {
    home.join(".config/systemd/user/orbitdock-server.service")
  }
}

fn parse_launchd_bind(content: &str) -> Option<SocketAddr> {
  let lines = content.lines().collect::<Vec<_>>();
  for window in lines.windows(3) {
    if window[0].contains("<string>--bind</string>") {
      let raw = strip_string_tag(window[1])?;
      return raw.parse().ok();
    }
  }
  None
}

fn parse_systemd_bind(content: &str) -> Option<SocketAddr> {
  let exec_line = content
    .lines()
    .find(|line| line.trim_start().starts_with("ExecStart="))?;
  let bind_flag = exec_line.find("--bind")?;
  let after_flag = &exec_line[bind_flag + "--bind".len()..];
  let bind_value = after_flag.split_whitespace().next()?;
  bind_value.parse().ok()
}

fn strip_string_tag(line: &str) -> Option<&str> {
  let trimmed = line.trim();
  let start = trimmed.strip_prefix("<string>")?;
  start.strip_suffix("</string>")
}

// ── Tailscale detection (delegates to init::detect_tailscale_ip) ─────────────

fn detect_tailscale_url() -> Option<String> {
  init::detect_tailscale_ip().map(|ip| format!("http://{}:4000", ip))
}

// ── Prompts ─────────────────────────────────────────────────────────────────

fn prompt_yes_no(prompt: &str, default_yes: bool) -> anyhow::Result<bool> {
  loop {
    print!("  {} ", prompt);
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let trimmed = input.trim();

    if trimmed.is_empty() {
      return Ok(default_yes);
    }

    match trimmed.to_ascii_lowercase().as_str() {
      "y" | "yes" => return Ok(true),
      "n" | "no" => return Ok(false),
      _ => println!("  Please answer y or n."),
    }
  }
}

fn prompt_input(prompt: &str) -> anyhow::Result<String> {
  print!("  {}", prompt);
  io::stdout().flush()?;

  let mut input = String::new();
  io::stdin().lock().read_line(&mut input)?;
  Ok(input.trim().to_string())
}

fn prompt_setup_path() -> anyhow::Result<SetupPath> {
  println!("  How will you use this machine?");
  println!();
  println!("    1) Local   — server + Claude Code on this machine");
  println!("    2) Server  — other devices connect to this machine");
  println!("    3) Client  — connect to an existing OrbitDock server");
  println!();

  loop {
    print!("  Choice [1]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;

    match input.trim() {
      "" | "1" | "local" => return Ok(SetupPath::Local),
      "2" | "server" => return Ok(SetupPath::Server),
      "3" | "client" => return Ok(SetupPath::Client),
      _ => println!("  Please choose 1, 2, or 3."),
    }
  }
}

fn prompt_exposure_mode() -> anyhow::Result<ExposureMode> {
  println!("  How should other devices reach this server?");
  println!();
  println!("    1) Cloudflare Tunnel (recommended, free)");
  println!("    2) Tailscale");
  println!("    3) Existing HTTPS reverse proxy");
  println!("    4) Direct bind / LAN / public IP (advanced)");
  println!();

  loop {
    print!("  Choice [1]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;

    match input.trim() {
      "" | "1" | "cloudflare" => return Ok(ExposureMode::Cloudflare),
      "2" | "tailscale" => return Ok(ExposureMode::Tailscale),
      "3" | "proxy" | "reverse-proxy" => return Ok(ExposureMode::ReverseProxy),
      "4" | "direct" | "lan" => return Ok(ExposureMode::Direct),
      _ => println!("  Please choose 1, 2, 3, or 4."),
    }
  }
}

// ── Entry point ─────────────────────────────────────────────────────────────

pub fn run_setup_wizard(data_dir: &Path, opts: SetupOptions) -> anyhow::Result<()> {
  println!();
  println!("  OrbitDock Setup");
  println!("  ══════════════");
  println!();

  let path = match opts.path {
    Some(p) => p,
    None => prompt_setup_path()?,
  };

  // Re-run detection (skip for client — it only installs hooks)
  if path != SetupPath::Client {
    let existing = detect_existing_state();
    if existing.is_configured() {
      show_existing_state(&existing);
      if !prompt_yes_no("Reconfigure? [y/N]", false)? {
        println!("  Keeping existing configuration.");
        return Ok(());
      }

      if existing.active_token_count > 0
        && prompt_yes_no(
          &format!(
            "Revoke {} existing auth token(s) before generating new ones? [y/N]",
            existing.active_token_count
          ),
          false,
        )?
      {
        auth_tokens::revoke_all_tokens()?;
        println!("  Revoked {} token(s).", existing.active_token_count);
      }
      println!();
    }
  }

  // Set installer mode so init/hooks suppress verbose output
  std::env::set_var("ORBITDOCK_INSTALLER_MODE", "1");
  let result = match path {
    SetupPath::Local => run_local_setup(data_dir),
    SetupPath::Server => run_server_setup(data_dir),
    SetupPath::Client => run_client_setup(),
  };
  std::env::remove_var("ORBITDOCK_INSTALLER_MODE");

  result
}

// ── Local path ──────────────────────────────────────────────────────────────

fn run_local_setup(data_dir: &Path) -> anyhow::Result<()> {
  println!();
  println!("  Setting up OrbitDock locally...");
  println!();

  print!("  Initializing... ");
  io::stdout().flush()?;
  init::initialize_data_dir(data_dir, "http://127.0.0.1:4000", Default::default())?;
  println!("done.");

  print!("  Installing Claude Code hooks... ");
  io::stdout().flush()?;
  install_hooks::install_claude_hooks(None, None, None)?;
  println!("done.");

  print!("  Starting background service... ");
  io::stdout().flush()?;
  install_service::install_background_service(
    data_dir,
    "0.0.0.0:4000".parse().unwrap(),
    true,
    None,
  )?;
  println!("done.");

  println!();
  println!("  ══════════════════════════════════════════");
  println!("  Setup complete! OrbitDock is running.");
  println!("  ══════════════════════════════════════════");
  println!();
  println!("  Health:    http://127.0.0.1:4000/health");
  println!("  Dashboard: http://127.0.0.1:4000");
  println!();
  println!("  Claude Code sessions will auto-report to this server.");
  println!();

  Ok(())
}

// ── Server path ─────────────────────────────────────────────────────────────

fn run_server_setup(data_dir: &Path) -> anyhow::Result<()> {
  println!();
  let exposure = prompt_exposure_mode()?;

  print!("  Initializing... ");
  io::stdout().flush()?;
  init::initialize_data_dir(data_dir, "http://127.0.0.1:4000", Default::default())?;
  println!("done.");

  match exposure {
    ExposureMode::Cloudflare => run_cloudflare_setup(data_dir),
    ExposureMode::Tailscale => run_tailscale_setup(data_dir),
    ExposureMode::ReverseProxy => run_reverse_proxy_setup(data_dir),
    ExposureMode::Direct => run_direct_setup(data_dir),
  }
}

fn run_cloudflare_setup(data_dir: &Path) -> anyhow::Result<()> {
  println!();
  tunnel::ensure_cloudflared()?;

  let token = start_service_and_issue_token(data_dir, "127.0.0.1:4000")?;

  println!();
  println!("  Starting Cloudflare tunnel...");
  let (tunnel_child, tunnel_url) = tunnel::start_tunnel_and_extract_url(4000)?;

  print_token_banner(Some(&tunnel_url), &token, None);
  prompt_and_install_local_hooks(Some(&token))?;
  print_client_instructions(&tunnel_url);
  let _ = pair::print_pairing_details(Some(&tunnel_url), true);

  println!("  This is a temporary quick tunnel.");
  println!("  For a persistent URL, use a named Cloudflare tunnel:");
  println!("    cloudflared tunnel create orbitdock");
  println!("    orbitdock tunnel --name orbitdock");
  println!();
  println!("  Press Ctrl+C to stop the tunnel.");

  let _ = tunnel_child.wait_with_output();

  Ok(())
}

fn run_tailscale_setup(data_dir: &Path) -> anyhow::Result<()> {
  println!();
  let ts_url = match detect_tailscale_url() {
    Some(url) => {
      println!("  Tailscale detected: {}", url);
      url
    }
    None => {
      println!("  Tailscale not detected.");
      println!();
      println!("  Install Tailscale first:");
      println!("    macOS:  brew install --cask tailscale");
      println!("    Linux:  curl -fsSL https://tailscale.com/install.sh | sh");
      println!();
      println!("  Then run: tailscale up");
      println!("  And re-run: orbitdock setup server");
      return Ok(());
    }
  };

  let token = start_service_and_issue_token(data_dir, "0.0.0.0:4000")?;
  print_token_banner(Some(&ts_url), &token, None);
  prompt_and_install_local_hooks(Some(&token))?;
  print_client_instructions(&ts_url);
  let _ = pair::print_pairing_details(Some(&ts_url), true);

  Ok(())
}

fn run_reverse_proxy_setup(data_dir: &Path) -> anyhow::Result<()> {
  let token = start_service_and_issue_token(data_dir, "127.0.0.1:4000")?;
  print_token_banner(None, &token, None);

  println!("  Point your reverse proxy (nginx, Caddy, etc.) at:");
  println!("    http://127.0.0.1:4000");
  println!();

  prompt_and_install_local_hooks(Some(&token))?;

  println!();
  println!("  Once your proxy is configured, connect clients:");
  println!("    orbitdock setup client");
  println!();

  Ok(())
}

fn run_direct_setup(data_dir: &Path) -> anyhow::Result<()> {
  let token = start_service_and_issue_token(data_dir, "0.0.0.0:4000")?;
  print_token_banner(None, &token, Some("Bind:        0.0.0.0:4000"));

  println!("  Make sure port 4000 is reachable from your network.");

  prompt_and_install_local_hooks(Some(&token))?;

  println!();
  println!("  Connect clients using this machine's IP:");
  println!("    orbitdock setup client");
  println!();

  Ok(())
}

// ── Client path ─────────────────────────────────────────────────────────────

fn run_client_setup() -> anyhow::Result<()> {
  println!();
  println!("  Connect to an existing OrbitDock server.");
  println!();

  let server_url = prompt_input("Server URL: ")?;
  if server_url.is_empty() {
    anyhow::bail!("Server URL is required.");
  }

  let auth_token = prompt_input("Auth token: ")?;
  if auth_token.is_empty() {
    anyhow::bail!("Auth token is required.");
  }

  // Test connection
  print!("  Testing connection... ");
  io::stdout().flush()?;
  let health_url = format!("{}/health", server_url.trim_end_matches('/'));
  match test_remote_health(&health_url) {
    Ok(()) => println!("OK"),
    Err(e) => {
      println!("FAILED");
      println!();
      println!("  Could not reach {}", health_url);
      println!("  Error: {}", e);
      println!();
      println!("  Check that the server is running and the URL is correct.");
      return Err(e);
    }
  }

  // Install hooks
  print!("  Installing Claude Code hooks... ");
  io::stdout().flush()?;
  install_hooks::install_claude_hooks(None, Some(&server_url), Some(&auth_token))?;
  println!("done.");

  println!();
  println!("  ══════════════════════════════════════════");
  println!("  Connected to {}", server_url);
  println!("  ══════════════════════════════════════════");
  println!();
  println!("  Claude Code sessions will forward events to this server.");
  println!();

  Ok(())
}

fn test_remote_health(url: &str) -> anyhow::Result<()> {
  let output = Command::new("curl")
    .args(["-fsSL", "--max-time", "5", url])
    .output()
    .map_err(|e| anyhow::anyhow!("curl not found or failed to start: {}", e))?;

  if !output.status.success() {
    anyhow::bail!("health check failed (server returned an error)");
  }
  Ok(())
}

// ── Shared helpers ──────────────────────────────────────────────────────────

fn start_service_and_issue_token(data_dir: &Path, bind: &str) -> anyhow::Result<String> {
  println!();
  print!("  Starting background service (bind {})... ", bind);
  io::stdout().flush()?;
  install_service::install_background_service(data_dir, bind.parse().unwrap(), true, None)?;
  println!("done.");

  println!();
  status::issue_auth_token(data_dir)
}

fn print_token_banner(url: Option<&str>, token: &str, extra: Option<&str>) {
  println!();
  println!("  ══════════════════════════════════════════");
  if let Some(url) = url {
    println!("  Server URL:  {}", url);
  }
  println!("  Auth token:  {}", token);
  if let Some(line) = extra {
    println!("  {}", line);
  }
  println!("  ══════════════════════════════════════════");
  println!();
  println!("  Copy the token now — it won't be shown again.");
  println!();
}

fn prompt_and_install_local_hooks(auth_token: Option<&str>) -> anyhow::Result<()> {
  let also_local = prompt_yes_no("Will Claude Code also run on this machine? [Y/n]", true)?;
  if also_local {
    print!("  Installing Claude Code hooks... ");
    io::stdout().flush()?;
    install_hooks::install_claude_hooks(None, Some("http://127.0.0.1:4000"), auth_token)?;
    println!("done.");
  }
  Ok(())
}

fn print_client_instructions(url: &str) {
  println!();
  println!("  Connect another machine:");
  println!("    orbitdock setup client");
  println!("    Server URL: {}", url);
  println!("    Auth token: use the token above");
  println!();
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn cloudflare_exposure_binds_localhost() {
    assert_eq!(
      ExposureMode::Cloudflare.desired_bind().to_string(),
      "127.0.0.1:4000"
    );
  }

  #[test]
  fn tailscale_exposure_binds_all_interfaces() {
    assert_eq!(
      ExposureMode::Tailscale.desired_bind().to_string(),
      "0.0.0.0:4000"
    );
  }

  #[test]
  fn reverse_proxy_exposure_binds_localhost() {
    assert_eq!(
      ExposureMode::ReverseProxy.desired_bind().to_string(),
      "127.0.0.1:4000"
    );
  }

  #[test]
  fn direct_exposure_binds_all_interfaces() {
    assert_eq!(
      ExposureMode::Direct.desired_bind().to_string(),
      "0.0.0.0:4000"
    );
  }

  #[test]
  fn parse_launchd_bind_reads_bind_address() {
    let content = r#"
        <string>start</string>
        <string>--bind</string>
        <string>127.0.0.1:4000</string>
        "#;
    let bind = parse_launchd_bind(content).expect("bind");
    assert_eq!(bind.to_string(), "127.0.0.1:4000");
  }

  #[test]
  fn parse_systemd_bind_reads_bind_address() {
    let content = r#"ExecStart=/Users/test/.orbitdock/bin/orbitdock start --bind 0.0.0.0:4000 --data-dir /Users/test/.orbitdock"#;
    let bind = parse_systemd_bind(content).expect("bind");
    assert_eq!(bind.to_string(), "0.0.0.0:4000");
  }
}
