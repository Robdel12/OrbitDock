use std::sync::Arc;

use codex_core::auth::AuthCredentialsStoreMode;
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_core::models_manager::collaboration_mode_presets::CollaborationModesConfig;
use codex_core::models_manager::manager::RefreshStrategy;
use codex_core::{AuthManager, ThreadManager};
use codex_protocol::config_types::{
    CollaborationMode, CollaborationModeMask, ModeKind, Personality, ReasoningSummary, ServiceTier,
    Settings,
};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{Op, SessionSource};
use tracing::{info, warn};

use super::{CodexConnector, CodexControlPlane};
use orbitdock_connector_core::ConnectorError;

const DEFAULT_CODEX_SHOW_RAW_REASONING: bool = true;
const DEFAULT_CODEX_HIDE_REASONING: bool = false;
const DEFAULT_CODEX_REASONING_SUMMARY: &str = "detailed";
const REASONING_SUMMARY_NONE: &str = "none";
const ENV_CODEX_SHOW_RAW_REASONING: &str = "ORBITDOCK_CODEX_SHOW_RAW_REASONING";
const ENV_CODEX_HIDE_REASONING: &str = "ORBITDOCK_CODEX_HIDE_REASONING";
const ENV_CODEX_REASONING_SUMMARY: &str = "ORBITDOCK_CODEX_REASONING_SUMMARY";

impl CodexConnector {
    pub async fn new(
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        Self::new_with_control_plane(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
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
        Self::new_with_control_plane_and_tools(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
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
        info!("Creating codex-core connector for {}", cwd);

        let codex_home = find_codex_home().map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to find codex home: {}", e))
        })?;

        let auth_manager = Arc::new(AuthManager::new(
            codex_home.clone(),
            true,
            AuthCredentialsStoreMode::Auto,
        ));

        let mut config =
            Self::build_config(cwd, model, approval_policy, sandbox_mode, &control_plane).await?;

        let thread_manager = Arc::new(ThreadManager::new(
            &config,
            auth_manager.clone(),
            SessionSource::Mcp,
            CollaborationModesConfig::default(),
        ));
        Self::finalize_reasoning_summary(&mut config, thread_manager.as_ref()).await;

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
        Self::resume_with_control_plane(
            cwd,
            thread_id,
            model,
            approval_policy,
            sandbox_mode,
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
        info!(
            "Resuming codex-core connector for {} with thread {}",
            cwd, thread_id
        );

        let codex_home = find_codex_home().map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to find codex home: {}", e))
        })?;

        let rollout_path = codex_core::find_thread_path_by_id_str(&codex_home, thread_id)
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to find rollout for thread: {}", e))
            })?
            .ok_or_else(|| {
                ConnectorError::ProviderError(format!(
                    "No rollout file found for thread {}",
                    thread_id
                ))
            })?;

        info!("Found rollout at {:?}", rollout_path);

        let auth_manager = Arc::new(AuthManager::new(
            codex_home.clone(),
            true,
            AuthCredentialsStoreMode::Auto,
        ));

        let mut config =
            Self::build_config(cwd, model, approval_policy, sandbox_mode, &control_plane).await?;

        let thread_manager = Arc::new(ThreadManager::new(
            &config,
            auth_manager.clone(),
            SessionSource::Mcp,
            CollaborationModesConfig::default(),
        ));
        Self::finalize_reasoning_summary(&mut config, thread_manager.as_ref()).await;

        let configured_model = config.model.clone();
        let new_thread = thread_manager
            .resume_thread_from_rollout(config, rollout_path, auth_manager)
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to resume thread: {}", e))
            })?;

        let connector = Self::from_thread(new_thread, thread_manager, codex_home)?;
        connector
            .apply_post_start_control_plane(control_plane, configured_model, None)
            .await?;
        Ok(connector)
    }

    pub(crate) async fn build_config(
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        control_plane: &CodexControlPlane,
    ) -> Result<Config, ConnectorError> {
        let mut cli_overrides = Vec::new();

        if let Some(model) = model {
            cli_overrides.push(("model".to_string(), toml::Value::String(model.to_string())));
        }

        let policy = approval_policy.unwrap_or("untrusted");
        cli_overrides.push((
            "approval_policy".to_string(),
            toml::Value::String(policy.to_string()),
        ));

        if let Some(sandbox) = sandbox_mode {
            cli_overrides.push((
                "sandbox_mode".to_string(),
                toml::Value::String(sandbox.to_string()),
            ));
        }

        let show_raw_reasoning = parse_bool_env(ENV_CODEX_SHOW_RAW_REASONING)
            .unwrap_or(DEFAULT_CODEX_SHOW_RAW_REASONING);
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

        if let Some(multi_agent) = control_plane.multi_agent {
            cli_overrides.push((
                "features.multi_agent".to_string(),
                toml::Value::Boolean(multi_agent),
            ));
        }

        let harness_overrides = ConfigOverrides {
            cwd: Some(std::path::PathBuf::from(cwd)),
            service_tier: parse_service_tier_override(control_plane.service_tier.as_deref()),
            developer_instructions: control_plane.developer_instructions.clone(),
            personality: parse_personality(control_plane.personality.as_deref()),
            codex_linux_sandbox_exe: None,
            ..Default::default()
        };

        Config::load_with_cli_overrides_and_harness_overrides(cli_overrides, harness_overrides)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to load config: {}", e)))
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
        let collaboration_mode = collaboration_mode_for_update(
            self.thread_manager.as_ref(),
            control_plane.collaboration_mode.as_deref(),
            None,
            configured_model.unwrap_or_else(|| "gpt-5-codex".to_string()),
            configured_effort,
            control_plane.developer_instructions.as_deref(),
        );
        let service_tier = parse_service_tier_override(control_plane.service_tier.as_deref());
        let personality = parse_personality(control_plane.personality.as_deref());

        if collaboration_mode.is_none()
            && service_tier.is_none()
            && personality.is_none()
            && control_plane.multi_agent.is_none()
        {
            return Ok(());
        }

        self.thread
            .submit(Op::OverrideTurnContext {
                cwd: None,
                approval_policy: None,
                sandbox_policy: None,
                windows_sandbox_level: None,
                model: None,
                effort: None,
                summary: None,
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
    let codex_home = find_codex_home()
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;
    let auth_manager = Arc::new(AuthManager::new(
        codex_home.clone(),
        true,
        AuthCredentialsStoreMode::Auto,
    ));
    let base_config = Config::load_with_cli_overrides(Vec::new())
        .await
        .or_else(|err| {
            warn!(
                "Failed to load config for model discovery: {}. Falling back to defaults.",
                err
            );
            Config::load_default_with_cli_overrides(Vec::new())
        })
        .map_err(|e| {
            ConnectorError::ProviderError(format!(
                "Failed to load config for model discovery: {}",
                e
            ))
        })?;
    let thread_manager = Arc::new(ThreadManager::new(
        &base_config,
        auth_manager,
        SessionSource::Mcp,
        CollaborationModesConfig::default(),
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
