use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use orbitdock_protocol::{
    ClaudeUsageSnapshot, ClaudeUsageWindow, CodexRateLimitWindow, CodexUsageSnapshot,
    UsageErrorInfo,
};
#[cfg(target_os = "macos")]
use ring::digest::{digest, SHA256};
use serde_json::Value;
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdout, Command};

const SENTINEL_PATH: &str = "__ORBITDOCK_PATH__";

#[derive(Debug, Error)]
pub enum UsageProbeError {
    #[error("Codex CLI not installed")]
    NotInstalled,
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
            Self::NotInstalled => "not_installed",
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
    let codex_path = find_codex_binary().ok_or(UsageProbeError::NotInstalled)?;
    let path_env = resolved_path_env_for_binary(&codex_path);

    let mut command = Command::new(&codex_path);
    command.arg("app-server");
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::null());
    if let Some(home) = dirs::home_dir() {
        command.current_dir(home);
    }
    if let Some(path_env) = path_env {
        command.env("PATH", path_env);
    }

    let mut child = command
        .spawn()
        .map_err(|err| UsageProbeError::RequestFailed(format!("Failed to start codex: {err}")))?;

    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill().await;
        return Err(UsageProbeError::RequestFailed(
            "Failed to open codex stdin".to_string(),
        ));
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill().await;
        return Err(UsageProbeError::RequestFailed(
            "Failed to open codex stdout".to_string(),
        ));
    };
    let mut lines = BufReader::new(stdout).lines();

    let result = async {
        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method":"initialize",
                "id":1,
                "params":{"clientInfo":{"name":"orbitdock","title":"OrbitDock","version":"1.0.0"}}
            }),
        )
        .await?;
        let init_response = read_json_rpc_response(&mut lines, 1).await?;
        if init_response.get("error").is_some() {
            return Err(UsageProbeError::RequestFailed(
                "Initialize failed".to_string(),
            ));
        }

        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method":"initialized",
                "params":{}
            }),
        )
        .await?;

        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method":"account/read",
                "id":2,
                "params":{"refreshToken":false}
            }),
        )
        .await?;
        let auth_response = read_json_rpc_response(&mut lines, 2).await?;
        if auth_response.get("error").is_some() {
            return Err(UsageProbeError::RequestFailed(
                "Auth check failed".to_string(),
            ));
        }
        let auth_result = auth_response
            .get("result")
            .and_then(Value::as_object)
            .ok_or(UsageProbeError::RequestFailed(
                "Auth check failed".to_string(),
            ))?;

        let account_value = auth_result
            .get("account")
            .ok_or(UsageProbeError::NotLoggedIn)?;
        if account_value.is_null() {
            return Err(UsageProbeError::NotLoggedIn);
        }
        if account_value
            .get("type")
            .and_then(Value::as_str)
            .map(|value| value.eq_ignore_ascii_case("apikey"))
            .unwrap_or(false)
        {
            return Err(UsageProbeError::ApiKeyMode);
        }

        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method":"account/rateLimits/read",
                "id":3
            }),
        )
        .await?;
        let limits_response = read_json_rpc_response(&mut lines, 3).await?;
        if limits_response.get("error").is_some() {
            return Err(UsageProbeError::RequestFailed(
                "Rate limits fetch failed".to_string(),
            ));
        }
        let rate_limits = limits_response
            .get("result")
            .and_then(Value::as_object)
            .and_then(|result| result.get("rateLimits"))
            .and_then(Value::as_object)
            .ok_or(UsageProbeError::RequestFailed(
                "Rate limits fetch failed".to_string(),
            ))?;

        Ok(CodexUsageSnapshot {
            primary: parse_codex_limit(rate_limits.get("primary")),
            secondary: parse_codex_limit(rate_limits.get("secondary")),
            fetched_at_unix: unix_now(),
        })
    }
    .await;

    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

