//! `orbitdock-server hook-forward` — internal Claude hook transport.
//!
//! Reads a Claude hook JSON payload from stdin, wraps it into an OrbitDock
//! client message (`type` field), POSTs it to `/api/hook`, and spools on
//! transient failures. This replaces shell-script transport.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::paths;

const DEFAULT_SERVER_URL: &str = "http://127.0.0.1:4000";

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[allow(clippy::enum_variant_names)]
pub enum HookForwardType {
    #[value(name = "claude_session_start")]
    SessionStart,
    #[value(name = "claude_session_end")]
    SessionEnd,
    #[value(name = "claude_status_event")]
    StatusEvent,
    #[value(name = "claude_tool_event")]
    ToolEvent,
    #[value(name = "claude_subagent_event")]
    SubagentEvent,
}

impl HookForwardType {
    pub fn as_wire_type(self) -> &'static str {
        match self {
            HookForwardType::SessionStart => "claude_session_start",
            HookForwardType::SessionEnd => "claude_session_end",
            HookForwardType::StatusEvent => "claude_status_event",
            HookForwardType::ToolEvent => "claude_tool_event",
            HookForwardType::SubagentEvent => "claude_subagent_event",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HookTransportConfig {
    server_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    auth_token: Option<String>,
}

#[derive(Debug, Clone)]
struct HookTarget {
    server_url: String,
    auth_token: Option<String>,
}

pub fn run(
    hook_type: HookForwardType,
    server_url: Option<&str>,
    auth_token: Option<&str>,
) -> anyhow::Result<()> {
    let mut payload = String::new();
    std::io::stdin()
        .read_to_string(&mut payload)
        .context("read hook payload from stdin")?;

    if payload.trim().is_empty() {
        return Ok(());
    }

    let body = match build_hook_body(hook_type, &payload) {
        Ok(body) => body,
        Err(_) => {
            // Never fail the hook invocation for malformed payloads.
            return Ok(());
        }
    };

    let target = resolve_target(server_url, auth_token)?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    runtime.block_on(forward_with_spool(&target, &body))
}

pub fn write_transport_config(
    server_url: &str,
    auth_token: Option<&str>,
) -> anyhow::Result<PathBuf> {
    paths::ensure_dirs().context("ensure data directories for hook transport config")?;
    let config_path = paths::hook_transport_config_path();
    let normalized_url = normalize_server_url(server_url);
    let config = HookTransportConfig {
        server_url: normalized_url,
        auth_token: normalized_non_empty(auth_token.map(ToString::to_string)),
    };
    let body = serde_json::to_string_pretty(&config)?;
    std::fs::write(&config_path, body)?;
    Ok(config_path)
}

fn resolve_target(
    server_url: Option<&str>,
    auth_token: Option<&str>,
) -> anyhow::Result<HookTarget> {
    let persisted = read_transport_config().ok().flatten();

    let resolved_url = server_url
        .map(normalize_server_url)
        .or_else(|| {
            persisted
                .as_ref()
                .map(|cfg| normalize_server_url(&cfg.server_url))
        })
        .unwrap_or_else(|| DEFAULT_SERVER_URL.to_string());

    let mut resolved_token = normalized_non_empty(auth_token.map(ToString::to_string))
        .or_else(|| persisted.and_then(|cfg| normalized_non_empty(cfg.auth_token)));

    if resolved_token.is_none() && resolved_url == DEFAULT_SERVER_URL {
        resolved_token = read_local_auth_token();
    }

    Ok(HookTarget {
        server_url: resolved_url,
        auth_token: resolved_token,
    })
}

fn read_transport_config() -> anyhow::Result<Option<HookTransportConfig>> {
    let path = paths::hook_transport_config_path();
    if !path.exists() {
        return Ok(None);
    }
    let content =
        std::fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let parsed = serde_json::from_str::<HookTransportConfig>(&content)
        .with_context(|| format!("parse {}", path.display()))?;
    Ok(Some(parsed))
}

fn read_local_auth_token() -> Option<String> {
    let path = paths::token_file_path();
    let content = std::fs::read_to_string(path).ok()?;
    normalized_non_empty(Some(content))
}

fn normalize_server_url(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        DEFAULT_SERVER_URL.to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalized_non_empty(value: Option<String>) -> Option<String> {
    let value = value?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn build_hook_body(hook_type: HookForwardType, payload: &str) -> anyhow::Result<String> {
    let mut value: Value = serde_json::from_str(payload)?;
    let Some(obj) = value.as_object_mut() else {
        anyhow::bail!("hook payload must be a JSON object");
    };

    obj.insert(
        "type".to_string(),
        Value::String(hook_type.as_wire_type().to_string()),
    );

    if hook_type == HookForwardType::SessionStart {
        inject_session_start_terminal_fields(obj);
    }

    Ok(serde_json::to_string(&value)?)
}

fn inject_session_start_terminal_fields(obj: &mut Map<String, Value>) {
    if !obj.contains_key("terminal_session_id") {
        obj.insert(
            "terminal_session_id".to_string(),
            std::env::var("ITERM_SESSION_ID")
                .ok()
                .and_then(|v| normalized_non_empty(Some(v)))
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
    }

    if !obj.contains_key("terminal_app") {
        obj.insert(
            "terminal_app".to_string(),
            std::env::var("TERM_PROGRAM")
                .ok()
                .and_then(|v| normalized_non_empty(Some(v)))
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
    }
}

async fn forward_with_spool(target: &HookTarget, current_body: &str) -> anyhow::Result<()> {
    paths::ensure_dirs().context("ensure hook spool directory")?;
    let spool_dir = paths::spool_dir();
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(5))
        .build()?;

    let mut queued = load_spool_files(&spool_dir);
    queued.sort_by(|a, b| a.0.cmp(&b.0));

    for (path, body) in queued {
        if post_hook(&client, target, &body).await.is_err() {
            spool_event(&spool_dir, current_body)?;
            return Ok(());
        }
        let _ = std::fs::remove_file(path);
    }

    if post_hook(&client, target, current_body).await.is_err() {
        spool_event(&spool_dir, current_body)?;
    }

    Ok(())
}

fn load_spool_files(spool_dir: &Path) -> Vec<(PathBuf, String)> {
    let entries = match std::fs::read_dir(spool_dir) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };

    entries
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .filter_map(|path| std::fs::read_to_string(&path).ok().map(|body| (path, body)))
        .collect()
}

fn spool_event(spool_dir: &Path, body: &str) -> anyhow::Result<()> {
    std::fs::create_dir_all(spool_dir)?;
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let pid = std::process::id();
    let filename = format!("{ts}-{pid}.json");
    std::fs::write(spool_dir.join(filename), body)?;
    Ok(())
}

async fn post_hook(
    client: &reqwest::Client,
    target: &HookTarget,
    body: &str,
) -> anyhow::Result<()> {
    let url = format!("{}/api/hook", target.server_url.trim_end_matches('/'));
    let mut request = client
        .post(url)
        .header("Content-Type", "application/json")
        .body(body.to_string());

    if let Some(token) = target.auth_token.as_deref() {
        request = request.bearer_auth(token);
    }

    let response = request.send().await?;
    if !response.status().is_success() {
        anyhow::bail!("hook request failed with status {}", response.status());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{build_hook_body, HookForwardType};

    #[test]
    fn build_hook_body_injects_type() {
        let payload = r#"{"session_id":"abc","cwd":"/tmp"}"#;
        let body = build_hook_body(HookForwardType::StatusEvent, payload).expect("build hook body");
        let value: serde_json::Value = serde_json::from_str(&body).expect("parse body");
        assert_eq!(
            value.get("type").and_then(|v| v.as_str()),
            Some("claude_status_event")
        );
    }

    #[test]
    fn build_hook_body_keeps_existing_terminal_fields() {
        let payload = r#"{
          "session_id":"abc",
          "cwd":"/tmp",
          "terminal_session_id":"my-session",
          "terminal_app":"my-term"
        }"#;
        let body =
            build_hook_body(HookForwardType::SessionStart, payload).expect("build hook body");
        let value: serde_json::Value = serde_json::from_str(&body).expect("parse body");
        assert_eq!(
            value.get("terminal_session_id").and_then(|v| v.as_str()),
            Some("my-session")
        );
        assert_eq!(
            value.get("terminal_app").and_then(|v| v.as_str()),
            Some("my-term")
        );
    }
}
