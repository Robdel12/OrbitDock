use codex_app_server_protocol::{
  DynamicToolSpec as AppServerDynamicToolSpec, SandboxMode as AppServerSandboxMode,
  ThreadResumeParams, ThreadStartParams, ThreadStartSource,
};
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_exec_server::{EnvironmentManager, EnvironmentManagerArgs, ExecServerRuntimePaths};
use codex_features::Feature;
use codex_model_provider_info::ModelProviderInfo;
use codex_protocol::config_types::{ApprovalsReviewer, Personality, ReasoningSummary, ServiceTier};
use codex_protocol::openai_models::{
  default_input_modalities, ApplyPatchToolType, ConfigShellToolType, ModelInfo,
  ModelInstructionsVariables, ModelMessages, ModelVisibility, ModelsResponse,
  TruncationPolicyConfig, WebSearchToolType,
};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::collections::HashMap;
use tracing::warn;

use super::policy_bridge::parse_approval_policy_with_details;
use super::{CodexConfigOverrides, CodexConnector, CodexRuntimeOverrides};
use orbitdock_connector_core::ConnectorError;
use orbitdock_protocol::{CodexSandboxMode, CodexSandboxPolicy};

const DEFAULT_CODEX_SHOW_RAW_REASONING: bool = true;
const DEFAULT_CODEX_HIDE_REASONING: bool = false;
const DEFAULT_CODEX_REASONING_SUMMARY: &str = "detailed";
const REASONING_SUMMARY_NONE: &str = "none";
const ENV_CODEX_SHOW_RAW_REASONING: &str = "ORBITDOCK_CODEX_SHOW_RAW_REASONING";
const ENV_CODEX_HIDE_REASONING: &str = "ORBITDOCK_CODEX_HIDE_REASONING";
const ENV_CODEX_REASONING_SUMMARY: &str = "ORBITDOCK_CODEX_REASONING_SUMMARY";
const ENV_CODEX_ENABLE_APP_CONNECTORS: &str = "ORBITDOCK_CODEX_ENABLE_APP_CONNECTORS";
const ORBITDOCK_OPENROUTER_SITE_URL: &str = "https://orbitdock.dev";
const ORBITDOCK_OPENROUTER_TITLE: &str = "OrbitDock";
const ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS: &str =
  include_str!("../prompts/external_model_instructions.md");
const ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER: &str = "{{ personality }}";
const ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE: &str =
  "You optimize for team morale and being a supportive teammate as much as code quality.";
const ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE: &str =
  "You are a deeply pragmatic, effective software engineer.";

pub fn requested_sandbox_policy_details(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<CodexSandboxPolicy> {
  sandbox_policy_details
    .cloned()
    .or_else(|| sandbox_mode.and_then(CodexSandboxPolicy::from_storage_text))
}

pub fn config_loader_sandbox_mode(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<String> {
  if let Some(details) = requested_sandbox_policy_details(sandbox_mode, sandbox_policy_details) {
    return match details.mode {
      CodexSandboxMode::DangerFullAccess => Some("danger-full-access".to_string()),
      CodexSandboxMode::ReadOnly => Some("read-only".to_string()),
      CodexSandboxMode::WorkspaceWrite => Some("workspace-write".to_string()),
      CodexSandboxMode::ExternalSandbox => None,
    };
  }

  sandbox_mode
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(ToOwned::to_owned)
}

#[cfg(test)]
fn override_cwd(cwd: &str) -> Option<std::path::PathBuf> {
  let trimmed = cwd.trim();
  if trimmed.is_empty() {
    None
  } else {
    Some(std::path::PathBuf::from(trimmed))
  }
}

fn convert_app_server_type<T, U>(value: T, label: &str) -> Result<U, ConnectorError>
where
  T: Serialize,
  U: DeserializeOwned,
{
  serde_json::from_value(serde_json::to_value(value).map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to encode Codex {label}: {error}"))
  })?)
  .map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to convert Codex {label} for app-server: {error}"
    ))
  })
}

fn convert_optional<T, U>(value: Option<T>, label: &str) -> Result<Option<U>, ConnectorError>
where
  T: Serialize,
  U: DeserializeOwned,
{
  value
    .map(|inner| convert_app_server_type(inner, label))
    .transpose()
}

