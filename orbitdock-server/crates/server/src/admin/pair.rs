//! `orbitdock pair` — generate a connection URL for clients.

use crate::infrastructure::auth_tokens;

struct TokenState {
  env_token_prefix: Option<String>,
  active_db_tokens: u32,
}

struct PairingInfo {
  base_url: String,
  pair_url: String,
  uses_tls: bool,
  token_summary: String,
  requires_separate_token: bool,
  hook_install_command: String,
}

pub fn print_pairing_details(tunnel_url: Option<&str>) -> anyhow::Result<()> {
  let token_state = TokenState {
    env_token_prefix: std::env::var("ORBITDOCK_AUTH_TOKEN")
      .ok()
      .map(|s| s.trim().to_string())
      .filter(|s| !s.is_empty())
      .map(|token| token[..8.min(token.len())].to_string()),
    active_db_tokens: auth_tokens::active_token_count()
      .unwrap_or(0)
      .try_into()
      .unwrap_or(0),
  };
  let base_url = detect_base_url(tunnel_url)?;
  let info = build_pairing_info(&base_url, &token_state);

  render_pairing_details(&info)
}

fn detect_base_url(tunnel_url: Option<&str>) -> anyhow::Result<String> {
  if let Some(url) = tunnel_url {
    return Ok(url.to_string());
  }

  let health_ok = std::process::Command::new("curl")
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
    .unwrap_or(false);

  if health_ok {
    Ok("http://127.0.0.1:4000".to_string())
  } else {
    anyhow::bail!(
      "Cannot detect server URL. Either:\n\
             - Start the server: orbitdock start\n\
             - Provide a tunnel URL: orbitdock pair --tunnel-url https://..."
    );
  }
}

fn build_pairing_info(base_url: &str, token_state: &TokenState) -> PairingInfo {
  let normalized_base_url = base_url.trim_end_matches('/').to_string();
  let uses_tls = normalized_base_url.starts_with("https://");
  let host = normalized_base_url
    .trim_start_matches("https://")
    .trim_start_matches("http://");

  let pair_url = if uses_tls {
    format!("orbitdock://{}?tls=1", host)
  } else {
    format!("orbitdock://{}", host)
  };

  let token_summary = if let Some(prefix) = token_state.env_token_prefix.as_deref() {
    format!("{}...", prefix)
  } else if token_state.active_db_tokens > 0 {
    format!(
      "required ({} active database token(s))",
      token_state.active_db_tokens
    )
  } else {
    "(none — server accepts unauthenticated requests)".to_string()
  };

  PairingInfo {
    base_url: normalized_base_url.clone(),
    pair_url,
    uses_tls,
    token_summary,
    requires_separate_token: token_state.env_token_prefix.is_some()
      || token_state.active_db_tokens > 0,
    hook_install_command: format!(
      "orbitdock install-hooks --server-url {}",
      normalized_base_url
    ),
  }
}

fn render_pairing_details(info: &PairingInfo) -> anyhow::Result<()> {
  println!();
  println!("  OrbitDock Pairing");
  println!("  ─────────────────");
  println!();
  println!("  Server:  {}", info.base_url);
  println!("  TLS:     {}", if info.uses_tls { "yes" } else { "no" });
  println!("  Token:   {}", info.token_summary);
  println!();
  println!("  Connection URL:");
  println!("    {}", info.pair_url);
  println!();
  println!("  Connect another machine:");
  println!("    orbitdock setup client");
  println!("    Server URL: {}", info.base_url);
  if info.requires_separate_token {
    println!("    Auth token: enter it when prompted");
  } else {
    println!("    Auth token: not required");
  }
  println!();
  println!("  Install hooks on this machine, if needed:");
  println!("    {}", info.hook_install_command);
  if info.requires_separate_token {
    println!("    # Or set ORBITDOCK_AUTH_TOKEN first.");
    if std::env::var("ORBITDOCK_AUTH_TOKEN")
      .ok()
      .map(|s| !s.trim().is_empty())
      != Some(true)
    {
      println!("    # Create a new token if you don't already have one:");
      println!("    orbitdock generate-token");
    }
  }
  println!();

  Ok(())
}

#[cfg(test)]
#[path = "pair_tests.rs"]
mod tests;
