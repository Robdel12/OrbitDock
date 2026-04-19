use anyhow::{Context, Result};

use super::{MissionConfig, MissionDefinition};

/// Parse a MISSION.md file: YAML front matter between `---` fences, rest is Liquid template.
pub fn parse_mission_file(content: &str) -> Result<MissionDefinition> {
  let content = content.trim();
  if !content.starts_with("---") {
    anyhow::bail!("MISSION.md must start with YAML front matter (---)");
  }

  let after_first = &content[3..];
  let end_idx = after_first
    .find("\n---")
    .context("MISSION.md missing closing --- for YAML front matter")?;

  let yaml_block = &after_first[..end_idx];
  let prompt_start = 3 + end_idx + 4;
  let prompt_template = if prompt_start < content.len() {
    content[prompt_start..].trim().to_string()
  } else {
    String::new()
  };

  if let Ok(config) = serde_yaml::from_str::<MissionConfig>(yaml_block) {
    let defaults = MissionConfig::default();
    let has_mission_config = config.tracker != defaults.tracker
      || config.provider.strategy != defaults.provider.strategy
      || config.provider.primary != defaults.provider.primary
      || config.provider.secondary.is_some()
      || config.provider.max_concurrent != defaults.provider.max_concurrent
      || config.provider.max_concurrent_primary.is_some()
      || !config.workspace.is_empty()
      || config.trigger.kind != defaults.trigger.kind
      || config.trigger.interval != defaults.trigger.interval
      || !config.trigger.filters.labels.is_empty()
      || !config.trigger.filters.states.is_empty()
      || config.trigger.filters.project.is_some()
      || config.trigger.filters.team.is_some()
      || config.orchestration.max_retries != defaults.orchestration.max_retries
      || config.orchestration.stall_timeout != defaults.orchestration.stall_timeout
      || config.orchestration.base_branch != defaults.orchestration.base_branch;

    if has_mission_config {
      return Ok(MissionDefinition {
        config,
        prompt_template,
      });
    }

    let has_recognized_keys = yaml_block.contains("tracker:")
      || yaml_block.contains("provider:")
      || yaml_block.contains("workspace:")
      || yaml_block.contains("agent:")
      || yaml_block.contains("trigger:")
      || yaml_block.contains("orchestration:");

    if has_recognized_keys {
      return Ok(MissionDefinition {
        config,
        prompt_template,
      });
    }
  }

  anyhow::bail!(
    "MISSION.md does not contain OrbitDock mission configuration. \
         Use 'Generate MISSION.md' to create one."
  )
}