fn app_server_sandbox_mode(
  sandbox_mode: Option<&str>,
  sandbox_policy_details: Option<&CodexSandboxPolicy>,
) -> Option<AppServerSandboxMode> {
  requested_sandbox_policy_details(sandbox_mode, sandbox_policy_details)
    .map(|details| match details.mode {
      CodexSandboxMode::DangerFullAccess => AppServerSandboxMode::DangerFullAccess,
      CodexSandboxMode::ReadOnly => AppServerSandboxMode::ReadOnly,
      CodexSandboxMode::WorkspaceWrite => AppServerSandboxMode::WorkspaceWrite,
      CodexSandboxMode::ExternalSandbox => AppServerSandboxMode::WorkspaceWrite,
    })
    .or_else(|| {
      match sandbox_mode
        .map(str::trim)
        .filter(|value| !value.is_empty())
      {
        Some("danger-full-access") => Some(AppServerSandboxMode::DangerFullAccess),
        Some("read-only") | Some("read-only-network") => Some(AppServerSandboxMode::ReadOnly),
        Some("workspace-write")
        | Some("workspace-write-network")
        | Some("external-sandbox")
        | Some("external-sandbox-network") => Some(AppServerSandboxMode::WorkspaceWrite),
        _ => None,
      }
    })
}

pub struct ResumeConnectorWithToolsConfig<'a> {
  pub cwd: &'a str,
  pub thread_id: &'a str,
  pub model: Option<&'a str>,
  pub approval_policy: Option<&'a str>,
  pub sandbox_mode: Option<&'a str>,
  pub sandbox_policy_details: Option<&'a CodexSandboxPolicy>,
  pub config_overrides: &'a CodexConfigOverrides,
  pub runtime_overrides: CodexRuntimeOverrides,
  pub dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
}

impl CodexConnector {
  pub(crate) fn embedded_codex_self_exe() -> Result<std::path::PathBuf, ConnectorError> {
    std::env::current_exe().map_err(|error| {
      ConnectorError::ProviderError(format!(
        "Failed to resolve OrbitDock executable for Codex helpers: {error}"
      ))
    })
  }

  pub(crate) fn embedded_codex_runtime_paths() -> Result<ExecServerRuntimePaths, ConnectorError> {
    let codex_self_exe = Self::embedded_codex_self_exe()?;
    ExecServerRuntimePaths::new(codex_self_exe, None).map_err(|error| {
      ConnectorError::ProviderError(format!(
        "Failed to configure Codex helper runtime paths: {error}"
      ))
    })
  }

  pub(crate) fn embedded_environment_manager() -> Result<EnvironmentManager, ConnectorError> {
    Ok(EnvironmentManager::new(EnvironmentManagerArgs::from_env(
      Self::embedded_codex_runtime_paths()?,
    )))
  }

  pub async fn new(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_and_runtime_overrides(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      None,
      &CodexConfigOverrides::default(),
      CodexRuntimeOverrides::default(),
    )
    .await
  }

  pub async fn new_with_config_overrides(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_and_runtime_overrides(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      None,
      config_overrides,
      CodexRuntimeOverrides::default(),
    )
    .await
  }

  pub async fn new_with_runtime_overrides(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    runtime_overrides: CodexRuntimeOverrides,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_and_runtime_overrides(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      None,
      &CodexConfigOverrides::default(),
      runtime_overrides,
    )
    .await
  }

  pub async fn new_with_config_overrides_and_runtime_overrides(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    sandbox_policy_details: Option<&CodexSandboxPolicy>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: CodexRuntimeOverrides,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_runtime_overrides_and_tools(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details,
      config_overrides,
      runtime_overrides,
      Vec::new(),
    )
    .await
  }

  pub async fn new_with_runtime_overrides_and_tools(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    sandbox_policy_details: Option<&CodexSandboxPolicy>,
    runtime_overrides: CodexRuntimeOverrides,
    dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_runtime_overrides_and_tools(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details,
      &CodexConfigOverrides::default(),
      runtime_overrides,
      dynamic_tools,
    )
    .await
  }

