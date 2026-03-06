use anyhow::Result;
use serde::Deserialize;

use crate::cli::Cli;

const DEFAULT_SERVER: &str = "http://127.0.0.1:4000";

/// Resolved configuration for the CLI client.
#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub server_url: String,
    pub token: Option<String>,
    pub json: bool,
}

/// Optional TOML config file (~/.orbitdock/cli.toml).
/// Unknown keys (default_provider, default_model, color, etc.) are silently ignored
/// by serde's default behavior, so forward-compatible with future config additions.
#[derive(Debug, Deserialize, Default)]
struct FileConfig {
    server: Option<String>,
    token: Option<String>,
}

impl ClientConfig {
    /// Resolve configuration from CLI flags, env vars, config file, and defaults.
    ///
    /// Priority (highest first):
    /// 1. CLI flags (--server, --token, --json)
    /// 2. Environment variables (ORBITDOCK_URL, ORBITDOCK_TOKEN) — handled by clap env
    /// 3. Config file (~/.orbitdock/cli.toml)
    /// 4. Defaults
    pub fn resolve(cli: &Cli) -> Result<Self> {
        Ok(Self::from_sources(
            cli.server.as_deref(),
            cli.token.as_deref(),
            cli.json,
            cli.config.as_deref(),
        ))
    }

    pub fn from_sources(
        server: Option<&str>,
        token: Option<&str>,
        json: bool,
        config_path: Option<&str>,
    ) -> Self {
        let file_config = load_config_file(config_path);

        // Server URL: flag/env > config file > default
        let server_url = normalized_non_empty(server)
            .or_else(|| normalized_non_empty(file_config.server.as_deref()))
            .unwrap_or_else(|| DEFAULT_SERVER.to_string());

        // Token: flag/env > config file
        let token = normalized_non_empty(token)
            .or_else(|| normalized_non_empty(file_config.token.as_deref()));

        // JSON: flag or non-TTY stdout
        let json = json || !atty_stdout();

        Self {
            server_url,
            token,
            json,
        }
    }
}

fn load_config_file(explicit_path: Option<&str>) -> FileConfig {
    let path = match explicit_path {
        Some(p) => std::path::PathBuf::from(p),
        None => {
            let Some(home) = dirs::home_dir() else {
                return FileConfig::default();
            };
            home.join(".orbitdock").join("cli.toml")
        }
    };

    let Ok(contents) = std::fs::read_to_string(&path) else {
        return FileConfig::default();
    };

    toml::from_str(&contents).unwrap_or_default()
}
fn atty_stdout() -> bool {
    console::Term::stdout().is_term()
}

fn normalized_non_empty(value: Option<&str>) -> Option<String> {
    let value = value?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}
