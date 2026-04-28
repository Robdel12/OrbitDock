mod bridge;
#[path = "constructor.rs"]
mod constructor;
#[path = "discovery.rs"]
mod discovery;
mod policy;
#[path = "provider_defaults.rs"]
mod provider_defaults;
#[path = "runtime_defaults.rs"]
mod runtime_defaults;

pub(crate) use bridge::{convert_app_server_type, convert_optional};
pub(crate) use constructor::ResumeConnectorWithToolsConfig;
pub use discovery::{discover_models, discover_models_for_context};
#[cfg(test)]
pub(crate) use policy::parse_reasoning_summary;
#[cfg(test)]
pub(crate) use policy::should_disable_reasoning_summary;
pub(crate) use policy::{
  app_server_sandbox_mode, model_rejects_reasoning_summary, parse_approvals_reviewer,
  parse_personality, parse_service_tier_override, preferred_reasoning_summary,
  reasoning_summary_for_model, reasoning_summary_storage_text,
};
pub use policy::{config_loader_sandbox_mode, requested_sandbox_policy_details};
#[cfg(test)]
pub(crate) use provider_defaults::apply_orbitdock_provider_defaults;
#[cfg(test)]
pub(crate) use runtime_defaults::{
  apply_orbitdock_embedded_runtime_defaults, apply_orbitdock_external_model_defaults,
  ensure_apply_patch_feature_for_custom_models, should_enable_apply_patch_for_custom_models,
};

const DEFAULT_CODEX_SHOW_RAW_REASONING: bool = true;
const DEFAULT_CODEX_HIDE_REASONING: bool = false;
const ENV_CODEX_SHOW_RAW_REASONING: &str = "ORBITDOCK_CODEX_SHOW_RAW_REASONING";
const ENV_CODEX_HIDE_REASONING: &str = "ORBITDOCK_CODEX_HIDE_REASONING";
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

#[cfg(test)]
fn override_cwd(cwd: &str) -> Option<std::path::PathBuf> {
  let trimmed = cwd.trim();
  if trimmed.is_empty() {
    None
  } else {
    Some(std::path::PathBuf::from(trimmed))
  }
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod config_tests;
