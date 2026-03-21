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

/// Resolve the API key for a given tracker kind.
pub fn resolve_tracker_api_key(tracker_kind: &str) -> Option<String> {
    match tracker_kind {
        "linear" => resolve_linear_api_key(),
        "github" => resolve_github_api_key(),
        _ => None,
    }
}

/// Build a tracker client for the given kind.
pub fn build_tracker(tracker_kind: &str) -> anyhow::Result<Arc<dyn Tracker>> {
    match tracker_kind {
        "linear" => {
            let key = resolve_linear_api_key()
                .ok_or_else(|| anyhow::anyhow!("Linear API key not configured"))?;
            Ok(Arc::new(LinearClient::new(key)))
        }
        "github" => {
            let key = resolve_github_api_key()
                .ok_or_else(|| anyhow::anyhow!("GitHub token not configured"))?;
            Ok(Arc::new(
                crate::infrastructure::github::client::GitHubClient::new(key),
            ))
        }
        other => anyhow::bail!("Unknown tracker kind: {other}"),
    }
}
