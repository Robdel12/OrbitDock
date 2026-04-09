use orbitdock_protocol::CodexConfigSource;

use crate::infrastructure::persistence::load_config_value;

use super::codex_config_types::CodexConfigPreferencesResponse;

const CODEX_DEFAULT_CONFIG_SOURCE_KEY: &str = "codex_default_config_source";

pub fn codex_default_config_source() -> CodexConfigSource {
  match load_config_value(CODEX_DEFAULT_CONFIG_SOURCE_KEY).as_deref() {
    Some("orbitdock") => CodexConfigSource::Orbitdock,
    Some("user") => CodexConfigSource::User,
    _ => CodexConfigSource::User,
  }
}

pub fn codex_preferences_response() -> CodexConfigPreferencesResponse {
  CodexConfigPreferencesResponse {
    default_config_source: codex_default_config_source(),
  }
}