  #[allow(clippy::too_many_arguments)]
  pub async fn new_with_config_overrides_runtime_overrides_and_tools(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    sandbox_policy_details: Option<&CodexSandboxPolicy>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: CodexRuntimeOverrides,
    dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  ) -> Result<Self, ConnectorError> {
    let codex_home = find_codex_home()
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;

    let app_server =
      crate::app_server::shared_app_server(cwd, config_overrides, &runtime_overrides).await?;
    let approval_policy =
      parse_approval_policy_with_details(approval_policy, None).map_err(|error| {
        ConnectorError::ProviderError(format!("Invalid approval policy: {error}"))
      })?;
    let response = app_server
      .thread_start(ThreadStartParams {
        model: model.map(ToString::to_string),
        model_provider: config_overrides.model_provider.clone(),
        service_tier: convert_optional(
          parse_service_tier_override(runtime_overrides.service_tier.as_deref()),
          "service tier",
        )?,
        cwd: Some(cwd.to_string()),
        approval_policy: convert_optional(approval_policy, "approval policy")?,
        approvals_reviewer: convert_optional(
          parse_approvals_reviewer(runtime_overrides.approvals_reviewer.as_deref()),
          "approvals reviewer",
        )?,
        sandbox: app_server_sandbox_mode(sandbox_mode, sandbox_policy_details),
        permission_profile: None,
        config: None,
        service_name: None,
        base_instructions: None,
        developer_instructions: runtime_overrides.developer_instructions.clone(),
        personality: convert_optional(
          parse_personality(runtime_overrides.personality.as_deref()),
          "personality",
        )?,
        ephemeral: None,
        session_start_source: Some(ThreadStartSource::Startup),
        environments: None,
        dynamic_tools: Some(convert_app_server_type::<_, Vec<AppServerDynamicToolSpec>>(
          dynamic_tools,
          "dynamic tools",
        )?),
        mock_experimental_field: None,
        experimental_raw_events: false,
        persist_extended_history: true,
      })
      .await?;

    let reasoning_effort = convert_optional(response.reasoning_effort, "reasoning effort")?;
    Self::from_app_server_thread(
      app_server,
      response.thread.id,
      codex_home.to_path_buf(),
      cwd,
      Some(response.model),
      reasoning_effort,
    )
    .await
  }

  pub async fn resume(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
  ) -> Result<Self, ConnectorError> {
    let default_overrides = CodexConfigOverrides::default();
    Self::resume_with_config_overrides_runtime_overrides_and_tools(ResumeConnectorWithToolsConfig {
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details: None,
      config_overrides: &default_overrides,
      runtime_overrides: CodexRuntimeOverrides::default(),
      dynamic_tools: Vec::new(),
    })
    .await
  }

  pub async fn resume_with_config_overrides(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
  ) -> Result<Self, ConnectorError> {
    Self::resume_with_config_overrides_runtime_overrides_and_tools(ResumeConnectorWithToolsConfig {
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details: None,
      config_overrides,
      runtime_overrides: CodexRuntimeOverrides::default(),
      dynamic_tools: Vec::new(),
    })
    .await
  }

  pub async fn resume_with_runtime_overrides(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    runtime_overrides: CodexRuntimeOverrides,
  ) -> Result<Self, ConnectorError> {
    let default_overrides = CodexConfigOverrides::default();
    Self::resume_with_config_overrides_runtime_overrides_and_tools(ResumeConnectorWithToolsConfig {
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details: None,
      config_overrides: &default_overrides,
      runtime_overrides,
      dynamic_tools: Vec::new(),
    })
    .await
  }

  pub async fn resume_with_config_overrides_and_runtime_overrides(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: CodexRuntimeOverrides,
  ) -> Result<Self, ConnectorError> {
    Self::resume_with_config_overrides_runtime_overrides_and_tools(ResumeConnectorWithToolsConfig {
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details: None,
      config_overrides,
      runtime_overrides,
      dynamic_tools: Vec::new(),
    })
    .await
  }

