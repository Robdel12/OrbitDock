use std::collections::HashSet;
use std::path::PathBuf;
#[cfg(target_os = "macos")]
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use codex_app_server_protocol::{
  Account as AppServerAccount, RateLimitReachedType as AppServerRateLimitReachedType,
  RateLimitWindow as AppServerRateLimitWindow,
};
use orbitdock_protocol::{
  ClaudeUsageSnapshot, ClaudeUsageWindow, CodexRateLimitReachedType, CodexRateLimitWindow,
  CodexUsageSnapshot, UsageErrorInfo,
};
#[cfg(target_os = "macos")]
use ring::digest::{digest, SHA256};
use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum UsageProbeError {
  #[error("Not logged into Codex")]
  NotLoggedIn,
  #[error("Using API key (no rate limits)")]
  ApiKeyMode,
  #[error("No Claude credentials found")]
  NoCredentials,
  #[error("Claude token expired")]
  TokenExpired,
  #[error("Token missing user:profile scope")]
  MissingScope,
  #[error("Unauthorized")]
  Unauthorized,
  #[error("Network error: {0}")]
  Network(String),
  #[error("Invalid API response")]
  InvalidResponse,
  #[error("{0}")]
  RequestFailed(String),
}

impl UsageProbeError {
  pub fn to_info(&self) -> UsageErrorInfo {
    UsageErrorInfo {
      code: self.code().to_string(),
      message: self.to_string(),
    }
  }

  fn code(&self) -> &'static str {
    match self {
      Self::NotLoggedIn => "not_logged_in",
      Self::ApiKeyMode => "api_key_mode",
      Self::NoCredentials => "no_credentials",
      Self::TokenExpired => "token_expired",
      Self::MissingScope => "missing_scope",
      Self::Unauthorized => "unauthorized",
      Self::Network(_) => "network_error",
      Self::InvalidResponse => "invalid_response",
      Self::RequestFailed(_) => "request_failed",
    }
  }
}

#[derive(Clone)]
struct ClaudeCredentials {
  token: String,
  rate_limit_tier: Option<String>,
}

pub async fn fetch_codex_usage() -> Result<CodexUsageSnapshot, UsageProbeError> {
  let cwd = dirs::home_dir()
    .unwrap_or_else(|| PathBuf::from("."))
    .to_string_lossy()
    .to_string();
  let app_server = orbitdock_connector_codex::app_server::shared_app_server_for_cwd(&cwd)
    .await
    .map_err(|err| UsageProbeError::RequestFailed(err.to_string()))?;

  let account = app_server
    .account_read(false)
    .await
    .map_err(|err| UsageProbeError::RequestFailed(format!("Auth check failed: {err}")))?;
  let Some(account) = account.account else {
    return Err(UsageProbeError::NotLoggedIn);
  };
  if matches!(account, AppServerAccount::ApiKey {}) {
    return Err(UsageProbeError::ApiKeyMode);
  }

  let rate_limits = app_server
    .account_rate_limits()
    .await
    .map_err(|err| UsageProbeError::RequestFailed(format!("Rate limits fetch failed: {err}")))?
    .rate_limits;

  Ok(CodexUsageSnapshot {
    primary: app_server_codex_limit(rate_limits.primary),
    secondary: app_server_codex_limit(rate_limits.secondary),
    rate_limit_reached_type: rate_limits
      .rate_limit_reached_type
      .map(app_server_rate_limit_reached_type),
    fetched_at_unix: unix_now(),
  })
}

pub async fn fetch_claude_usage() -> Result<ClaudeUsageSnapshot, UsageProbeError> {
  let credentials = load_claude_credentials()?;
  let client = reqwest::Client::builder()
    .timeout(Duration::from_secs(15))
    .build()
    .map_err(|err| UsageProbeError::RequestFailed(format!("Failed to build HTTP client: {err}")))?;

  let response = client
    .get("https://api.anthropic.com/api/oauth/usage")
    .header("Authorization", format!("Bearer {}", credentials.token))
    .header("Accept", "application/json")
    .header("anthropic-beta", "oauth-2025-04-20")
    .header("User-Agent", "OrbitDock/1.0")
    .send()
    .await
    .map_err(|err| UsageProbeError::Network(err.to_string()))?;

  let status = response.status();
  match status.as_u16() {
    200 => {
      let json: Value = response
        .json()
        .await
        .map_err(|_| UsageProbeError::InvalidResponse)?;
      let five_hour = parse_claude_window(json.get("five_hour")).unwrap_or(ClaudeUsageWindow {
        utilization: 0.0,
        resets_at: None,
      });

      Ok(ClaudeUsageSnapshot {
        five_hour,
        seven_day: parse_claude_window(json.get("seven_day")),
        seven_day_sonnet: parse_claude_window(json.get("seven_day_sonnet")),
        seven_day_opus: parse_claude_window(json.get("seven_day_opus")),
        rate_limit_tier: credentials.rate_limit_tier,
        fetched_at_unix: unix_now(),
      })
    }
    401 => Err(UsageProbeError::Unauthorized),
    _ => {
      let detail = response.text().await.unwrap_or_default();
      let message = if detail.trim().is_empty() {
        format!("Claude usage API returned HTTP {}", status.as_u16())
      } else {
        format!(
          "Claude usage API returned HTTP {}: {}",
          status.as_u16(),
          truncate_for_error(&detail, 240)
        )
      };
      Err(UsageProbeError::RequestFailed(message))
    }
  }
}

