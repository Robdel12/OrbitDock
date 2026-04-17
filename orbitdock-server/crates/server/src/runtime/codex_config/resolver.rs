use std::collections::HashMap;
use std::path::PathBuf;

use codex_app_server_protocol::{ConfigLayer, ConfigLayerMetadata, ConfigLayerSource};
use codex_core::config::Config as CoreConfig;
use orbitdock_connector_codex::{
  config_loader_sandbox_mode, requested_sandbox_policy_details, CodexConfigOverrides,
  CodexConnector, CodexControlPlane,
};
use orbitdock_protocol::{
  CodexApprovalMode, CodexApprovalPolicy, CodexApprovalsReviewer, CodexGranularApprovalPolicy,
  CodexSandboxMode, CodexSandboxPolicy, CodexSessionOverrides,
};
use serde_json::Value;

use super::codex_config_types::{
  CodexConfigInspectorResponse, CodexConfigSelection, CodexInspectorLayer, CodexInspectorOrigin,
  CodexResolvedSettings,
};
use super::rpc_client::read_codex_config;

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

pub(crate) async fn build_effective_codex_config(
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
    approvals_reviewer: selection
      .overrides
      .approvals_reviewer
      .map(|value| value.as_str().to_string()),
    collaboration_mode: selection.overrides.collaboration_mode.clone(),
    multi_agent: selection.overrides.multi_agent,
    personality: selection.overrides.personality.clone(),
    service_tier: selection.overrides.service_tier.clone(),
    developer_instructions: selection.overrides.developer_instructions.clone(),
    effort: selection.overrides.effort.clone(),
  };
  CodexConnector::build_config_with_runtime_defaults(
    cwd,
    selection.overrides.model.as_deref(),
    selection.overrides.approval_policy_summary().as_deref(),
    selection.overrides.sandbox_mode_summary().as_deref(),
    selection.overrides.sandbox_policy_details.as_ref(),
    &config_overrides,
    &control_plane,
    false,
  )
  .await
  .map_err(|error| error.to_string())
}

pub(crate) fn normalized_optional_cwd(cwd: &str) -> Option<&str> {
  if cwd.trim().is_empty() {
    None
  } else {
    Some(cwd)
  }
}

pub(crate) fn resolved_codex_context_cwd(cwd: Option<&str>) -> Result<String, String> {
  if let Some(cwd) = cwd {
    return Ok(cwd.to_string());
  }

  let home = std::env::var_os("HOME").ok_or_else(|| {
    "Couldn't resolve a fallback Codex config directory: HOME is not set".to_string()
  })?;
  let path = PathBuf::from(home);
  if path.is_dir() {
    Ok(path.display().to_string())
  } else {
    Err(format!(
      "Couldn't resolve a fallback Codex config directory: HOME is not a usable directory ({})",
      path.display()
    ))
  }
}

