use std::collections::HashMap;

use codex_app_server_protocol::ConfigLayerSource;
use codex_core::config::Config;
use codex_core::config_loader::ConfigLayerStackOrdering;
use codex_core::features::Feature;
use codex_protocol::config_types::{Personality, ServiceTier};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{AskForApproval, SandboxPolicy};
use orbitdock_connector_codex::{CodexConnector, CodexControlPlane};
use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides};
use serde::Serialize;

const CODEX_DEFAULT_CONFIG_SOURCE_KEY: &str = "codex_default_config_source";

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
    let control_plane = CodexControlPlane {
        collaboration_mode: overrides.collaboration_mode.clone(),
        multi_agent: overrides.multi_agent,
        personality: overrides.personality.clone(),
        service_tier: overrides.service_tier.clone(),
        developer_instructions: overrides.developer_instructions.clone(),
    };

    let config = CodexConnector::build_config_with_runtime_defaults(
        cwd,
        overrides.model.as_deref(),
        overrides.approval_policy.as_deref(),
        overrides.sandbox_mode.as_deref(),
        &control_plane,
        config_source == CodexConfigSource::Orbitdock,
    )
    .await
    .map_err(|error| error.to_string())?;

    let effective_settings = CodexResolvedSettings {
        config_source,
        overrides: overrides.clone(),
        model: config.model.clone(),
        approval_policy: Some(approval_policy_to_string(
            config.permissions.approval_policy.value(),
        )),
        sandbox_mode: Some(sandbox_policy_to_string(
            config.permissions.sandbox_policy.get(),
        )),
        collaboration_mode: overrides.collaboration_mode.clone(),
        multi_agent: Some(config.features.get().enabled(Feature::Collab)),
        personality: config.personality.as_ref().map(personality_to_string),
        service_tier: config.service_tier.as_ref().map(service_tier_to_string),
        developer_instructions: config.developer_instructions.clone(),
        effort: config
            .model_reasoning_effort
            .as_ref()
            .map(reasoning_effort_to_string),
    };

    let mut origins = inspector_origins(&config);
    apply_runtime_origin_overrides(&mut origins, &overrides);

    Ok(CodexConfigInspectorResponse {
        effective_settings,
        origins,
        layers: inspector_layers(&config),
        warnings: config.startup_warnings.clone(),
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

fn inspector_layers(config: &Config) -> Vec<CodexInspectorLayer> {
    config
        .config_layer_stack
        .get_layers(ConfigLayerStackOrdering::HighestPrecedenceFirst, true)
        .into_iter()
        .map(|layer| CodexInspectorLayer {
            source_kind: source_kind_name(&layer.name),
            path: source_path(&layer.name),
            version: layer.version.clone(),
            config: serde_json::to_value(&layer.config).unwrap_or(serde_json::Value::Null),
            disabled_reason: layer.disabled_reason.clone(),
        })
        .collect()
}

fn inspector_origins(config: &Config) -> HashMap<String, CodexInspectorOrigin> {
    config
        .config_layer_stack
        .origins()
        .into_iter()
        .map(|(path, metadata)| {
            (
                path,
                CodexInspectorOrigin {
                    source_kind: source_kind_name(&metadata.name),
                    path: source_path(&metadata.name),
                    version: metadata.version,
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

fn approval_policy_to_string(value: AskForApproval) -> String {
    match value {
        AskForApproval::UnlessTrusted => "untrusted",
        AskForApproval::OnFailure => "on-failure",
        AskForApproval::OnRequest => "on-request",
        AskForApproval::Never => "never",
        AskForApproval::Reject { .. } => "reject",
    }
    .to_string()
}

fn sandbox_policy_to_string(value: &SandboxPolicy) -> String {
    match value {
        SandboxPolicy::DangerFullAccess => "danger-full-access",
        SandboxPolicy::ReadOnly { .. } => "read-only",
        SandboxPolicy::ExternalSandbox { .. } => "external-sandbox",
        SandboxPolicy::WorkspaceWrite { .. } => "workspace-write",
    }
    .to_string()
}

fn personality_to_string(value: &Personality) -> String {
    value.to_string()
}

fn service_tier_to_string(value: &ServiceTier) -> String {
    value.to_string()
}

fn reasoning_effort_to_string(value: &ReasoningEffort) -> String {
    value.to_string()
}
