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
#[derive(Debug, Deserialize, Default)]
struct FileConfig {
    server: Option<String>,
    token: Option<String>,
    #[allow(dead_code)]
    default_provider: Option<String>,
    #[allow(dead_code)]
    default_model: Option<String>,
    #[allow(dead_code)]
    color: Option<String>,
}

impl ClientConfig {
    /// Resolve configuration from CLI flags, env vars, config file, and defaults.
    ///
    /// Priority (highest first):
    /// 1. CLI flags (--server, --token, --json)
    /// 2. Environment variables (ORBITDOCK_URL, ORBITDOCK_TOKEN) — handled by clap env
    /// 3. Config file (~/.orbitdock/cli.toml)
    /// 4. Token file (~/.orbitdock/auth-token)
    /// 5. Defaults
    pub fn resolve(cli: &Cli) -> Result<Self> {
        let file_config = load_config_file(cli.config.as_deref());

        // Server URL: flag/env > config file > default
        let server_url = cli
            .server
            .clone()
            .or(file_config.server)
            .unwrap_or_else(|| DEFAULT_SERVER.to_string());

        // Token: flag/env > config file > auth-token file
        let token = cli
            .token
            .clone()
            .or(file_config.token)
            .or_else(load_token_file);

        // JSON: flag or non-TTY stdout
        let json = cli.json || !atty_stdout();

        Ok(Self {
            server_url,
            token,
            json,
        })
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

fn load_token_file() -> Option<String> {
    let home = dirs::home_dir()?;
    let path = home.join(".orbitdock").join("auth-token");
    let contents = std::fs::read_to_string(path).ok()?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn atty_stdout() -> bool {
    console::Term::stdout().is_term()
}