  pub async fn resume_with_config_overrides_runtime_overrides_and_tools(
    params: ResumeConnectorWithToolsConfig<'_>,
  ) -> Result<Self, ConnectorError> {
    let ResumeConnectorWithToolsConfig {
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details,
      config_overrides,
      runtime_overrides,
      dynamic_tools,
    } = params;

    let codex_home = find_codex_home()
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;

    if !dynamic_tools.is_empty() {
      match codex_protocol::ThreadId::try_from(thread_id) {
        Ok(resume_thread_id) => {
          let config = Self::build_config(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            sandbox_policy_details,
            config_overrides,
            &runtime_overrides,
          )
          .await?;
          if let Some(state_db) = codex_core::get_state_db(&config).await {
            if let Err(err) = state_db
              .persist_dynamic_tools(resume_thread_id, Some(dynamic_tools.as_slice()))
              .await
            {
              warn!(
                thread_id = %thread_id,
                error = %err,
                "Failed to persist Codex dynamic tools for resumed thread"
              );
            }
          }
        }
        Err(err) => {
          warn!(
            thread_id = %thread_id,
            error = %err,
            "Failed to parse thread id for resume dynamic tool persistence"
          );
        }
      }
    }

    let app_server =
      crate::app_server::shared_app_server(cwd, config_overrides, &runtime_overrides).await?;
    let approval_policy =
      parse_approval_policy_with_details(approval_policy, None).map_err(|error| {
        ConnectorError::ProviderError(format!("Invalid approval policy: {error}"))
      })?;
    let response = app_server
      .thread_resume(ThreadResumeParams {
        thread_id: thread_id.to_string(),
        history: None,
        path: None,
        model: model.map(ToString::to_string),
        model_provider: config_overrides.model_provider.clone(),
        service_tier: convert_optional(
          parse_service_tier_override(runtime_overrides.service_tier.as_deref()),
          "service tier",
        )?,
        cwd: Some(cwd.to_string()),
        approval_policy: convert_optional(approval_policy, "approval policy")?,
        approvals_reviewer: convert_optional(
          parse_approvals_reviewer(runtime_overrides.approvals_reviewer.as_deref()),
          "approvals reviewer",
        )?,
        sandbox: app_server_sandbox_mode(sandbox_mode, sandbox_policy_details),
        permission_profile: None,
        config: None,
        base_instructions: None,
        developer_instructions: runtime_overrides.developer_instructions.clone(),
        personality: convert_optional(
          parse_personality(runtime_overrides.personality.as_deref()),
          "personality",
        )?,
        exclude_turns: false,
        persist_extended_history: true,
      })
      .await?;

    let reasoning_effort = convert_optional(response.reasoning_effort, "reasoning effort")?;
    Self::from_app_server_thread(
      app_server,
      response.thread.id,
      codex_home.to_path_buf(),
      cwd,
      Some(response.model),
      reasoning_effort,
    )
    .await
  }

  pub async fn build_config(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    sandbox_policy_details: Option<&CodexSandboxPolicy>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: &CodexRuntimeOverrides,
  ) -> Result<Config, ConnectorError> {
    Self::build_config_with_runtime_defaults(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      sandbox_policy_details,
      config_overrides,
      runtime_overrides,
      true,
    )
    .await
  }