fn app_server_codex_limit(value: Option<AppServerRateLimitWindow>) -> Option<CodexRateLimitWindow> {
  let value = value?;
  Some(CodexRateLimitWindow {
    used_percent: f64::from(value.used_percent),
    window_duration_mins: value
      .window_duration_mins
      .and_then(|mins| u32::try_from(mins).ok())
      .unwrap_or(0),
    resets_at_unix: value.resets_at.map(|ts| ts as f64).unwrap_or(0.0),
  })
}

fn app_server_rate_limit_reached_type(
  value: AppServerRateLimitReachedType,
) -> CodexRateLimitReachedType {
  match value {
    AppServerRateLimitReachedType::RateLimitReached => CodexRateLimitReachedType::RateLimitReached,
    AppServerRateLimitReachedType::WorkspaceOwnerCreditsDepleted => {
      CodexRateLimitReachedType::WorkspaceOwnerCreditsDepleted
    }
    AppServerRateLimitReachedType::WorkspaceMemberCreditsDepleted => {
      CodexRateLimitReachedType::WorkspaceMemberCreditsDepleted
    }
    AppServerRateLimitReachedType::WorkspaceOwnerUsageLimitReached => {
      CodexRateLimitReachedType::WorkspaceOwnerUsageLimitReached
    }
    AppServerRateLimitReachedType::WorkspaceMemberUsageLimitReached => {
      CodexRateLimitReachedType::WorkspaceMemberUsageLimitReached
    }
  }
}

fn parse_claude_window(value: Option<&Value>) -> Option<ClaudeUsageWindow> {
  let value = value?.as_object()?;
  let utilization = value_to_f64(value.get("utilization"))?;
  let resets_at = value
    .get("resets_at")
    .and_then(Value::as_str)
    .map(str::to_string);
  Some(ClaudeUsageWindow {
    utilization,
    resets_at,
  })
}

fn value_to_f64(value: Option<&Value>) -> Option<f64> {
  let value = value?;
  if let Some(v) = value.as_f64() {
    return Some(v);
  }
  if let Some(v) = value.as_i64() {
    return Some(v as f64);
  }
  if let Some(v) = value.as_u64() {
    return Some(v as f64);
  }
  value.as_str().and_then(|v| v.parse::<f64>().ok())
}

fn unix_now() -> f64 {
  match SystemTime::now().duration_since(UNIX_EPOCH) {
    Ok(duration) => duration.as_secs_f64(),
    Err(_) => 0.0,
  }
}

fn load_claude_credentials() -> Result<ClaudeCredentials, UsageProbeError> {
  if let Ok(token) = std::env::var("ORBITDOCK_CLAUDE_ACCESS_TOKEN") {
    let trimmed = token.trim();
    if !trimmed.is_empty() {
      let tier = std::env::var("ORBITDOCK_CLAUDE_RATE_LIMIT_TIER")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
      return Ok(ClaudeCredentials {
        token: trimmed.to_string(),
        rate_limit_tier: tier,
      });
    }
  }

  load_claude_credentials_from_keychain()
}

#[cfg(target_os = "macos")]
fn load_claude_credentials_from_keychain() -> Result<ClaudeCredentials, UsageProbeError> {
  let account = std::env::var("USER")
    .ok()
    .map(|value| value.trim().to_string())
    .filter(|value| !value.is_empty());

  for service in claude_keychain_service_candidates() {
    let value = read_keychain_json_for_service(&service, account.as_deref())
      .or_else(|| read_keychain_json_for_service(&service, None));
    let Some(value) = value else {
      continue;
    };
    match parse_claude_credentials_from_value(&value) {
      Ok(credentials) => return Ok(credentials),
      Err(UsageProbeError::NoCredentials) => continue,
      Err(err) => return Err(err),
    }
  }

  Err(UsageProbeError::NoCredentials)
}

