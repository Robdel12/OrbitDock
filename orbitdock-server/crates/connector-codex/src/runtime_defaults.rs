use codex_core::config::Config;
use codex_features::Feature;
use codex_protocol::config_types::ReasoningSummary;
use codex_protocol::openai_models::{
  default_input_modalities, ApplyPatchToolType, ConfigShellToolType, ModelInfo,
  ModelInstructionsVariables, ModelMessages, ModelVisibility, ModelsResponse,
  TruncationPolicyConfig, WebSearchToolType,
};
use tracing::warn;

use super::{
  ORBITDOCK_EXTERNAL_MODEL_BASE_INSTRUCTIONS, ORBITDOCK_EXTERNAL_MODEL_FRIENDLY_TEMPLATE,
  ORBITDOCK_EXTERNAL_MODEL_PERSONALITY_PLACEHOLDER, ORBITDOCK_EXTERNAL_MODEL_PRAGMATIC_TEMPLATE,
};

pub(crate) fn apply_orbitdock_embedded_runtime_defaults(
  config: &mut Config,
  app_connectors_enabled: bool,
) {
  if app_connectors_enabled {
    return;
  }

  let _ = config.features.disable(Feature::Apps);
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
