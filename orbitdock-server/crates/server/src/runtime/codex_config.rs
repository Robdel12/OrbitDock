use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use codex_app_server_protocol::{
    AskForApproval, Config, ConfigLayer, ConfigLayerMetadata, ConfigLayerSource, ConfigReadParams,
    ConfigReadResponse, SandboxMode,
};
use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides};
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdout, Command};

const CODEX_DEFAULT_CONFIG_SOURCE_KEY: &str = "codex_default_config_source";
const CODEX_PATH_SENTINEL: &str = "__ORBITDOCK_PATH__";

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigPreferencesResponse {
    pub default_config_source: CodexConfigSource,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexResolvedSettings {
    pub config_source: CodexConfigSource,
    pub overrides: CodexSessionOverrides,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexInspectorOrigin {
    pub source_kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub version: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexInspectorLayer {
    pub source_kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub version: String,
    pub config: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disabled_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigInspectorResponse {
    pub effective_settings: CodexResolvedSettings,
    pub origins: HashMap<String, CodexInspectorOrigin>,
    pub layers: Vec<CodexInspectorLayer>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

pub async fn resolve_codex_settings(
    cwd: &str,
    config_source: CodexConfigSource,
    overrides: CodexSessionOverrides,
) -> Result<CodexConfigInspectorResponse, String> {
    let config_response = read_codex_config(cwd).await?;
    let effective_settings = effective_settings(&config_response.config, config_source, &overrides);

    let mut origins = inspector_origins(&config_response.origins);
    apply_runtime_origin_overrides(&mut origins, &overrides);
    let layers = inspector_layers(config_response.layers.unwrap_or_default(), &overrides);

    Ok(CodexConfigInspectorResponse {
        effective_settings,
        origins,
        layers,
        warnings: Vec::new(),
    })
}

pub fn codex_default_config_source() -> CodexConfigSource {
    match crate::infrastructure::persistence::load_config_value(CODEX_DEFAULT_CONFIG_SOURCE_KEY)
        .as_deref()
    {
        Some("orbitdock") => CodexConfigSource::Orbitdock,
        Some("user") => CodexConfigSource::User,
        _ => CodexConfigSource::User,
    }
}

pub fn codex_preferences_response() -> CodexConfigPreferencesResponse {
    CodexConfigPreferencesResponse {
        default_config_source: codex_default_config_source(),
    }
}

pub fn source_kind_name(source: &ConfigLayerSource) -> String {
    match source {
        ConfigLayerSource::Mdm { .. } => "mdm",
        ConfigLayerSource::System { .. } => "system",
        ConfigLayerSource::User { .. } => "user",
        ConfigLayerSource::Project { .. } => "project",
        ConfigLayerSource::SessionFlags => "session_flags",
        ConfigLayerSource::LegacyManagedConfigTomlFromFile { .. } => "legacy_managed_file",
        ConfigLayerSource::LegacyManagedConfigTomlFromMdm => "legacy_managed_mdm",
    }
    .to_string()
}

pub fn source_path(source: &ConfigLayerSource) -> Option<String> {
    match source {
        ConfigLayerSource::Mdm { domain, key } => Some(format!("{domain}:{key}")),
        ConfigLayerSource::System { file } | ConfigLayerSource::User { file } => {
            Some(file.as_path().display().to_string())
        }
        ConfigLayerSource::Project { dot_codex_folder } => {
            Some(dot_codex_folder.as_path().display().to_string())
        }
        ConfigLayerSource::SessionFlags => None,
        ConfigLayerSource::LegacyManagedConfigTomlFromFile { file } => {
            Some(file.as_path().display().to_string())
        }
        ConfigLayerSource::LegacyManagedConfigTomlFromMdm => None,
    }
}

pub fn serialize_codex_overrides(overrides: &CodexSessionOverrides) -> Option<String> {
    if overrides == &CodexSessionOverrides::default() {
        None
    } else {
        serde_json::to_string(overrides).ok()
    }
}

fn effective_settings(
    config: &Config,
    config_source: CodexConfigSource,
    overrides: &CodexSessionOverrides,
) -> CodexResolvedSettings {
    CodexResolvedSettings {
        config_source,
        overrides: overrides.clone(),
        model: overrides.model.clone().or_else(|| config.model.clone()),
        approval_policy: overrides
            .approval_policy
            .clone()
            .or_else(|| config.approval_policy.map(approval_policy_to_string)),
        sandbox_mode: overrides
            .sandbox_mode
            .clone()
            .or_else(|| config.sandbox_mode.map(sandbox_mode_to_string)),
        collaboration_mode: overrides
            .collaboration_mode
            .clone()
            .or_else(|| config_string(config, "collaboration_mode")),
        multi_agent: overrides
            .multi_agent
            .or_else(|| config_bool(config, &["features", "multi_agent"])),
        personality: overrides
            .personality
            .clone()
            .or_else(|| config_string(config, "personality")),
        service_tier: overrides
            .service_tier
            .clone()
            .or_else(|| config.service_tier.map(service_tier_to_string)),
        developer_instructions: overrides
            .developer_instructions
            .clone()
            .or_else(|| config.developer_instructions.clone()),
        effort: overrides.effort.clone().or_else(|| {
            config
                .model_reasoning_effort
                .map(reasoning_effort_to_string)
        }),
    }
}

fn inspector_layers(
    layers: Vec<ConfigLayer>,
    overrides: &CodexSessionOverrides,
) -> Vec<CodexInspectorLayer> {
    let mut mapped = Vec::new();

    if let Some(runtime_layer) = runtime_override_layer(overrides) {
        mapped.push(runtime_layer);
    }

    mapped.extend(layers.into_iter().map(|layer| CodexInspectorLayer {
        source_kind: source_kind_name(&layer.name),
        path: source_path(&layer.name),
        version: layer.version,
        config: layer.config,
        disabled_reason: layer.disabled_reason,
    }));

    mapped
}

fn inspector_origins(
    origins: &HashMap<String, ConfigLayerMetadata>,
) -> HashMap<String, CodexInspectorOrigin> {
    origins
        .iter()
        .map(|(path, metadata)| {
            (
                path.clone(),
                CodexInspectorOrigin {
                    source_kind: source_kind_name(&metadata.name),
                    path: source_path(&metadata.name),
                    version: metadata.version.clone(),
                },
            )
        })
        .collect()
}

fn apply_runtime_origin_overrides(
    origins: &mut HashMap<String, CodexInspectorOrigin>,
    overrides: &CodexSessionOverrides,
) {
    let runtime_origin = |path: &str| CodexInspectorOrigin {
        source_kind: "orbitdock_runtime".to_string(),
        path: Some(path.to_string()),
        version: "runtime".to_string(),
    };

    if overrides.collaboration_mode.is_some() {
        origins.insert(
            "collaboration_mode".to_string(),
            runtime_origin("collaboration_mode"),
        );
    }
    if overrides.model.is_some() {
        origins.insert("model".to_string(), runtime_origin("model"));
    }
    if overrides.approval_policy.is_some() {
        origins.insert(
            "approval_policy".to_string(),
            runtime_origin("approval_policy"),
        );
    }
    if overrides.sandbox_mode.is_some() {
        origins.insert("sandbox_mode".to_string(), runtime_origin("sandbox_mode"));
    }
    if overrides.multi_agent.is_some() {
        origins.insert(
            "features.multi_agent".to_string(),
            runtime_origin("features.multi_agent"),
        );
    }
    if overrides.personality.is_some() {
        origins.insert("personality".to_string(), runtime_origin("personality"));
    }
    if overrides.service_tier.is_some() {
        origins.insert("service_tier".to_string(), runtime_origin("service_tier"));
    }
    if overrides.developer_instructions.is_some() {
        origins.insert(
            "developer_instructions".to_string(),
            runtime_origin("developer_instructions"),
        );
    }
    if overrides.effort.is_some() {
        origins.insert(
            "model_reasoning_effort".to_string(),
            runtime_origin("model_reasoning_effort"),
        );
    }
}

fn runtime_override_layer(overrides: &CodexSessionOverrides) -> Option<CodexInspectorLayer> {
    let mut config = serde_json::Map::new();

    if let Some(model) = &overrides.model {
        config.insert("model".to_string(), Value::String(model.clone()));
    }
    if let Some(approval_policy) = &overrides.approval_policy {
        config.insert(
            "approval_policy".to_string(),
            Value::String(approval_policy.clone()),
        );
    }
    if let Some(sandbox_mode) = &overrides.sandbox_mode {
        config.insert(
            "sandbox_mode".to_string(),
            Value::String(sandbox_mode.clone()),
        );
    }
    if let Some(collaboration_mode) = &overrides.collaboration_mode {
        config.insert(
            "collaboration_mode".to_string(),
            Value::String(collaboration_mode.clone()),
        );
    }
    if let Some(multi_agent) = overrides.multi_agent {
        config.insert(
            "features".to_string(),
            serde_json::json!({ "multi_agent": multi_agent }),
        );
    }
    if let Some(personality) = &overrides.personality {
        config.insert(
            "personality".to_string(),
            Value::String(personality.clone()),
        );
    }
    if let Some(service_tier) = &overrides.service_tier {
        config.insert(
            "service_tier".to_string(),
            Value::String(service_tier.clone()),
        );
    }
    if let Some(developer_instructions) = &overrides.developer_instructions {
        config.insert(
            "developer_instructions".to_string(),
            Value::String(developer_instructions.clone()),
        );
    }
    if let Some(effort) = &overrides.effort {
        config.insert(
            "model_reasoning_effort".to_string(),
            Value::String(effort.clone()),
        );
    }

    if config.is_empty() {
        return None;
    }

    Some(CodexInspectorLayer {
        source_kind: "orbitdock_runtime".to_string(),
        path: Some("runtime overrides".to_string()),
        version: "runtime".to_string(),
        config: Value::Object(config),
        disabled_reason: None,
    })
}

async fn read_codex_config(cwd: &str) -> Result<ConfigReadResponse, String> {
    let codex_path = find_codex_binary().ok_or_else(|| "Codex CLI not installed".to_string())?;
    let path_env = resolved_path_env_for_binary(&codex_path);

    let mut command = Command::new(&codex_path);
    command.arg("app-server");
    command.stdin(Stdio::piped());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    command.current_dir(cwd);
    if let Some(path_env) = path_env {
        command.env("PATH", path_env);
    }

    let mut child = command
        .spawn()
        .map_err(|error| format!("Failed to start codex app-server: {error}"))?;

    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill().await;
        return Err("Failed to open codex app-server stdin".to_string());
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill().await;
        return Err("Failed to open codex app-server stdout".to_string());
    };
    let mut lines = BufReader::new(stdout).lines();

    let result = async {
        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method": "initialize",
                "id": 1,
                "params": {
                    "clientInfo": {
                        "name": "orbitdock",
                        "title": "OrbitDock",
                        "version": env!("CARGO_PKG_VERSION"),
                    }
                }
            }),
        )
        .await?;
        let init_response = read_json_rpc_response(&mut lines, 1).await?;
        if let Some(error) = init_response.get("error") {
            return Err(json_rpc_error_message("initialize", error));
        }

        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method": "initialized",
                "params": {}
            }),
        )
        .await?;

        send_json_rpc(
            &mut stdin,
            serde_json::json!({
                "method": "config/read",
                "id": 2,
                "params": ConfigReadParams {
                    include_layers: true,
                    cwd: Some(cwd.to_string()),
                }
            }),
        )
        .await?;

        let config_response = read_json_rpc_response(&mut lines, 2).await?;
        if let Some(error) = config_response.get("error") {
            return Err(json_rpc_error_message("config/read", error));
        }

        let result = config_response
            .get("result")
            .cloned()
            .ok_or_else(|| "config/read returned no result".to_string())?;
        serde_json::from_value::<ConfigReadResponse>(result)
            .map_err(|error| format!("Failed to decode config/read response: {error}"))
    }
    .await;

    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