#[cfg(target_os = "macos")]
fn parse_claude_credentials_from_value(
  value: &Value,
) -> Result<ClaudeCredentials, UsageProbeError> {
  let oauth = value
    .get("claudeAiOauth")
    .and_then(Value::as_object)
    .ok_or(UsageProbeError::NoCredentials)?;

  let token = oauth
    .get("accessToken")
    .and_then(Value::as_str)
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .ok_or(UsageProbeError::NoCredentials)?
    .to_string();

  if let Some(expires_at_ms) = oauth
    .get("expiresAt")
    .and_then(|value| value_to_f64(Some(value)))
  {
    let expires_at_unix = expires_at_ms / 1_000.0;
    if unix_now() >= expires_at_unix {
      return Err(UsageProbeError::TokenExpired);
    }
  }

  let has_scope = oauth
    .get("scopes")
    .and_then(Value::as_array)
    .map(|scopes| {
      scopes
        .iter()
        .filter_map(Value::as_str)
        .any(|scope| scope == "user:profile")
    })
    .unwrap_or(false);
  if !has_scope {
    return Err(UsageProbeError::MissingScope);
  }

  let rate_limit_tier = oauth
    .get("rateLimitTier")
    .and_then(Value::as_str)
    .map(str::to_string);

  Ok(ClaudeCredentials {
    token,
    rate_limit_tier,
  })
}

#[cfg(target_os = "macos")]
fn read_keychain_json_for_service(service: &str, account: Option<&str>) -> Option<Value> {
  let mut args = vec!["find-generic-password", "-s", service];
  if let Some(account) = account {
    args.push("-a");
    args.push(account);
  }
  args.push("-w");

  let output = std::process::Command::new("/usr/bin/security")
    .args(args)
    .stderr(Stdio::null())
    .output()
    .ok()?;

  if !output.status.success() {
    return None;
  }

  serde_json::from_slice::<Value>(&output.stdout).ok()
}

#[cfg(target_os = "macos")]
fn claude_keychain_service_candidates() -> Vec<String> {
  let mut candidates = Vec::new();
  let oauth_suffixes = ["", "-custom-oauth", "-staging-oauth", "-local-oauth"];
  let hashed_suffix = claude_keychain_hash_suffix();

  for oauth_suffix in oauth_suffixes {
    let base = format!("Claude Code{oauth_suffix}-credentials");
    if let Some(ref hash) = hashed_suffix {
      candidates.push(format!("{base}{hash}"));
    }
    candidates.push(base);
  }

  let mut deduped = Vec::new();
  let mut seen = HashSet::new();
  for candidate in candidates {
    if seen.insert(candidate.clone()) {
      deduped.push(candidate);
    }
  }
  deduped
}

#[cfg(target_os = "macos")]
fn claude_keychain_hash_suffix() -> Option<String> {
  if std::env::var_os("CLAUDE_CONFIG_DIR").is_some() {
    return None;
  }
  let config_dir = claude_config_dir()?;
  let hash = sha256_hex(config_dir.to_string_lossy().as_ref());
  let prefix = &hash[..8.min(hash.len())];
  Some(format!("-{prefix}"))
}

#[cfg(target_os = "macos")]
fn claude_config_dir() -> Option<PathBuf> {
  if let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR") {
    return Some(PathBuf::from(dir));
  }
  dirs::home_dir().map(|home| home.join(".claude"))
}

#[cfg(target_os = "macos")]
fn sha256_hex(input: &str) -> String {
  let bytes = digest(&SHA256, input.as_bytes());
  let mut result = String::with_capacity(bytes.as_ref().len() * 2);
  for byte in bytes.as_ref() {
    use std::fmt::Write as _;
    let _ = write!(&mut result, "{byte:02x}");
  }
  result
}

fn truncate_for_error(value: &str, max_chars: usize) -> String {
  let trimmed = value.trim();
  if trimmed.chars().count() <= max_chars {
    return trimmed.to_string();
  }
  let mut result = String::new();
  for ch in trimmed.chars().take(max_chars) {
    result.push(ch);
  }
  result.push('…');
  result
}

#[cfg(not(target_os = "macos"))]
fn load_claude_credentials_from_keychain() -> Result<ClaudeCredentials, UsageProbeError> {
  Err(UsageProbeError::NoCredentials)
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn maps_codex_rate_limit_reached_type_from_app_server() {
    let value = AppServerRateLimitReachedType::WorkspaceMemberUsageLimitReached;

    assert_eq!(
      app_server_rate_limit_reached_type(value),
      CodexRateLimitReachedType::WorkspaceMemberUsageLimitReached
    );
  }

  #[test]
  fn maps_codex_rate_limit_window_from_app_server() {
    let value = AppServerRateLimitWindow {
      used_percent: 42,
      window_duration_mins: Some(300),
      resets_at: Some(1_710_000_000),
    };

    let mapped = app_server_codex_limit(Some(value)).expect("rate limit window");

    assert_eq!(mapped.used_percent, 42.0);
    assert_eq!(mapped.window_duration_mins, 300);
    assert_eq!(mapped.resets_at_unix, 1_710_000_000.0);
  }

  #[test]
  fn defaults_missing_codex_rate_limit_window_fields() {
    let value = AppServerRateLimitWindow {
      used_percent: 7,
      window_duration_mins: None,
      resets_at: None,
    };

    let mapped = app_server_codex_limit(Some(value)).expect("rate limit window");

    assert_eq!(mapped.used_percent, 7.0);
    assert_eq!(mapped.window_duration_mins, 0);
    assert_eq!(mapped.resets_at_unix, 0.0);
  }
}