pub async fn fetch_claude_usage() -> Result<ClaudeUsageSnapshot, UsageProbeError> {
    let credentials = load_claude_credentials()?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|err| {
            UsageProbeError::RequestFailed(format!("Failed to build HTTP client: {err}"))
        })?;

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
            let five_hour =
                parse_claude_window(json.get("five_hour")).unwrap_or(ClaudeUsageWindow {
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

fn parse_codex_limit(value: Option<&Value>) -> Option<CodexRateLimitWindow> {
    let value = value?.as_object()?;
    let used_percent = value_to_f64(value.get("usedPercent"))?;
    let window_duration_mins = value
        .get("windowDurationMins")
        .and_then(value_to_u32)
        .unwrap_or(0);
    let resets_at_unix = value_to_f64(value.get("resetsAt"))?;
    Some(CodexRateLimitWindow {
        used_percent,
        window_duration_mins,
        resets_at_unix,
    })
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

fn value_to_u32(value: &Value) -> Option<u32> {
    if let Some(v) = value.as_u64() {
        return u32::try_from(v).ok();
    }
    if let Some(v) = value.as_i64() {
        return u32::try_from(v).ok();
    }
    value.as_str().and_then(|v| v.parse::<u32>().ok())
}

fn unix_now() -> f64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs_f64(),
        Err(_) => 0.0,
    }
}

async fn send_json_rpc(
    stdin: &mut tokio::process::ChildStdin,
    payload: Value,
) -> Result<(), UsageProbeError> {
    let mut bytes = serde_json::to_vec(&payload).map_err(|err| {
        UsageProbeError::RequestFailed(format!("Invalid JSON-RPC payload: {err}"))
    })?;
    bytes.push(b'\n');
    stdin.write_all(&bytes).await.map_err(|err| {
        UsageProbeError::RequestFailed(format!("Failed to write to codex stdin: {err}"))
    })?;
    stdin.flush().await.map_err(|err| {
        UsageProbeError::RequestFailed(format!("Failed to flush codex stdin: {err}"))
    })?;
    Ok(())
}

async fn read_json_rpc_response(
    lines: &mut tokio::io::Lines<BufReader<ChildStdout>>,
    expected_id: i64,
) -> Result<Value, UsageProbeError> {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
            .await
            .map_err(|_| {
                UsageProbeError::RequestFailed("Timed out waiting for codex response".to_string())
            })?
            .map_err(|err| {
                UsageProbeError::RequestFailed(format!("Failed reading codex output: {err}"))
            })?;

        let Some(line) = line else {
            return Err(UsageProbeError::RequestFailed(
                "Codex app-server exited unexpectedly".to_string(),
            ));
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let value: Value = serde_json::from_str(trimmed).map_err(|err| {
            UsageProbeError::RequestFailed(format!("Invalid codex response: {err}"))
        })?;
        let id = value.get("id").and_then(Value::as_i64);
        if id == Some(expected_id) {
            return Ok(value);
        }
    }
}

fn find_codex_binary() -> Option<PathBuf> {
    if let Ok(value) = std::env::var("ORBITDOCK_CODEX_PATH") {
        let path = PathBuf::from(value);
        if is_executable_file(&path) {
            return Some(path);
        }
    }

    for path in [
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/bin/codex",
        "/bin/codex",
    ] {
        let candidate = PathBuf::from(path);
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }

    let mut checked = HashSet::new();
    for directory in resolve_path_entries() {
        if !checked.insert(directory.clone()) {
            continue;
        }
        let candidate = directory.join("codex");
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }

    None
}

fn resolved_path_env_for_binary(binary_path: &Path) -> Option<String> {
    let mut entries = Vec::new();
    if let Some(parent) = binary_path.parent() {
        entries.push(parent.to_string_lossy().to_string());
    }
    for path in resolve_path_entries() {
        entries.push(path.to_string_lossy().to_string());
    }
    dedup_non_empty(entries)
}

fn resolve_path_entries() -> Vec<PathBuf> {
    let mut entries = Vec::new();
    if let Some(env_path) = std::env::var_os("PATH") {
        entries.extend(std::env::split_paths(&env_path));
    }
    if let Some(shell_path) = probe_login_shell_path() {
        entries.extend(std::env::split_paths(&shell_path));
    }
    entries
}

fn probe_login_shell_path() -> Option<String> {
    let shell = resolve_shell_binary();
    let command = format!("printf '{}%s\\n' \"$PATH\"", SENTINEL_PATH);

    let candidates = [
        vec!["-ilc".to_string(), command.clone()],
        vec!["-lc".to_string(), command.clone()],
        vec!["-c".to_string(), command],
    ];

    for args in candidates {
        let output = match std::process::Command::new(&shell)
            .args(args)
            .stderr(Stdio::null())
            .output()
        {
            Ok(output) => output,
            Err(_) => continue,
        };
        if !output.status.success() {
            continue;
        }
        let text = match String::from_utf8(output.stdout) {
            Ok(text) => text,
            Err(_) => continue,
        };
        if let Some(path) = extract_probe_path(&text) {
            return Some(path);
        }
    }

    None
}

fn extract_probe_path(output: &str) -> Option<String> {
    let start = output.rfind(SENTINEL_PATH)?;
    let path = &output[start + SENTINEL_PATH.len()..];
    let first_line = path.lines().next()?.trim();
    if first_line.is_empty() {
        None
    } else {
        Some(first_line.to_string())
    }
}

fn resolve_shell_binary() -> String {
    if let Ok(shell) = std::env::var("SHELL") {
        if is_executable_file(Path::new(&shell)) {
            return shell;
        }
    }
    for fallback in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
        if is_executable_file(Path::new(fallback)) {
            return fallback.to_string();
        }
    }
    "/bin/sh".to_string()
}

fn dedup_non_empty(values: Vec<String>) -> Option<String> {
    let mut seen = HashSet::new();
    let mut deduped = Vec::new();

    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        if seen.insert(trimmed.to_string()) {
            deduped.push(trimmed.to_string());
        }
    }

    if deduped.is_empty() {
        None
    } else {
        Some(deduped.join(":"))
    }
}

fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|meta| meta.is_file())
        .unwrap_or(false)
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