  #[allow(clippy::too_many_arguments)]
  pub async fn build_config_with_runtime_defaults(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    sandbox_policy_details: Option<&CodexSandboxPolicy>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: &CodexRuntimeOverrides,
    apply_runtime_defaults: bool,
  ) -> Result<Config, ConnectorError> {
    let mut cli_overrides = Vec::new();

    if let Some(model) = model {
      cli_overrides.push(("model".to_string(), toml::Value::String(model.to_string())));
    }

    if let Some(policy) = approval_policy.or(if apply_runtime_defaults {
      Some("untrusted")
    } else {
      None
    }) {
      cli_overrides.push((
        "approval_policy".to_string(),
        toml::Value::String(policy.to_string()),
      ));
    }

    if let Some(sandbox) = config_loader_sandbox_mode(sandbox_mode, sandbox_policy_details) {
      cli_overrides.push(("sandbox_mode".to_string(), toml::Value::String(sandbox)));
    }

    if let Some(effort) = runtime_overrides.effort.as_deref() {
      cli_overrides.push((
        "model_reasoning_effort".to_string(),
        toml::Value::String(effort.to_string()),
      ));
    }

    if let Some(reviewer) = runtime_overrides.approvals_reviewer.as_deref() {
      cli_overrides.push((
        "approvals_reviewer".to_string(),
        toml::Value::String(reviewer.to_string()),
      ));
    }

    if apply_runtime_defaults {
      let show_raw_reasoning =
        parse_bool_env(ENV_CODEX_SHOW_RAW_REASONING).unwrap_or(DEFAULT_CODEX_SHOW_RAW_REASONING);
      let hide_reasoning =
        parse_bool_env(ENV_CODEX_HIDE_REASONING).unwrap_or(DEFAULT_CODEX_HIDE_REASONING);
      let mut reasoning_summary = parse_reasoning_summary_env(ENV_CODEX_REASONING_SUMMARY)
        .unwrap_or_else(|| DEFAULT_CODEX_REASONING_SUMMARY.to_string());
      if model_rejects_reasoning_summary(model) {
        reasoning_summary = REASONING_SUMMARY_NONE.to_string();
      }

      cli_overrides.push((
        "show_raw_agent_reasoning".to_string(),
        toml::Value::Boolean(show_raw_reasoning),
      ));
      cli_overrides.push((
        "hide_agent_reasoning".to_string(),
        toml::Value::Boolean(hide_reasoning),
      ));
      cli_overrides.push((
        "model_reasoning_summary".to_string(),
        toml::Value::String(reasoning_summary),
      ));
    }

    if let Some(multi_agent) = runtime_overrides.multi_agent {
      cli_overrides.push((
        "features.multi_agent".to_string(),
        toml::Value::Boolean(multi_agent),
      ));
    }

    let embedded_codex_self_exe = Self::embedded_codex_self_exe()?;
    let build_harness_overrides = || ConfigOverrides {
      cwd: Some(std::path::PathBuf::from(cwd)),
      model: model.map(str::to_string),
      model_provider: config_overrides.model_provider.clone(),
      service_tier: parse_service_tier_override(runtime_overrides.service_tier.as_deref()),
      config_profile: config_overrides.config_profile.clone(),
      developer_instructions: runtime_overrides.developer_instructions.clone(),
      personality: parse_personality(runtime_overrides.personality.as_deref()),
      codex_self_exe: Some(embedded_codex_self_exe.clone()),
      codex_linux_sandbox_exe: None,
      ..Default::default()
    };

    let harness = build_harness_overrides();
    tracing::debug!(
      component = "codex_config",
      event = "build_config.inputs",
      harness_model = ?harness.model,
      cli_model_override = ?model,
      profile = ?harness.config_profile,
      "Building effective codex config"
    );
    let mut config =
      Config::load_with_cli_overrides_and_harness_overrides(cli_overrides.clone(), harness)
        .await
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to load config: {}", e)))?;
    tracing::debug!(
      component = "codex_config",
      event = "build_config.resolved",
      resolved_model = ?config.model,
      active_profile = ?config.active_profile,
      "Config resolved after load"
    );
    apply_orbitdock_provider_defaults(&mut config);
    apply_orbitdock_external_model_defaults(&mut config);
    apply_orbitdock_embedded_runtime_defaults(
      &mut config,
      parse_bool_env(ENV_CODEX_ENABLE_APP_CONNECTORS).unwrap_or(false),
    );
    let forced_apply_patch_feature = ensure_apply_patch_feature_for_custom_models(&mut config);
    let _ = forced_apply_patch_feature;

    Ok(config)
  }
}

pub async fn discover_models() -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError>
{
  discover_models_for_context(None, None).await
}

pub async fn discover_models_for_context(
  cwd: Option<&str>,
  model_provider: Option<&str>,
) -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError> {
  let app_server = crate::app_server::shared_app_server(
    cwd.unwrap_or("."),
    &CodexConfigOverrides {
      model_provider: model_provider.map(str::to_string),
      config_profile: None,
    },
    &CodexRuntimeOverrides::default(),
  )
  .await?;

  let models = app_server
    .model_list(false)
    .await?
    .data
    .into_iter()
    .filter(|model| !model.hidden)
    .map(|model| {
      let supported_reasoning_efforts = model
        .supported_reasoning_efforts
        .into_iter()
        .map(|effort| effort.reasoning_effort.to_string())
        .collect();
      let supported_service_tiers = model.additional_speed_tiers;
      let supports_reasoning_summaries = !model_rejects_reasoning_summary(Some(&model.model));

      orbitdock_protocol::CodexModelOption {
        id: model.id,
        model: model.model,
        display_name: model.display_name,
        description: model.description,
        is_default: model.is_default,
        supported_reasoning_efforts,
        supports_reasoning_summaries,
        supported_collaboration_modes: vec!["default".to_string(), "plan".to_string()],
        supports_multi_agent: true,
        multi_agent_is_experimental: true,
        supports_personality: model.supports_personality,
        supported_service_tiers,
        supports_developer_instructions: true,
      }
    })
    .collect();

  Ok(models)
}

