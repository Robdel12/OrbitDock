use anyhow::{Context, Result};

use super::{parse_mission_file, MissionConfig};
use crate::domain::mission_control::template::default_mission_template;

/// Generate a scaffold MISSION.md for a given provider.
pub fn generate_scaffold(provider: &str, tracker: &str) -> Result<(String, MissionConfig, String)> {
  let file_content = default_mission_template(provider, tracker);
  let parsed = parse_mission_file(&file_content).context("parse scaffolded template")?;
  let prompt_template = parsed.prompt_template.clone();
  Ok((file_content, parsed.config, prompt_template))
}
