use std::collections::HashMap;
use std::sync::Arc;

use codex_core::auth::AuthCredentialsStoreMode;
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_features::Feature;
use codex_core::models_manager::collaboration_mode_presets::CollaborationModesConfig;
use codex_core::models_manager::manager::RefreshStrategy;
use codex_core::{AuthManager, ModelProviderInfo, ThreadManager};
use codex_exec_server::EnvironmentManager;
use codex_protocol::config_types::{
  ApprovalsReviewer, CollaborationMode, CollaborationModeMask, ModeKind, Personality,
  ReasoningSummary, ServiceTier, Settings,
};
use codex_protocol::openai_models::{
  ApplyPatchToolType, ConfigShellToolType, ModelInfo, ModelInstructionsVariables, ModelMessages,
  ModelVisibility, ModelsResponse, ReasoningEffort, TruncationPolicyConfig, WebSearchToolType,
  default_input_modalities,
};
use codex_protocol::protocol::{Op, SessionSource};
use tracing::{info, warn};

use super::{CodexConfigOverrides, CodexConnector, CodexControlPlane};
use orbitdock_connector_core::ConnectorError;

const DEFAULT_CODEX_SHOW_RAW_REASONING: bool = true;
const DEFAULT_CODEX_HIDE_REASONING: bool = false;
const DEFAULT_CODEX_REASONING_SUMMARY: &str = "detailed";
const REASONING_SUMMARY_NONE: &str = "none";
const ENV_CODEX_SHOW_RAW_REASONING: &str = "ORBITDOCK_CODEX_SHOW_RAW_REASONING";
const ENV_CODEX_HIDE_REASONING: &str = "ORBITDOCK_CODEX_HIDE_REASONING";
const ENV_CODEX_REASONING_SUMMARY: &str = "ORBITDOCK_CODEX_REASONING_SUMMARY";
const ORBITDOCK_CODEX_AUTH_STORE_MODE: AuthCredentialsStoreMode = AuthCredentialsStoreMode::File;
const ORBITDOCK_OPENROUTER_SITE_URL: &str = "https://orbitdock.dev";
const ORBITDOCK_OPENROUTER_TITLE: &str = "OrbitDock";
const ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS: &str =
  include_str!("../prompts/external_model_instructions.md");
const ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER: &str = "{{ personality }}";
const ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE: &str =
  "You optimize for team morale and being a supportive teammate as much as code quality.";
const ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE: &str =
  "You are a deeply pragmatic, effective software engineer.";

struct ProviderRouteDebugInfo {
  provider_id: String,
  provider_name: Option<String>,
  base_url: Option<String>,
  wire_api: String,
  query_param_keys: Vec<String>,
  http_header_names: Vec<String>,
  env_http_header_names: Vec<String>,
  has_orbitdock_openrouter_referer: bool,
  has_orbitdock_openrouter_title: bool,
}