pub(crate) fn parse_approvals_reviewer(value: Option<&str>) -> Option<ApprovalsReviewer> {
  match value.map(str::trim).filter(|value| !value.is_empty()) {
    Some("user") => Some(ApprovalsReviewer::User),
    Some("guardian_subagent") | Some("auto_review") => Some(ApprovalsReviewer::AutoReview),
    _ => None,
  }
}
pub(crate) fn apply_orbitdock_embedded_runtime_defaults(
  config: &mut Config,
  app_connectors_enabled: bool,
) {
  if app_connectors_enabled {
    return;
  }

  let _ = config.features.disable(Feature::Apps);
}

pub(crate) fn apply_orbitdock_provider_defaults(config: &mut Config) {
  let provider_id = config.model_provider_id.clone();
  let Some(provider) = config.model_providers.get_mut(&provider_id) else {
    return;
  };

  if !is_openrouter_provider(&provider_id, provider) {
    return;
  }

  let headers = provider.http_headers.get_or_insert_with(HashMap::new);
  headers
    .entry("HTTP-Referer".to_string())
    .or_insert_with(|| ORBITDOCK_OPENROUTER_SITE_URL.to_string());

  if !headers.contains_key("X-OpenRouter-Title") && !headers.contains_key("X-Title") {
    headers.insert(
      "X-OpenRouter-Title".to_string(),
      ORBITDOCK_OPENROUTER_TITLE.to_string(),
    );
  }
}

pub(crate) fn apply_orbitdock_external_model_defaults(config: &mut Config) {
  let Some(model_slug) = config.model.clone() else {
    return;
  };

  if config.model_provider_id.eq_ignore_ascii_case("openai") || config.model_provider.is_openai() {
    return;
  }

  let catalog = config
    .model_catalog
    .get_or_insert_with(|| ModelsResponse { models: Vec::new() });
  if let Some(existing_model) = catalog
    .models
    .iter_mut()
    .find(|candidate| model_slug.starts_with(&candidate.slug))
  {
    merge_external_model_instructions(existing_model);
    return;
  }

  catalog.models.push(synthetic_external_model_info(
    &model_slug,
    &config.model_provider_id,
  ));
}

fn merge_external_model_instructions(model: &mut ModelInfo) {
  model.base_instructions = merge_instruction_text(
    model.base_instructions.as_str(),
    ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS,
  );

  let external_messages = ModelMessages {
    instructions_template: Some(format!(
      "{}\n\n{}",
      ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS, ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER
    )),
    instructions_variables: Some(ModelInstructionsVariables {
      personality_default: Some(String::new()),
      personality_friendly: Some(ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE.to_string()),
      personality_pragmatic: Some(ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE.to_string()),
    }),
  };

  match model.model_messages.as_mut() {
    Some(existing) => {
      let merged_template = merge_instruction_text(
        existing
          .instructions_template
          .as_deref()
          .unwrap_or_default(),
        external_messages
          .instructions_template
          .as_deref()
          .unwrap_or_default(),
      );
      existing.instructions_template = Some(merged_template);

      let merged_variables =
        existing
          .instructions_variables
          .get_or_insert(ModelInstructionsVariables {
            personality_default: None,
            personality_friendly: None,
            personality_pragmatic: None,
          });
      if merged_variables.personality_default.is_none() {
        merged_variables.personality_default = Some(String::new());
      }
      if merged_variables.personality_friendly.is_none() {
        merged_variables.personality_friendly =
          Some(ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE.to_string());
      }
      if merged_variables.personality_pragmatic.is_none() {
        merged_variables.personality_pragmatic =
          Some(ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE.to_string());
      }
    }
    None => {
      model.model_messages = Some(external_messages);
    }
  }

  if model.apply_patch_tool_type.is_none() {
    model.apply_patch_tool_type = Some(ApplyPatchToolType::Function);
  }
}

