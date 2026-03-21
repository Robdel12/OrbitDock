use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use codex_app_server_protocol::{
    Config, ConfigBatchWriteParams, ConfigEdit, ConfigLayer, ConfigLayerMetadata,
    ConfigLayerSource, ConfigReadParams, ConfigReadResponse, ConfigValueWriteParams,
    ConfigWriteResponse, MergeStrategy, OverriddenMetadata, WriteStatus,
};
use codex_core::config::Config as CoreConfig;
use orbitdock_connector_codex::{CodexConfigOverrides, CodexConnector, CodexControlPlane};
use orbitdock_protocol::{CodexConfigMode, CodexConfigSource, CodexSessionOverrides};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt;
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
    pub config_mode: CodexConfigMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config_profile: Option<String>,
    pub overrides: CodexSessionOverrides,
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
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

#[derive(Debug, Clone)]
pub struct CodexConfigSelection {
    pub config_source: CodexConfigSource,
    pub config_mode: CodexConfigMode,
    pub config_profile: Option<String>,
    pub model_provider: Option<String>,
    pub overrides: CodexSessionOverrides,
}

impl CodexConfigSelection {
    pub fn normalized(mut self) -> Self {
        match self.config_mode {
            CodexConfigMode::Inherit => {
                self.config_profile = None;
                self.model_provider = None;
                self.overrides.model_provider = None;
            }
            CodexConfigMode::Profile => {
                self.model_provider = None;
                self.overrides.model_provider = None;
            }
            CodexConfigMode::Custom => {
                self.config_profile = None;
            }
        }
        self
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigProfileSummary {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexProviderSummary {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wire_api: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_custom: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigCatalogResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effective_settings: Option<CodexResolvedSettings>,
    pub profiles: Vec<CodexConfigProfileSummary>,
    pub providers: Vec<CodexProviderSummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigDocumentScope {
    User,
    Project,
}

impl fmt::Display for CodexConfigDocumentScope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::User => write!(f, "user"),
            Self::Project => write!(f, "project"),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigProfileDocument {
    pub name: String,
    pub config: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexProviderDocument {
    pub id: String,
    pub config: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wire_api: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_custom: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigDocument {
    pub scope: CodexConfigDocumentScope,
    pub exists: bool,
    pub writable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub write_warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub config: Value,
    pub profiles: Vec<CodexConfigProfileDocument>,
    pub providers: Vec<CodexProviderDocument>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigDocumentsResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub user: CodexConfigDocument,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub projects: Vec<CodexConfigDocument>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigValueWriteRequest {
    pub cwd: String,
    #[serde(default)]
    pub key_path: String,
    pub value: Value,
    #[serde(default)]
    pub merge_strategy: Option<CodexConfigMergeStrategy>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub expected_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigBatchWriteRequest {
    pub cwd: String,
    #[serde(default)]
    pub edits: Vec<CodexConfigEditRequest>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub expected_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigEditRequest {
    pub key_path: String,
    pub value: Value,
    #[serde(default)]
    pub merge_strategy: Option<CodexConfigMergeStrategy>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigMergeStrategy {
    Replace,
    Upsert,
}

impl From<CodexConfigMergeStrategy> for MergeStrategy {
    fn from(value: CodexConfigMergeStrategy) -> Self {
        match value {
            CodexConfigMergeStrategy::Replace => MergeStrategy::Replace,
            CodexConfigMergeStrategy::Upsert => MergeStrategy::Upsert,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigWriteResponseData {
    pub status: String,
    pub version: String,
    pub file_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overridden_metadata: Option<CodexConfigOverriddenMetadata>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigOverriddenMetadata {
    pub message: String,
    pub overriding_layer: CodexInspectorOrigin,
    pub effective_value: Value,
}

pub async fn resolve_codex_settings(
    cwd: &str,
    selection: CodexConfigSelection,
) -> Result<CodexConfigInspectorResponse, String> {
    let selection = selection.normalized();
    let config_response = read_codex_config(cwd).await?;
    let effective_config = build_effective_codex_config(cwd, &selection).await?;
    let effective_settings = effective_settings(&effective_config, &selection);

    let mut origins = inspector_origins(&config_response.origins);
    apply_runtime_origin_overrides(&mut origins, &selection);
    let layers = inspector_layers(config_response.layers.unwrap_or_default(), &selection);

    Ok(CodexConfigInspectorResponse {
        effective_settings,
        origins,
        layers,
        warnings: Vec::new(),
    })
}

pub async fn codex_config_catalog(cwd: &str) -> Result<CodexConfigCatalogResponse, String> {
    let config_response = read_codex_config(cwd).await?;
    let selection = CodexConfigSelection {
        config_source: CodexConfigSource::User,
        config_mode: CodexConfigMode::Inherit,
        config_profile: None,
        model_provider: None,
        overrides: CodexSessionOverrides::default(),
    };
    let effective_config = build_effective_codex_config(cwd, &selection).await?;
    Ok(CodexConfigCatalogResponse {
        cwd: Some(cwd.to_string()),
        effective_settings: Some(effective_settings(&effective_config, &selection)),
        profiles: config_profiles(&config_response.config),
        providers: config_providers(&config_response.config),
        warnings: Vec::new(),
    })
}

pub async fn codex_config_documents(cwd: &str) -> Result<CodexConfigDocumentsResponse, String> {
    let config_response = read_codex_config(cwd).await?;
    let user = user_document(&config_response);
    let projects = project_documents(&config_response);

    Ok(CodexConfigDocumentsResponse {
        cwd: Some(cwd.to_string()),
        user,
        projects,
        warnings: Vec::new(),
    })
}

pub async fn codex_config_write_value(
    request: CodexConfigValueWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
    let response: ConfigWriteResponse = call_codex_app_server(
        &request.cwd,
        2,
        "config/value/write",
        ConfigValueWriteParams {
            key_path: request.key_path,
            value: request.value,
            merge_strategy: request
                .merge_strategy
                .unwrap_or(CodexConfigMergeStrategy::Replace)
                .into(),
            file_path: request.file_path,
            expected_version: request.expected_version,
        },
    )
    .await?;

    Ok(write_response(response))
}

pub async fn codex_config_batch_write(
    request: CodexConfigBatchWriteRequest,
) -> Result<CodexConfigWriteResponseData, String> {
    let response: ConfigWriteResponse = call_codex_app_server(
        &request.cwd,
        2,
        "config/batchWrite",
        ConfigBatchWriteParams {
            edits: request
                .edits
                .into_iter()
                .map(|edit| ConfigEdit {
                    key_path: edit.key_path,
                    value: edit.value,
                    merge_strategy: edit
                        .merge_strategy
                        .unwrap_or(CodexConfigMergeStrategy::Replace)
                        .into(),
                })
                .collect(),
            file_path: request.file_path,
            expected_version: request.expected_version,
            reload_user_config: true,
        },
    )
    .await?;

    Ok(write_response(response))
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
    config: &CoreConfig,
    selection: &CodexConfigSelection,
) -> CodexResolvedSettings {
    CodexResolvedSettings {
        config_source: selection.config_source,
        config_mode: selection.config_mode,
        config_profile: config.active_profile.clone(),
        overrides: selection.overrides.clone(),
        model: config.model.clone(),
        model_provider: Some(config.model_provider_id.clone()),
        approval_policy: Some(core_approval_policy_to_string(
            *config.permissions.approval_policy.get(),
        )),
        sandbox_mode: Some(core_sandbox_policy_to_string(
            &config.permissions.sandbox_policy,
        )),
        collaboration_mode: selection.overrides.collaboration_mode.clone(),
        multi_agent: selection.overrides.multi_agent,
        personality: selection.overrides.personality.clone(),
        service_tier: config.service_tier.map(service_tier_to_string),
        developer_instructions: config
            .developer_instructions
            .clone()
            .or(selection.overrides.developer_instructions.clone()),
        effort: config
            .model_reasoning_effort
            .map(reasoning_effort_to_string),
    }
}

fn inspector_layers(
    layers: Vec<ConfigLayer>,
    selection: &CodexConfigSelection,
) -> Vec<CodexInspectorLayer> {
    let mut mapped = Vec::new();

    if let Some(runtime_layer) = runtime_override_layer(selection) {
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
    selection: &CodexConfigSelection,
) {
    let runtime_origin = |path: &str| CodexInspectorOrigin {
        source_kind: "orbitdock_runtime".to_string(),
        path: Some(path.to_string()),
        version: "runtime".to_string(),
    };

    if selection.config_profile.is_some() {
        origins.insert("profile".to_string(), runtime_origin("profile"));
    }
    if selection.model_provider.is_some() || selection.overrides.model_provider.is_some() {
        origins.insert(
            "model_provider".to_string(),
            runtime_origin("model_provider"),
        );
    }
    if selection.overrides.collaboration_mode.is_some() {
        origins.insert(
            "collaboration_mode".to_string(),
            runtime_origin("collaboration_mode"),
        );
    }
    if selection.overrides.model.is_some() {
        origins.insert("model".to_string(), runtime_origin("model"));
    }
    if selection.overrides.approval_policy.is_some() {
        origins.insert(
            "approval_policy".to_string(),
            runtime_origin("approval_policy"),
        );
    }
    if selection.overrides.sandbox_mode.is_some() {
        origins.insert("sandbox_mode".to_string(), runtime_origin("sandbox_mode"));
    }
    if selection.overrides.multi_agent.is_some() {
        origins.insert(
            "features.multi_agent".to_string(),
            runtime_origin("features.multi_agent"),
        );
    }
    if selection.overrides.personality.is_some() {
        origins.insert("personality".to_string(), runtime_origin("personality"));
    }
    if selection.overrides.service_tier.is_some() {
        origins.insert("service_tier".to_string(), runtime_origin("service_tier"));
    }
    if selection.overrides.developer_instructions.is_some() {
        origins.insert(
            "developer_instructions".to_string(),
            runtime_origin("developer_instructions"),
        );
    }
    if selection.overrides.effort.is_some() {
        origins.insert(
            "model_reasoning_effort".to_string(),
            runtime_origin("model_reasoning_effort"),
        );
    }
}

fn runtime_override_layer(selection: &CodexConfigSelection) -> Option<CodexInspectorLayer> {
    let mut config = serde_json::Map::new();

    if let Some(profile) = &selection.config_profile {
        config.insert("profile".to_string(), Value::String(profile.clone()));
    }
    if let Some(model_provider) = selection
        .model_provider
        .as_ref()
        .or(selection.overrides.model_provider.as_ref())
    {
        config.insert(
            "model_provider".to_string(),
            Value::String(model_provider.clone()),
        );
    }
    if let Some(model) = &selection.overrides.model {
        config.insert("model".to_string(), Value::String(model.clone()));
    }
    if let Some(approval_policy) = &selection.overrides.approval_policy {
        config.insert(
            "approval_policy".to_string(),
            Value::String(approval_policy.clone()),
        );
    }
    if let Some(sandbox_mode) = &selection.overrides.sandbox_mode {
        config.insert(
            "sandbox_mode".to_string(),
            Value::String(sandbox_mode.clone()),
        );
    }
    if let Some(collaboration_mode) = &selection.overrides.collaboration_mode {
        config.insert(
            "collaboration_mode".to_string(),
            Value::String(collaboration_mode.clone()),
        );
    }
    if let Some(multi_agent) = selection.overrides.multi_agent {
        config.insert(
            "features".to_string(),
            serde_json::json!({ "multi_agent": multi_agent }),
        );
    }
    if let Some(personality) = &selection.overrides.personality {
        config.insert(
            "personality".to_string(),
            Value::String(personality.clone()),
        );
    }
    if let Some(service_tier) = &selection.overrides.service_tier {
        config.insert(
            "service_tier".to_string(),
            Value::String(service_tier.clone()),
        );
    }
    if let Some(developer_instructions) = &selection.overrides.developer_instructions {
        config.insert(
            "developer_instructions".to_string(),
            Value::String(developer_instructions.clone()),
        );
    }
    if let Some(effort) = &selection.overrides.effort {
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
    call_codex_app_server(
        cwd,
        2,
        "config/read",
        ConfigReadParams {
            include_layers: true,
            cwd: Some(cwd.to_string()),
        },
    )
    .await
}

async fn call_codex_app_server<TParams, TResponse>(
    cwd: &str,
    request_id: i64,
    method: &str,
    params: TParams,
) -> Result<TResponse, String>
where
    TParams: Serialize,
    TResponse: serde::de::DeserializeOwned,
{
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
                "method": method,
                "id": request_id,
                "params": params,
            }),
        )
        .await?;

        let response = read_json_rpc_response(&mut lines, request_id).await?;
        if let Some(error) = response.get("error") {
            return Err(json_rpc_error_message(method, error));
        }

        let result = response
            .get("result")
            .cloned()
            .ok_or_else(|| format!("{method} returned no result"))?;
        serde_json::from_value::<TResponse>(result)
            .map_err(|error| format!("Failed to decode {method} response: {error}"))
    }
    .await;

    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

fn user_document(config_response: &ConfigReadResponse) -> CodexConfigDocument {
    let Some(layer) = config_response.layers.as_ref().and_then(|layers| {
        layers
            .iter()
            .find(|layer| matches!(layer.name, ConfigLayerSource::User { .. }))
    }) else {
        return CodexConfigDocument {
            scope: CodexConfigDocumentScope::User,
            exists: false,
            writable: true,
            write_warning: None,
            file_path: default_user_config_path(),
            version: None,
            config: Value::Object(Map::new()),
            profiles: Vec::new(),
            providers: Vec::new(),
        };
    };

    config_document_from_layer(layer, CodexConfigDocumentScope::User, true, None)
}

fn project_documents(config_response: &ConfigReadResponse) -> Vec<CodexConfigDocument> {
    let mut documents: Vec<_> = config_response
        .layers
        .as_ref()
        .into_iter()
        .flat_map(|layers| layers.iter())
        .filter(|layer| matches!(layer.name, ConfigLayerSource::Project { .. }))
        .map(|layer| {
            config_document_from_layer(
                layer,
                CodexConfigDocumentScope::Project,
                false,
                Some("Codex currently only supports writes to the user config layer.".to_string()),
            )
        })
        .collect();
    documents.sort_by(|a, b| a.file_path.cmp(&b.file_path));
    documents
}

fn config_document_from_layer(
    layer: &ConfigLayer,
    scope: CodexConfigDocumentScope,
    writable: bool,
    write_warning: Option<String>,
) -> CodexConfigDocument {
    CodexConfigDocument {
        scope,
        exists: true,
        writable,
        write_warning,
        file_path: source_path(&layer.name),
        version: Some(layer.version.clone()),
        config: layer.config.clone(),
        profiles: config_profile_documents(&layer.config),
        providers: config_provider_documents(&layer.config),
    }
}

fn config_profile_documents(config: &Value) -> Vec<CodexConfigProfileDocument> {
    let mut profiles: Vec<_> = config
        .get("profiles")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|profiles| profiles.iter())
        .map(|(name, profile)| CodexConfigProfileDocument {
            name: name.clone(),
            config: profile.clone(),
            model: profile
                .get("model")
                .and_then(Value::as_str)
                .map(str::to_string),
            model_provider: profile
                .get("model_provider")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
        .collect();
    profiles.sort_by(|a, b| a.name.cmp(&b.name));
    profiles
}

fn config_provider_documents(config: &Value) -> Vec<CodexProviderDocument> {
    let mut providers: Vec<_> = config
        .get("model_providers")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|providers| providers.iter())
        .map(|(id, provider)| CodexProviderDocument {
            id: id.clone(),
            config: provider.clone(),
            display_name: Some(id.clone()),
            base_url: provider
                .get("base_url")
                .and_then(Value::as_str)
                .map(str::to_string),
            wire_api: provider
                .get("wire_api")
                .and_then(Value::as_str)
                .map(str::to_string),
            env_key: provider
                .get("env_key")
                .and_then(Value::as_str)
                .map(str::to_string),
            is_custom: Some(true),
        })
        .collect();
    providers.sort_by(|a, b| a.id.cmp(&b.id));
    providers
}

fn default_user_config_path() -> Option<String> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".codex")
            .join("config.toml")
            .display()
            .to_string()
    })
}

fn write_response(response: ConfigWriteResponse) -> CodexConfigWriteResponseData {
    CodexConfigWriteResponseData {
        status: match response.status {
            WriteStatus::Ok => "ok".to_string(),
            WriteStatus::OkOverridden => "ok_overridden".to_string(),
        },
        version: response.version,
        file_path: response.file_path.as_path().display().to_string(),
        overridden_metadata: response
            .overridden_metadata
            .map(overridden_metadata_response),
    }
}

fn overridden_metadata_response(value: OverriddenMetadata) -> CodexConfigOverriddenMetadata {
    CodexConfigOverriddenMetadata {
        message: value.message,
        overriding_layer: CodexInspectorOrigin {
            source_kind: source_kind_name(&value.overriding_layer.name),
            path: source_path(&value.overriding_layer.name),
            version: value.overriding_layer.version,
        },
        effective_value: value.effective_value,
    }
}

async fn build_effective_codex_config(
    cwd: &str,
    selection: &CodexConfigSelection,
) -> Result<CoreConfig, String> {
    let config_overrides = CodexConfigOverrides {
        model_provider: selection
            .model_provider
            .clone()
            .or(selection.overrides.model_provider.clone()),
        config_profile: selection.config_profile.clone(),
    };
    let control_plane = CodexControlPlane {
        collaboration_mode: selection.overrides.collaboration_mode.clone(),
        multi_agent: selection.overrides.multi_agent,
        personality: selection.overrides.personality.clone(),
        service_tier: selection.overrides.service_tier.clone(),
        developer_instructions: selection.overrides.developer_instructions.clone(),
    };
    CodexConnector::build_config_with_runtime_defaults(
        cwd,
        selection.overrides.model.as_deref(),
        selection.overrides.approval_policy.as_deref(),
        selection.overrides.sandbox_mode.as_deref(),
        &config_overrides,
        &control_plane,
        false,
    )
    .await
    .map_err(|error| error.to_string())
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

fn core_approval_policy_to_string(value: codex_protocol::protocol::AskForApproval) -> String {
    match value {
        codex_protocol::protocol::AskForApproval::UnlessTrusted => "untrusted",
        codex_protocol::protocol::AskForApproval::OnFailure => "on-failure",
        codex_protocol::protocol::AskForApproval::OnRequest => "on-request",
        codex_protocol::protocol::AskForApproval::Reject { .. } => "reject",
        codex_protocol::protocol::AskForApproval::Never => "never",
    }
    .to_string()
}

fn config_profiles(config: &Config) -> Vec<CodexConfigProfileSummary> {
    let mut profiles: Vec<_> = config
        .profiles
        .iter()
        .map(|(name, profile)| CodexConfigProfileSummary {
            name: name.clone(),
            model: profile.model.clone(),
            model_provider: profile.model_provider.clone(),
            source: Some("codex".to_string()),
        })
        .collect();
    profiles.sort_by(|a, b| a.name.cmp(&b.name));
    profiles
}

fn config_providers(config: &Config) -> Vec<CodexProviderSummary> {
    let mut providers: HashMap<String, CodexProviderSummary> = built_in_provider_summaries()
        .into_iter()
        .map(|provider| (provider.id.clone(), provider))
        .collect();

    if let Some(custom) = config
        .additional
        .get("model_providers")
        .and_then(Value::as_object)
    {
        for (id, raw) in custom {
            let raw = raw.as_object();
            providers.insert(
                id.clone(),
                CodexProviderSummary {
                    id: id.clone(),
                    display_name: Some(id.clone()),
                    base_url: raw
                        .and_then(|value| value.get("base_url"))
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    wire_api: raw
                        .and_then(|value| value.get("wire_api"))
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    env_key: raw
                        .and_then(|value| value.get("env_key"))
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    is_custom: Some(true),
                },
            );
        }
    }

    let mut values: Vec<_> = providers.into_values().collect();
    values.sort_by(|a, b| a.id.cmp(&b.id));
    values
}

fn built_in_provider_summaries() -> Vec<CodexProviderSummary> {
    vec![
        CodexProviderSummary {
            id: "openai".to_string(),
            display_name: Some("OpenAI".to_string()),
            base_url: Some("https://api.openai.com/v1".to_string()),
            wire_api: Some("responses".to_string()),
            env_key: Some("OPENAI_API_KEY".to_string()),
            is_custom: Some(false),
        },
        CodexProviderSummary {
            id: "ollama".to_string(),
            display_name: Some("Ollama".to_string()),
            base_url: Some("http://localhost:11434/v1".to_string()),
            wire_api: Some("chat_completions".to_string()),
            env_key: None,
            is_custom: Some(false),
        },
        CodexProviderSummary {
            id: "lmstudio".to_string(),
            display_name: Some("LM Studio".to_string()),
            base_url: Some("http://localhost:1234/v1".to_string()),
            wire_api: Some("chat_completions".to_string()),
            env_key: None,
            is_custom: Some(false),
        },
    ]
}

fn core_sandbox_policy_to_string(value: &codex_protocol::protocol::SandboxPolicy) -> String {
    match value {
        codex_protocol::protocol::SandboxPolicy::DangerFullAccess => "danger-full-access",
        codex_protocol::protocol::SandboxPolicy::ReadOnly { .. } => "read-only",
        codex_protocol::protocol::SandboxPolicy::ExternalSandbox { .. } => "read-only",
        codex_protocol::protocol::SandboxPolicy::WorkspaceWrite { .. } => "workspace-write",
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalized_selection_clears_profile_and_provider_for_inherit_mode() {
        let normalized = CodexConfigSelection {
            config_source: CodexConfigSource::User,
            config_mode: CodexConfigMode::Inherit,
            config_profile: Some("qwen".to_string()),
            model_provider: Some("openrouter".to_string()),
            overrides: CodexSessionOverrides {
                model_provider: Some("openrouter".to_string()),
                ..CodexSessionOverrides::default()
            },
        }
        .normalized();

        assert_eq!(normalized.config_profile, None);
        assert_eq!(normalized.model_provider, None);
        assert_eq!(normalized.overrides.model_provider, None);
    }

    #[test]
    fn normalized_selection_clears_stale_profile_for_custom_mode() {
        let normalized = CodexConfigSelection {
            config_source: CodexConfigSource::User,
            config_mode: CodexConfigMode::Custom,
            config_profile: Some("qwen".to_string()),
            model_provider: Some("openrouter".to_string()),
            overrides: CodexSessionOverrides::default(),
        }
        .normalized();

        assert_eq!(normalized.config_profile, None);
        assert_eq!(normalized.model_provider.as_deref(), Some("openrouter"));
    }
}