pub fn serialize_codex_overrides(overrides: &CodexSessionOverrides) -> Option<String> {
  if overrides == &CodexSessionOverrides::default() {
    None
  } else {
    serde_json::to_string(overrides).ok()
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

fn effective_settings(
  config: &CoreConfig,
  selection: &CodexConfigSelection,
) -> CodexResolvedSettings {
  let mut overrides = selection.overrides.clone();
  if overrides.approvals_reviewer.is_none() {
    overrides.approvals_reviewer = Some(core_approvals_reviewer_to_protocol(
      config.approvals_reviewer,
    ));
  }

  let explicit_sandbox_policy = requested_sandbox_policy_details(
    selection.overrides.sandbox_mode_summary().as_deref(),
    selection.overrides.sandbox_policy_details.as_ref(),
  );
  let effective_sandbox_policy = explicit_sandbox_policy.clone().or_else(|| {
    Some(core_sandbox_policy_to_details(
      &config.permissions.sandbox_policy,
    ))
  });
  let effective_sandbox_mode = explicit_sandbox_policy
    .as_ref()
    .map(CodexSandboxPolicy::legacy_summary)
    .or_else(|| {
      config_loader_sandbox_mode(
        selection.overrides.sandbox_mode_summary().as_deref(),
        selection.overrides.sandbox_policy_details.as_ref(),
      )
    })
    .or_else(|| {
      Some(core_sandbox_policy_to_string(
        &config.permissions.sandbox_policy,
      ))
    });

  CodexResolvedSettings {
    config_source: selection.config_source,
    config_mode: selection.config_mode,
    config_profile: config.active_profile.clone(),
    overrides,
    model: config.model.clone(),
    model_provider: Some(config.model_provider_id.clone()),
    approval_policy: Some(core_approval_policy_to_string(
      *config.permissions.approval_policy.get(),
    )),
    approval_policy_details: Some(core_approval_policy_to_details(
      *config.permissions.approval_policy.get(),
    )),
    sandbox_mode: effective_sandbox_mode,
    sandbox_policy_details: effective_sandbox_policy,
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
  if selection.overrides.approval_policy_details.is_some() {
    origins.insert(
      "approval_policy".to_string(),
      runtime_origin("approval_policy"),
    );
  }
  if selection.overrides.sandbox_policy_details.is_some() {
    origins.insert("sandbox_mode".to_string(), runtime_origin("sandbox_mode"));
  }
  if selection.overrides.sandbox_policy_details.is_some() {
    origins.insert(
      "sandbox_policy_details".to_string(),
      runtime_origin("sandbox_policy_details"),
    );
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
  if let Some(approval_policy) = selection.overrides.approval_policy_summary() {
    config.insert(
      "approval_policy".to_string(),
      Value::String(approval_policy),
    );
  }
  if let Some(sandbox_mode) = selection.overrides.sandbox_mode_summary() {
    config.insert("sandbox_mode".to_string(), Value::String(sandbox_mode));
  }
  if let Some(sandbox_policy_details) = &selection.overrides.sandbox_policy_details {
    if let Ok(value) = serde_json::to_value(sandbox_policy_details) {
      config.insert("sandbox_policy_details".to_string(), value);
    }
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

fn core_approvals_reviewer_to_protocol(
  reviewer: codex_core::config::ApprovalsReviewer,
) -> CodexApprovalsReviewer {
  match reviewer {
    codex_core::config::ApprovalsReviewer::User => CodexApprovalsReviewer::User,
    codex_core::config::ApprovalsReviewer::GuardianSubagent => {
      CodexApprovalsReviewer::GuardianSubagent
    }
  }
}

fn core_approval_policy_to_string(value: codex_protocol::protocol::AskForApproval) -> String {
  match value {
    codex_protocol::protocol::AskForApproval::UnlessTrusted => "untrusted",
    codex_protocol::protocol::AskForApproval::OnFailure => "on-failure",
    codex_protocol::protocol::AskForApproval::OnRequest => "on-request",
    codex_protocol::protocol::AskForApproval::Granular(_) => "reject",
    codex_protocol::protocol::AskForApproval::Never => "never",
  }
  .to_string()
}

fn core_approval_policy_to_details(
  value: codex_protocol::protocol::AskForApproval,
) -> CodexApprovalPolicy {
  match value {
    codex_protocol::protocol::AskForApproval::UnlessTrusted => {
      CodexApprovalPolicy::Mode(CodexApprovalMode::Untrusted)
    }
    codex_protocol::protocol::AskForApproval::OnFailure => {
      CodexApprovalPolicy::Mode(CodexApprovalMode::OnFailure)
    }
    codex_protocol::protocol::AskForApproval::OnRequest => {
      CodexApprovalPolicy::Mode(CodexApprovalMode::OnRequest)
    }
    codex_protocol::protocol::AskForApproval::Granular(config) => CodexApprovalPolicy::Granular {
      granular: CodexGranularApprovalPolicy {
        sandbox_approval: config.sandbox_approval,
        rules: config.rules,
        skill_approval: config.skill_approval,
        request_permissions: config.request_permissions,
        mcp_elicitations: config.mcp_elicitations,
      },
    },
    codex_protocol::protocol::AskForApproval::Never => {
      CodexApprovalPolicy::Mode(CodexApprovalMode::Never)
    }
  }
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

fn core_sandbox_policy_to_details(
  value: &codex_protocol::protocol::SandboxPolicy,
) -> CodexSandboxPolicy {
  match value {
    codex_protocol::protocol::SandboxPolicy::DangerFullAccess => CodexSandboxPolicy {
      mode: CodexSandboxMode::DangerFullAccess,
      network_access: true,
    },
    codex_protocol::protocol::SandboxPolicy::ReadOnly { network_access, .. } => {
      CodexSandboxPolicy {
        mode: CodexSandboxMode::ReadOnly,
        network_access: *network_access,
      }
    }
    codex_protocol::protocol::SandboxPolicy::WorkspaceWrite { network_access, .. } => {
      CodexSandboxPolicy {
        mode: CodexSandboxMode::WorkspaceWrite,
        network_access: *network_access,
      }
    }
    codex_protocol::protocol::SandboxPolicy::ExternalSandbox { network_access, .. } => {
      CodexSandboxPolicy {
        mode: CodexSandboxMode::ExternalSandbox,
        network_access: network_access.is_enabled(),
      }
    }
  }
}

fn service_tier_to_string(value: codex_protocol::config_types::ServiceTier) -> String {
  value.to_string()
}

fn reasoning_effort_to_string(value: codex_protocol::openai_models::ReasoningEffort) -> String {
  value.to_string()
}