fn merge_instruction_text(existing: &str, required: &str) -> String {
  let existing_trimmed = existing.trim();
  let required_trimmed = required.trim();

  if existing_trimmed.is_empty() {
    return required_trimmed.to_string();
  }
  if existing_trimmed.contains(required_trimmed) {
    return existing_trimmed.to_string();
  }

  format!("{}\n\n{}", existing_trimmed, required_trimmed)
}

fn synthetic_external_model_info(model_slug: &str, provider_id: &str) -> ModelInfo {
  ModelInfo {
    slug: model_slug.to_string(),
    display_name: model_slug.to_string(),
    description: Some(format!(
      "OrbitDock synthetic metadata for external provider `{provider_id}`."
    )),
    default_reasoning_level: None,
    supported_reasoning_levels: Vec::new(),
    shell_type: ConfigShellToolType::ShellCommand,
    visibility: ModelVisibility::None,
    supported_in_api: true,
    priority: 99,
    additional_speed_tiers: Vec::new(),
    availability_nux: None,
    upgrade: None,
    base_instructions: ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS.to_string(),
    model_messages: Some(ModelMessages {
      instructions_template: Some(format!(
        "{}\n\n{}",
        ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS,
        ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER
      )),
      instructions_variables: Some(ModelInstructionsVariables {
        personality_default: Some(String::new()),
        personality_friendly: Some(ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE.to_string()),
        personality_pragmatic: Some(ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE.to_string()),
      }),
    }),
    supports_reasoning_summaries: false,
    default_reasoning_summary: ReasoningSummary::Auto,
    support_verbosity: false,
    default_verbosity: None,
    apply_patch_tool_type: Some(ApplyPatchToolType::Function),
    web_search_tool_type: WebSearchToolType::Text,
    truncation_policy: TruncationPolicyConfig::bytes(10_000),
    supports_parallel_tool_calls: false,
    supports_image_detail_original: false,
    context_window: Some(272_000),
    max_context_window: Some(272_000),
    auto_compact_token_limit: None,
    effective_context_window_percent: 95,
    experimental_supported_tools: Vec::new(),
    input_modalities: default_input_modalities(),
    used_fallback_model_metadata: false,
    supports_search_tool: false,
  }
}

fn is_openai_provider(config: &Config) -> bool {
  config.model_provider_id.eq_ignore_ascii_case("openai") || config.model_provider.is_openai()
}

pub(crate) fn should_enable_apply_patch_for_custom_models(config: &Config) -> bool {
  !is_openai_provider(config)
}

pub(crate) fn ensure_apply_patch_feature_for_custom_models(config: &mut Config) -> bool {
  if !should_enable_apply_patch_for_custom_models(config) {
    return false;
  }
  if config.features.enabled(Feature::ApplyPatchFreeform) {
    return false;
  }

  match config.features.enable(Feature::ApplyPatchFreeform) {
    Ok(()) => true,
    Err(error) => {
      warn!(
        event = "codex.connector.apply_patch_feature_enable_failed",
        model_provider_id = %config.model_provider_id,
        error = %error,
        "Failed to force apply_patch feature for non-OpenAI provider"
      );
      false
    }
  }
}

pub(crate) fn is_openrouter_provider(provider_id: &str, provider: &ModelProviderInfo) -> bool {
  provider_id.eq_ignore_ascii_case("openrouter")
    || provider.name.eq_ignore_ascii_case("openrouter")
    || provider
      .base_url
      .as_ref()
      .is_some_and(|value| value.to_ascii_lowercase().contains("openrouter.ai"))
}

pub(crate) fn parse_bool_env(name: &str) -> Option<bool> {
  let raw = std::env::var(name).ok()?;
  match raw.trim().to_ascii_lowercase().as_str() {
    "1" | "true" | "yes" | "on" => Some(true),
    "0" | "false" | "no" | "off" => Some(false),
    other => {
      warn!(
        "Ignoring invalid boolean env {}={} (expected true/false, 1/0, yes/no, on/off)",
        name, other
      );
      None
    }
  }
}

pub(crate) fn parse_reasoning_summary_env(name: &str) -> Option<String> {
  let raw = std::env::var(name).ok()?;
  let value = raw.trim().to_ascii_lowercase();
  match value.as_str() {
    "auto" | "concise" | "detailed" | REASONING_SUMMARY_NONE => Some(value),
    other => {
      warn!(
        "Ignoring invalid reasoning summary env {}={} (expected auto|concise|detailed|none)",
        name, other
      );
      None
    }
  }
}