impl CodexConnector {
  pub async fn new(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_and_control_plane(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      &CodexConfigOverrides::default(),
      CodexControlPlane::default(),
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
    Self::new_with_config_overrides_and_control_plane(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      CodexControlPlane::default(),
    )
    .await
  }

  pub async fn new_with_control_plane(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    control_plane: CodexControlPlane,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_and_control_plane(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      &CodexConfigOverrides::default(),
      control_plane,
    )
    .await
  }

  pub async fn new_with_config_overrides_and_control_plane(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    control_plane: CodexControlPlane,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_control_plane_and_tools(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      control_plane,
      Vec::new(),
    )
    .await
  }

  pub async fn new_with_control_plane_and_tools(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    control_plane: CodexControlPlane,
    dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  ) -> Result<Self, ConnectorError> {
    Self::new_with_config_overrides_control_plane_and_tools(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      &CodexConfigOverrides::default(),
      control_plane,
      dynamic_tools,
    )
    .await
  }

  pub async fn new_with_config_overrides_control_plane_and_tools(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    control_plane: CodexControlPlane,
    dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  ) -> Result<Self, ConnectorError> {
    info!("Creating codex-core connector for {}", cwd);

    let codex_home = find_codex_home()
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;

    let auth_manager = Arc::new(AuthManager::new(
      codex_home.clone(),
      true,
      ORBITDOCK_CODEX_AUTH_STORE_MODE,
    ));

    let mut config = Self::build_config(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      &control_plane,
    )
    .await?;

    let thread_manager = Arc::new(ThreadManager::new(
      &config,
      auth_manager.clone(),
      SessionSource::Mcp,
      CollaborationModesConfig::default(),
      Arc::new(EnvironmentManager::new(None)),
    ));
    Self::finalize_reasoning_summary(&mut config, thread_manager.as_ref()).await;
    log_provider_route("start", cwd, &config);

    let configured_model = config.model.clone();
    let new_thread = thread_manager
      .start_thread_with_tools(config, dynamic_tools, false)
      .await
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to start thread: {}", e)))?;

    let connector = Self::from_thread(new_thread, thread_manager, codex_home)?;
    connector
      .apply_post_start_control_plane(control_plane, configured_model, None)
      .await?;
    Ok(connector)
  }

  pub async fn resume(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
  ) -> Result<Self, ConnectorError> {
    Self::resume_with_config_overrides_and_control_plane(
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      &CodexConfigOverrides::default(),
      CodexControlPlane::default(),
    )
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
    Self::resume_with_config_overrides_and_control_plane(
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      CodexControlPlane::default(),
    )
    .await
  }

  pub async fn resume_with_control_plane(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    control_plane: CodexControlPlane,
  ) -> Result<Self, ConnectorError> {
    Self::resume_with_config_overrides_and_control_plane(
      cwd,
      thread_id,
      model,
      approval_policy,
      sandbox_mode,
      &CodexConfigOverrides::default(),
      control_plane,
    )
    .await
  }

  pub async fn resume_with_config_overrides_and_control_plane(
    cwd: &str,
    thread_id: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    control_plane: CodexControlPlane,
  ) -> Result<Self, ConnectorError> {
    info!(
      "Resuming codex-core connector for {} with thread {}",
      cwd, thread_id
    );

    let codex_home = find_codex_home()
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;

    let rollout_path = codex_core::find_thread_path_by_id_str(&codex_home, thread_id)
      .await
      .map_err(|e| {
        ConnectorError::ProviderError(format!("Failed to find rollout for thread: {}", e))
      })?
      .ok_or_else(|| {
        ConnectorError::ProviderError(format!("No rollout file found for thread {}", thread_id))
      })?;

    info!("Found rollout at {:?}", rollout_path);

    let auth_manager = Arc::new(AuthManager::new(
      codex_home.clone(),
      true,
      ORBITDOCK_CODEX_AUTH_STORE_MODE,
    ));

    let mut config = Self::build_config(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      &control_plane,
    )
    .await?;

    let thread_manager = Arc::new(ThreadManager::new(
      &config,
      auth_manager.clone(),
      SessionSource::Mcp,
      CollaborationModesConfig::default(),
      Arc::new(EnvironmentManager::new(None)),
    ));
    Self::finalize_reasoning_summary(&mut config, thread_manager.as_ref()).await;
    log_provider_route("resume", cwd, &config);

    let configured_model = config.model.clone();
    let new_thread = thread_manager
      .resume_thread_from_rollout(config, rollout_path, auth_manager, None)
      .await
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to resume thread: {}", e)))?;

    let connector = Self::from_thread(new_thread, thread_manager, codex_home)?;
    connector
      .apply_post_start_control_plane(control_plane, configured_model, None)
      .await?;
    Ok(connector)
  }

  pub async fn build_config(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    control_plane: &CodexControlPlane,
  ) -> Result<Config, ConnectorError> {
    Self::build_config_with_runtime_defaults(
      cwd,
      model,
      approval_policy,
      sandbox_mode,
      config_overrides,
      control_plane,
      true,
    )
    .await
  }

  pub async fn build_config_with_runtime_defaults(
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    config_overrides: &CodexConfigOverrides,
    control_plane: &CodexControlPlane,
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

    if let Some(sandbox) = sandbox_mode {
      cli_overrides.push((
        "sandbox_mode".to_string(),
        toml::Value::String(sandbox.to_string()),
      ));
    }

    if let Some(effort) = control_plane.effort.as_deref() {
      cli_overrides.push((
        "model_reasoning_effort".to_string(),
        toml::Value::String(effort.to_string()),
      ));
    }

    if let Some(reviewer) = control_plane.approvals_reviewer.as_deref() {
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

    if let Some(multi_agent) = control_plane.multi_agent {
      cli_overrides.push((
        "features.multi_agent".to_string(),
        toml::Value::Boolean(multi_agent),
      ));
    }

    let build_harness_overrides = || ConfigOverrides {
      cwd: Some(std::path::PathBuf::from(cwd)),
      model_provider: config_overrides.model_provider.clone(),
      service_tier: parse_service_tier_override(control_plane.service_tier.as_deref()),
      config_profile: config_overrides.config_profile.clone(),
      developer_instructions: control_plane.developer_instructions.clone(),
      personality: parse_personality(control_plane.personality.as_deref()),
      codex_linux_sandbox_exe: None,
      ..Default::default()
    };

    let mut config =
      Config::load_with_cli_overrides_and_harness_overrides(
        cli_overrides.clone(),
        build_harness_overrides(),
      )
        .await
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to load config: {}", e)))?;
    apply_orbitdock_provider_defaults(&mut config);
    apply_orbitdock_external_model_defaults(&mut config);
    let forced_apply_patch_feature = ensure_apply_patch_feature_for_custom_models(&mut config);
    log_apply_patch_tool_resolution(cwd, &config, forced_apply_patch_feature);

    Ok(config)
  }

  pub(crate) async fn finalize_reasoning_summary(
    config: &mut Config,
    thread_manager: &ThreadManager,
  ) {
    let supports_reasoning_summaries =
      model_supports_reasoning_summaries(thread_manager, config).await;
    if should_disable_reasoning_summary(config.model.as_deref(), supports_reasoning_summaries) {
      config.model_reasoning_summary = Some(ReasoningSummary::None);
    }
  }

  pub(crate) async fn apply_post_start_control_plane(
    &self,
    control_plane: CodexControlPlane,
    configured_model: Option<String>,
    configured_effort: Option<ReasoningEffort>,
  ) -> Result<(), ConnectorError> {
    let requested_effort = control_plane
      .effort
      .as_deref()
      .and_then(parse_reasoning_effort_value);
    let collaboration_mode = collaboration_mode_for_update(
      self.thread_manager.as_ref(),
      control_plane.collaboration_mode.as_deref(),
      None,
      configured_model.unwrap_or_else(|| "gpt-5-codex".to_string()),
      requested_effort.or(configured_effort),
      control_plane.developer_instructions.as_deref(),
    );
    let service_tier = parse_service_tier_override(control_plane.service_tier.as_deref());
    let personality = parse_personality(control_plane.personality.as_deref());
    let approvals_reviewer = parse_approvals_reviewer(control_plane.approvals_reviewer.as_deref());

    if collaboration_mode.is_none()
      && approvals_reviewer.is_none()
      && service_tier.is_none()
      && personality.is_none()
      && control_plane.multi_agent.is_none()
      && requested_effort.is_none()
    {
      return Ok(());
    }

    self
      .thread
      .submit(Op::OverrideTurnContext {
        cwd: None,
        approval_policy: None,
        sandbox_policy: None,
        windows_sandbox_level: None,
        model: None,
        effort: requested_effort.map(Some),
        summary: None,
        approvals_reviewer,
        service_tier,
        collaboration_mode,
        personality,
      })
      .await
      .map_err(|e| {
        ConnectorError::ProviderError(format!(
          "Failed to apply Codex control plane settings: {}",
          e
        ))
      })?;

    Ok(())
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
  let codex_home = find_codex_home()
    .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;
  let auth_manager = Arc::new(AuthManager::new(
    codex_home.clone(),
    true,
    ORBITDOCK_CODEX_AUTH_STORE_MODE,
  ));
  let harness_overrides = ConfigOverrides {
    cwd: cwd.map(std::path::PathBuf::from),
    model_provider: model_provider.map(str::to_string),
    ..Default::default()
  };
  let mut base_config =
    Config::load_with_cli_overrides_and_harness_overrides(Vec::new(), harness_overrides)
      .await
      .or_else(|err| {
        warn!(
          "Failed to load config for model discovery: {}. Falling back to defaults.",
          err
        );
        Config::load_default_with_cli_overrides(Vec::new())
      })
      .map_err(|e| {
        ConnectorError::ProviderError(format!("Failed to load config for model discovery: {}", e))
      })?;
  apply_orbitdock_provider_defaults(&mut base_config);
  log_provider_route("discover_models", cwd.unwrap_or(""), &base_config);
  let thread_manager = Arc::new(ThreadManager::new(
    &base_config,
    auth_manager,
    SessionSource::Mcp,
    CollaborationModesConfig::default(),
    Arc::new(EnvironmentManager::new(None)),
  ));

  let mut models: Vec<orbitdock_protocol::CodexModelOption> = Vec::new();
  for preset in thread_manager
    .list_models(RefreshStrategy::OnlineIfUncached)
    .await
    .into_iter()
    .filter(|preset| preset.show_in_picker)
  {
    let mut model_config = base_config.clone();
    model_config.model = Some(preset.model.clone());
    let supports_reasoning_summaries =
      model_supports_reasoning_summaries(thread_manager.as_ref(), &model_config).await;
    let supported_reasoning_efforts = preset
      .supported_reasoning_efforts
      .into_iter()
      .map(|effort| effort.effort.to_string())
      .collect();

    models.push(orbitdock_protocol::CodexModelOption {
      id: preset.id,
      model: preset.model,
      display_name: preset.display_name,
      description: preset.description,
      is_default: preset.is_default,
      supported_reasoning_efforts,
      supports_reasoning_summaries,
      supported_collaboration_modes: vec!["default".to_string(), "plan".to_string()],
      supports_multi_agent: true,
      multi_agent_is_experimental: true,
      supports_personality: true,
      supported_service_tiers: vec!["fast".to_string(), "flex".to_string()],
      supports_developer_instructions: true,
    });
  }

  Ok(models)
}

pub(crate) fn parse_approvals_reviewer(value: Option<&str>) -> Option<ApprovalsReviewer> {
  match value.map(str::trim).filter(|value| !value.is_empty()) {
    Some("user") => Some(ApprovalsReviewer::User),
    Some("guardian_subagent") => Some(ApprovalsReviewer::GuardianSubagent),
    _ => None,
  }
}

fn parse_reasoning_effort_value(value: &str) -> Option<ReasoningEffort> {
  match value {
    "none" => Some(ReasoningEffort::None),
    "minimal" => Some(ReasoningEffort::Minimal),
    "low" => Some(ReasoningEffort::Low),
    "medium" => Some(ReasoningEffort::Medium),
    "high" => Some(ReasoningEffort::High),
    "xhigh" => Some(ReasoningEffort::XHigh),
    _ => None,
  }
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
      ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS,
      ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER
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
        existing.instructions_template.as_deref().unwrap_or_default(),
        external_messages
          .instructions_template
          .as_deref()
          .unwrap_or_default(),
      );
      existing.instructions_template = Some(merged_template);

      let merged_variables = existing
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

fn log_apply_patch_tool_resolution(cwd: &str, config: &Config, forced_by_orbitdock: bool) {
  info!(
    event = "codex.connector.apply_patch_tool_resolved",
    cwd,
    model = ?config.model,
    model_provider_id = %config.model_provider_id,
    include_apply_patch_tool = config.include_apply_patch_tool,
    feature_apply_patch_freeform = config.features.enabled(Feature::ApplyPatchFreeform),
    feature_js_repl = config.features.enabled(Feature::JsRepl),
    feature_unified_exec = config.features.enabled(Feature::UnifiedExec),
    forced_by_orbitdock,
  );
}

fn log_provider_route(phase: &str, cwd: &str, config: &Config) {
  let info = provider_route_debug_info(config);
  info!(
    event = "codex.connector.route_resolved",
    phase,
    cwd,
    model = ?config.model,
    model_provider_id = %info.provider_id,
    provider_name = ?info.provider_name,
    provider_base_url = ?info.base_url,
    wire_api = %info.wire_api,
    query_param_keys = ?info.query_param_keys,
    http_header_names = ?info.http_header_names,
    env_http_header_names = ?info.env_http_header_names,
    has_orbitdock_openrouter_referer = info.has_orbitdock_openrouter_referer,
    has_orbitdock_openrouter_title = info.has_orbitdock_openrouter_title,
  );
}

fn provider_route_debug_info(config: &Config) -> ProviderRouteDebugInfo {
  let provider_id = config.model_provider_id.clone();
  let provider = config.model_providers.get(&provider_id);

  let mut query_param_keys = provider
    .and_then(|value| value.query_params.as_ref())
    .map(|value| value.keys().cloned().collect::<Vec<_>>())
    .unwrap_or_default();
  query_param_keys.sort();

  let mut http_header_names = provider
    .and_then(|value| value.http_headers.as_ref())
    .map(|value| value.keys().cloned().collect::<Vec<_>>())
    .unwrap_or_default();
  http_header_names.sort();

  let mut env_http_header_names = provider
    .and_then(|value| value.env_http_headers.as_ref())
    .map(|value| value.keys().cloned().collect::<Vec<_>>())
    .unwrap_or_default();
  env_http_header_names.sort();

  let has_orbitdock_openrouter_referer = provider
    .and_then(|value| value.http_headers.as_ref())
    .and_then(|value| value.get("HTTP-Referer"))
    .map(|value| value == ORBITDOCK_OPENROUTER_SITE_URL)
    .unwrap_or(false);

  let has_orbitdock_openrouter_title = provider
    .and_then(|value| value.http_headers.as_ref())
    .and_then(|value| value.get("X-OpenRouter-Title"))
    .map(|value| value == ORBITDOCK_OPENROUTER_TITLE)
    .unwrap_or(false);

  ProviderRouteDebugInfo {
    provider_id,
    provider_name: provider.map(|value| value.name.clone()),
    base_url: provider.and_then(|value| value.base_url.clone()),
    wire_api: provider
      .map(|value| format!("{:?}", value.wire_api))
      .unwrap_or_else(|| "unknown".to_string()),
    query_param_keys,
    http_header_names,
    env_http_header_names,
    has_orbitdock_openrouter_referer,
    has_orbitdock_openrouter_title,
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

pub(crate) async fn model_supports_reasoning_summaries(
  thread_manager: &ThreadManager,
  config: &Config,
) -> bool {
  let Some(model) = config.model.as_deref() else {
    return true;
  };

  thread_manager
    .get_models_manager()
    .get_model_info(model, config)
    .await
    .supports_reasoning_summaries
}

pub(crate) fn should_disable_reasoning_summary(
  model: Option<&str>,
  supports_reasoning_summaries: bool,
) -> bool {
  !supports_reasoning_summaries || model_rejects_reasoning_summary(model)
}

pub(crate) fn collaboration_mode_for_update(
  thread_manager: &ThreadManager,
  explicit_collaboration_mode: Option<&str>,
  permission_mode: Option<&str>,
  model: String,
  effort: Option<ReasoningEffort>,
  developer_instructions: Option<&str>,
) -> Option<CollaborationMode> {
  let explicit_mode = explicit_collaboration_mode
    .and_then(parse_mode_kind)
    .map(|mode| {
      collaboration_mode_from_name_or_mode(
        thread_manager.list_collaboration_modes(),
        mode_kind_name(mode),
        model.clone(),
        effort,
        developer_instructions,
      )
    });

  if explicit_mode.is_some() {
    return explicit_mode.flatten();
  }

  let shim_mode = permission_mode.and_then(parse_mode_kind).map(|mode| {
    collaboration_mode_from_name_or_mode(
      thread_manager.list_collaboration_modes(),
      mode_kind_name(mode),
      model.clone(),
      effort,
      developer_instructions,
    )
  });

  if shim_mode.is_some() {
    return shim_mode.flatten();
  }

  developer_instructions.map(|instructions| CollaborationMode {
    mode: ModeKind::Default,
    settings: Settings {
      model,
      reasoning_effort: effort,
      developer_instructions: Some(instructions.to_string()),
    },
  })
}

#[cfg(test)]
pub(crate) fn collaboration_mode_from_permission_mode(
  permission_mode: Option<&str>,
  model: String,
  effort: Option<ReasoningEffort>,
) -> Option<CollaborationMode> {
  let mode = permission_mode.and_then(parse_mode_kind)?;
  Some(build_collaboration_mode(
    mode,
    model,
    effort,
    None::<String>,
  ))
}

pub(crate) fn collaboration_mode_from_name_or_mode(
  masks: Vec<CollaborationModeMask>,
  mode_name: &str,
  model: String,
  effort: Option<ReasoningEffort>,
  developer_instructions: Option<&str>,
) -> Option<CollaborationMode> {
  let normalized = mode_name.trim().to_ascii_lowercase();
  let parsed_mode = parse_mode_kind(normalized.as_str())?;
  let base = build_collaboration_mode(
    parsed_mode,
    model,
    effort,
    developer_instructions.map(ToOwned::to_owned),
  );

  let matched_mask = masks.into_iter().find(|mask| {
    mask.name.trim().eq_ignore_ascii_case(normalized.as_str())
      || mask
        .mode
        .map(|mode| mode_kind_name(mode).eq_ignore_ascii_case(normalized.as_str()))
        .unwrap_or(false)
  });

  let resolved = matched_mask
    .map(|mask| base.apply_mask(&mask))
    .unwrap_or(base);
  let developer_override = developer_instructions.map(|value| Some(value.to_string()));
  Some(resolved.with_updates(None, None, developer_override))
}

fn build_collaboration_mode(
  mode: ModeKind,
  model: String,
  effort: Option<ReasoningEffort>,
  developer_instructions: impl Into<Option<String>>,
) -> CollaborationMode {
  CollaborationMode {
    mode,
    settings: Settings {
      model,
      reasoning_effort: effort,
      developer_instructions: developer_instructions.into(),
    },
  }
}

fn mode_kind_name(mode: ModeKind) -> &'static str {
  match mode {
    ModeKind::Plan => "plan",
    ModeKind::Default | ModeKind::PairProgramming | ModeKind::Execute => "default",
  }
}

fn parse_mode_kind(value: &str) -> Option<ModeKind> {
  match value.trim().to_ascii_lowercase().as_str() {
    "plan" => Some(ModeKind::Plan),
    "default" => Some(ModeKind::Default),
    _ => None,
  }
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