async fn send_json_rpc(
    stdin: &mut tokio::process::ChildStdin,
    payload: Value,
) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(&payload)
        .map_err(|error| format!("Invalid JSON-RPC payload: {error}"))?;
    bytes.push(b'\n');
    stdin
        .write_all(&bytes)
        .await
        .map_err(|error| format!("Failed writing to codex app-server stdin: {error}"))?;
    stdin
        .flush()
        .await
        .map_err(|error| format!("Failed flushing codex app-server stdin: {error}"))?;
    Ok(())
}

async fn read_json_rpc_response(
    lines: &mut tokio::io::Lines<BufReader<ChildStdout>>,
    expected_id: i64,
) -> Result<Value, String> {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
            .await
            .map_err(|_| "Timed out waiting for codex app-server response".to_string())?
            .map_err(|error| format!("Failed reading codex app-server output: {error}"))?;

        let Some(line) = line else {
            return Err("Codex app-server exited unexpectedly".to_string());
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let value: Value = serde_json::from_str(trimmed)
            .map_err(|error| format!("Invalid codex app-server response: {error}"))?;
        if value.get("id").and_then(Value::as_i64) == Some(expected_id) {
            return Ok(value);
        }
    }
}

fn json_rpc_error_message(method: &str, error: &Value) -> String {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Unknown JSON-RPC error");
    format!("{method} failed: {message}")
}