pub(crate) fn parse_reasoning_summary(value: &str) -> Option<ReasoningSummary> {
  match value.trim().to_ascii_lowercase().as_str() {
    "auto" => Some(ReasoningSummary::Auto),
    "concise" => Some(ReasoningSummary::Concise),
    "detailed" => Some(ReasoningSummary::Detailed),
    REASONING_SUMMARY_NONE => Some(ReasoningSummary::None),
    _ => None,
  }
}

pub(crate) fn preferred_reasoning_summary() -> ReasoningSummary {
  parse_reasoning_summary_env(ENV_CODEX_REASONING_SUMMARY)
    .as_deref()
    .and_then(parse_reasoning_summary)
    .unwrap_or(ReasoningSummary::Detailed)
}

pub(crate) fn model_rejects_reasoning_summary(model: Option<&str>) -> bool {
  model
    .map(|value| value.trim().to_ascii_lowercase().contains("codex-spark"))
    .unwrap_or(false)
}

pub(crate) fn reasoning_summary_for_model(
  model: Option<&str>,
  preferred: ReasoningSummary,
) -> ReasoningSummary {
  if model_rejects_reasoning_summary(model) {
    ReasoningSummary::None
  } else {
    preferred
  }
}

#[cfg(test)]
pub(crate) fn should_disable_reasoning_summary(
  model: Option<&str>,
  supports_reasoning_summaries: bool,
) -> bool {
  !supports_reasoning_summaries || model_rejects_reasoning_summary(model)
}

pub(crate) fn parse_personality(value: Option<&str>) -> Option<Personality> {
  value
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(str::to_ascii_lowercase)
    .as_deref()
    .and_then(|value| match value {
      "none" => Some(Personality::None),
      "friendly" => Some(Personality::Friendly),
      "pragmatic" => Some(Personality::Pragmatic),
      _ => None,
    })
}

pub(crate) fn parse_service_tier_override(value: Option<&str>) -> Option<Option<ServiceTier>> {
  value
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(str::to_ascii_lowercase)
    .and_then(|value| match value.as_str() {
      "none" | "off" => Some(None),
      "fast" => Some(Some(ServiceTier::Fast)),
      "flex" => Some(Some(ServiceTier::Flex)),
      _ => None,
    })
}

#[cfg(test)]
mod tests {
  use super::{config_loader_sandbox_mode, override_cwd, requested_sandbox_policy_details};
  use orbitdock_protocol::{CodexSandboxMode, CodexSandboxPolicy};

  #[test]
  fn config_loader_sandbox_mode_preserves_supported_base_values() {
    assert_eq!(
      config_loader_sandbox_mode(Some("workspace-write"), None),
      Some("workspace-write".to_string())
    );
    assert_eq!(
      config_loader_sandbox_mode(Some("danger-full-access"), None),
      Some("danger-full-access".to_string())
    );
  }

  #[test]
  fn config_loader_sandbox_mode_strips_network_suffixes() {
    assert_eq!(
      config_loader_sandbox_mode(Some("workspace-write-network"), None),
      Some("workspace-write".to_string())
    );
    assert_eq!(
      config_loader_sandbox_mode(Some("read-only-network"), None),
      Some("read-only".to_string())
    );
  }

  #[test]
  fn config_loader_sandbox_mode_omits_external_sandbox() {
    assert_eq!(
      config_loader_sandbox_mode(Some("external-sandbox"), None),
      None
    );
    assert_eq!(
      config_loader_sandbox_mode(Some("external-sandbox-network"), None),
      None
    );
  }

  #[test]
  fn requested_sandbox_policy_details_prefer_explicit_details() {
    let details = CodexSandboxPolicy {
      mode: CodexSandboxMode::ExternalSandbox,
      network_access: true,
    };
    assert_eq!(
      requested_sandbox_policy_details(Some("workspace-write"), Some(&details)),
      Some(details)
    );
  }

  #[test]
  fn override_cwd_uses_session_workspace_for_runtime_overrides() {
    assert_eq!(
      override_cwd(" /Users/robertdeluca/Developer/OrbitDock "),
      Some(std::path::PathBuf::from(
        "/Users/robertdeluca/Developer/OrbitDock"
      ))
    );
    assert_eq!(override_cwd("  "), None);
  }
}
