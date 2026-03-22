pub(crate) mod config;
pub(crate) mod eligibility;
pub mod executor;
pub(crate) mod prompt;
pub(crate) mod retry;
pub(crate) mod skills;
pub(crate) mod template;
pub mod tools;
pub(crate) mod tracker;

use crate::infrastructure::persistence::MissionRow;

pub(crate) fn compute_orchestrator_status(
    row: &MissionRow,
    orchestrator_running: bool,
) -> Option<String> {
    if !row.enabled {
        return Some("disabled".to_string());
    }
    if row.paused {
        return Some("paused".to_string());
    }
    if row.parse_error.is_some() {
        return Some("config_error".to_string());
    }
    if crate::support::api_keys::resolve_tracker_api_key(&row.tracker_kind).is_none() {
        return Some("no_api_key".to_string());
    }
    if !orchestrator_running {
        return Some("idle".to_string());
    }
    Some("polling".to_string())
}