fn config_string(config: &Config, key: &str) -> Option<String> {
    config
        .additional
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn config_bool(config: &Config, path: &[&str]) -> Option<bool> {
    let mut value = config.additional.get(*path.first()?)?;
    for segment in path.iter().skip(1) {
        value = value.get(*segment)?;
    }
    value.as_bool()
}

fn approval_policy_to_string(value: AskForApproval) -> String {
    match value {
        AskForApproval::UnlessTrusted => "untrusted",
        AskForApproval::OnFailure => "on-failure",
        AskForApproval::OnRequest => "on-request",
        AskForApproval::Reject { .. } => "reject",
        AskForApproval::Never => "never",
    }
    .to_string()
}

fn sandbox_mode_to_string(value: SandboxMode) -> String {
    match value {
        SandboxMode::ReadOnly => "read-only",
        SandboxMode::WorkspaceWrite => "workspace-write",
        SandboxMode::DangerFullAccess => "danger-full-access",
    }
    .to_string()
}

fn service_tier_to_string(value: codex_protocol::config_types::ServiceTier) -> String {
    value.to_string()
}

fn reasoning_effort_to_string(value: codex_protocol::openai_models::ReasoningEffort) -> String {
    value.to_string()
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

    for directory in resolve_path_entries() {
        let candidate = directory.join("codex");
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }

    None
}

fn is_executable_file(path: &Path) -> bool {
    path.is_file()
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
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let command = format!("printf '{}%s\\n' \"$PATH\"", CODEX_PATH_SENTINEL);

    for args in [
        vec!["-ilc".to_string(), command.clone()],
        vec!["-lc".to_string(), command.clone()],
        vec!["-c".to_string(), command.clone()],
    ] {
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
    output
        .lines()
        .find_map(|line| line.strip_prefix(CODEX_PATH_SENTINEL))
        .map(str::to_string)
}

fn dedup_non_empty(entries: Vec<String>) -> Option<String> {
    let mut deduped = Vec::new();
    for entry in entries {
        let trimmed = entry.trim();
        if trimmed.is_empty() {
            continue;
        }
        if deduped.iter().any(|existing| existing == trimmed) {
            continue;
        }
        deduped.push(trimmed.to_string());
    }

    if deduped.is_empty() {
        None
    } else {
        Some(deduped.join(":"))
    }
}
