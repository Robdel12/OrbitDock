use codex_app_server_protocol::{
  DynamicToolSpec as AppServerDynamicToolSpec, ThreadResumeParams, ThreadStartParams,
  ThreadStartSource,
};
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_exec_server::{EnvironmentManager, EnvironmentManagerArgs, ExecServerRuntimePaths};
use orbitdock_connector_core::ConnectorError;
use orbitdock_protocol::CodexSandboxPolicy;

use super::{
  app_server_sandbox_mode, model_rejects_reasoning_summary, parse_approvals_reviewer,
  parse_personality, parse_service_tier_override, preferred_reasoning_summary,
  reasoning_summary_storage_text, DEFAULT_CODEX_HIDE_REASONING, DEFAULT_CODEX_SHOW_RAW_REASONING,
  ENV_CODEX_ENABLE_APP_CONNECTORS, ENV_CODEX_HIDE_REASONING, ENV_CODEX_SHOW_RAW_REASONING,
};
use crate::config::bridge::{convert_app_server_type, convert_optional};
use crate::config::provider_defaults::apply_orbitdock_provider_defaults;
use crate::config::runtime_defaults::{
  apply_orbitdock_embedded_runtime_defaults, apply_orbitdock_external_model_defaults,
  ensure_apply_patch_feature_for_custom_models, parse_bool_env,
};
use crate::policy_bridge::parse_approval_policy_with_details;
use crate::{CodexConfigOverrides, CodexConnector, CodexRuntimeOverrides};

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
              tracing::warn!(
                thread_id = %thread_id,
                error = %err,
                "Failed to persist Codex dynamic tools for resumed thread"
              );
            }
          }
        }
        Err(err) => {
          tracing::warn!(
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

    if let Some(sandbox) = super::config_loader_sandbox_mode(sandbox_mode, sandbox_policy_details) {
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
      let mut reasoning_summary =
        reasoning_summary_storage_text(preferred_reasoning_summary()).to_string();
      if model_rejects_reasoning_summary(model) {
        reasoning_summary =
          reasoning_summary_storage_text(codex_protocol::config_types::ReasoningSummary::None)
            .to_string();
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
