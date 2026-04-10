use anyhow::{Context, Result};

use super::MissionConfig;

/// Reconstruct MISSION.md content from config + prompt template.
///
/// Writes config keys at the top level of the YAML front matter.
pub fn serialize_mission_file(config: &MissionConfig, prompt_template: &str) -> Result<String> {
  let yaml = serde_yaml::to_string(config).context("serialize config to YAML")?;
  Ok(format!("---\n{}---\n\n{}", yaml, prompt_template))
}

/// Serialize config while preserving non-mission content from an existing MISSION.md.
pub fn serialize_mission_file_preserving(
  config: &MissionConfig,
  prompt_template: &str,
  existing_content: Option<&str>,
) -> Result<String> {
  let Some(existing) = existing_content else {
    return serialize_mission_file(config, prompt_template);
  };

  let trimmed = existing.trim();
  if !trimmed.starts_with("---") {
    let body = if prompt_template.is_empty() {
      trimmed
    } else {
      prompt_template
    };
    return serialize_mission_file(config, body);
  }

  let after_first = &trimmed[3..];
  let end_idx = after_first
    .find("\n---")
    .context("existing MISSION.md missing closing ---")?;
  let existing_yaml = &after_first[..end_idx];
  let existing_body_start = 3 + end_idx + 4;
  let existing_body = if existing_body_start < trimmed.len() {
    trimmed[existing_body_start..].trim()
  } else {
    ""
  };

  let mut mapping: serde_yaml::Mapping = serde_yaml::from_str(existing_yaml).unwrap_or_default();
  let config_value =
    serde_yaml::to_value(config).context("serialize mission config to YAML value")?;

  if let serde_yaml::Value::Mapping(config_map) = config_value {
    for (key, value) in config_map {
      mapping.insert(key, value);
    }
  }

  let yaml = serde_yaml::to_string(&mapping).context("serialize merged YAML")?;
  let body = if prompt_template.is_empty() {
    existing_body
  } else {
    prompt_template
  };

  Ok(format!("---\n{}---\n\n{}", yaml, body))
}
