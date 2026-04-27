#[path = "config_model.rs"]
mod config_model;
mod parser;
mod scaffold;
mod serializer;

pub use self::config_model::*;
pub use self::parser::parse_mission_file;
pub use self::scaffold::generate_scaffold;
pub use self::serializer::serialize_mission_file_preserving;

// ── Public API ───────────────────────────────────────────────────────

/// Parsed MISSION.md: config + prompt template.
#[derive(Debug, Clone)]
pub struct MissionDefinition {
  pub config: MissionConfig,
  pub prompt_template: String,
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod tests;
