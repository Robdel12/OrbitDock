use std::sync::Arc;

use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::linear::client::LinearClient;

/// Resolve the Linear API key from env var or config table.
pub fn resolve_linear_api_key() -> Option<String> {
    if let Ok(key) = std::env::var("LINEAR_API_KEY") {
        if !key.is_empty() {
            return Some(key);
        }
    }

    crate::infrastructure::persistence::load_config_value("linear_api_key")
}

/// Resolve the GitHub token from env var or config table.
pub fn resolve_github_api_key() -> Option<String> {
    if let Ok(key) = std::env::var("GITHUB_TOKEN") {
        if !key.is_empty() {
            return Some(key);
        }
    }

    crate::infrastructure::persistence::load_config_value("github_api_key")
}

/// Resolve the API key for a given tracker kind (global only).
pub fn resolve_tracker_api_key(tracker_kind: &str) -> Option<String> {
    match tracker_kind {
        "linear" => resolve_linear_api_key(),
        "github" => resolve_github_api_key(),
        _ => None,
    }
}

/// Resolve a tracker API key for a specific mission.
///
/// Resolution order:
/// 1. Mission-scoped key (`missions.tracker_api_key`)
/// 2. Environment variable (`LINEAR_API_KEY` / `GITHUB_TOKEN`)
/// 3. Global config table (`linear_api_key` / `github_api_key`)
pub fn resolve_tracker_api_key_for_mission(mission_id: &str, tracker_kind: &str) -> Option<String> {
    // 1. Mission-scoped key
    if let Some(key) = crate::infrastructure::persistence::load_mission_tracker_key(mission_id) {
        if !key.is_empty() {
            return Some(key);
        }
    }

    // 2+3. Fall through to global resolution
    resolve_tracker_api_key(tracker_kind)
}

/// Determine the source of a tracker API key for a specific mission.
///
/// Returns the source label or `None` if no key is configured.
pub fn tracker_key_source_for_mission(
    mission_id: &str,
    tracker_kind: &str,
) -> Option<&'static str> {
    // 1. Mission-scoped key
    if let Some(key) = crate::infrastructure::persistence::load_mission_tracker_key(mission_id) {
        if !key.is_empty() {
            return Some("mission");
        }
    }

    // 2. Environment variable
    let env_key = match tracker_kind {
        "linear" => "LINEAR_API_KEY",
        "github" => "GITHUB_TOKEN",
        _ => return None,
    };
    if std::env::var(env_key)
        .map(|k| !k.is_empty())
        .unwrap_or(false)
    {
        return Some("env");
    }

    // 3. Global config table
    let config_key = match tracker_kind {
        "linear" => "linear_api_key",
        "github" => "github_api_key",
        _ => return None,
    };
    if crate::infrastructure::persistence::load_config_value(config_key).is_some() {
        return Some("global");
    }

    None
}

/// Build a tracker client for a specific mission, using mission-scoped resolution.
pub fn build_tracker_for_mission(
    mission_id: &str,
    tracker_kind: &str,
) -> anyhow::Result<Arc<dyn Tracker>> {
    let key = resolve_tracker_api_key_for_mission(mission_id, tracker_kind)
        .ok_or_else(|| anyhow::anyhow!("{tracker_kind} API key not configured"))?;
    build_tracker_with_key(tracker_kind, &key)
}

fn build_tracker_with_key(tracker_kind: &str, key: &str) -> anyhow::Result<Arc<dyn Tracker>> {
    match tracker_kind {
        "linear" => Ok(Arc::new(LinearClient::new(key.to_string()))),
        "github" => Ok(Arc::new(
            crate::infrastructure::github::client::GitHubClient::new(key.to_string()),
        )),
        other => anyhow::bail!("Unknown tracker kind: {other}"),
    }
}
