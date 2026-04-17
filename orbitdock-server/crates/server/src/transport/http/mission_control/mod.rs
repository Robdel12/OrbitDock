use serde::{Deserialize, Serialize};

mod common;
mod crud;
mod defaults;
mod files;
mod issue_reports;
mod issues;
mod orchestrator;
#[cfg(test)]
mod tests;
mod tracker_keys;

pub(crate) use common::{
  build_detail_response, db_read, flush_persistence, load_detail_response, summary_from_row,
};
pub use crud::{create_mission, delete_mission, get_mission, list_missions, update_mission};
pub use defaults::{get_mission_defaults, update_mission_defaults};
pub use files::{
  get_default_template, migrate_workflow_to_mission, scaffold_mission_file, update_mission_settings,
};
pub use issue_reports::{
  list_mission_worktrees, report_issue_blocked, report_issue_completed, set_issue_pr_url,
  transition_mission_issue,
};
pub use issues::{list_mission_issues, retry_mission_issue};
pub use orchestrator::{
  dispatch_mission_issue, start_mission_orchestrator_endpoint, trigger_mission_poll,
};
pub use tracker_keys::{
  adopt_global_tracker_key, check_github_key, check_linear_key, delete_github_key,
  delete_linear_key, delete_mission_tracker_key, get_mission_tracker_key, get_tracker_keys,
  set_github_key, set_linear_key, set_mission_tracker_key,
};

#[derive(Serialize)]
pub struct MissionsListResponse {
  pub missions: Vec<orbitdock_protocol::MissionSummary>,
}

#[derive(Serialize)]
pub struct MissionDetailResponse {
  pub summary: orbitdock_protocol::MissionSummary,
  pub issues: Vec<orbitdock_protocol::MissionIssueItem>,
  pub cleanup_prompt: Option<orbitdock_protocol::MissionCleanupPrompt>,
  pub settings: Option<MissionSettingsResponse>,
  pub mission_file_exists: bool,
  pub mission_file_path: Option<String>,
  pub workflow_migration_available: bool,
}

#[derive(Serialize)]
pub struct MissionSettingsResponse {
  #[serde(flatten)]
  pub config: crate::domain::mission_control::config::MissionConfig,
  pub prompt_template: String,
}

#[derive(Deserialize)]
pub struct CreateMissionRequest {
  pub name: String,
  pub repo_root: String,
  #[serde(default = "default_tracker")]
  pub tracker_kind: String,
  #[serde(default = "default_provider")]
  pub provider: String,
}

#[derive(Deserialize)]
pub struct UpdateMissionRequest {
  pub name: Option<String>,
  pub enabled: Option<bool>,
  pub paused: Option<bool>,
  pub mission_file_path: Option<Option<String>>,
}

#[derive(Deserialize)]
pub struct UpdateMissionSettingsRequest {
  pub provider_strategy: Option<String>,
  pub primary_provider: Option<String>,
  pub secondary_provider: Option<Option<String>>,
  pub max_concurrent: Option<u32>,
  pub max_concurrent_primary: Option<Option<u32>>,
  pub agent_claude_model: Option<Option<String>>,
  pub agent_claude_effort: Option<Option<String>>,
  pub agent_claude_permission_mode: Option<Option<String>>,
  pub agent_claude_allowed_tools: Option<Vec<String>>,
  pub agent_claude_disallowed_tools: Option<Vec<String>>,
  pub agent_claude_allow_bypass_permissions: Option<bool>,
  pub agent_codex_model: Option<Option<String>>,
  pub agent_codex_effort: Option<Option<String>>,
  pub agent_codex_approval_policy: Option<Option<String>>,
  pub agent_codex_sandbox_mode: Option<Option<String>>,
  pub agent_codex_collaboration_mode: Option<Option<String>>,
  pub agent_codex_multi_agent: Option<Option<bool>>,
  pub agent_codex_personality: Option<Option<String>>,
  pub agent_codex_service_tier: Option<Option<String>>,
  pub agent_codex_developer_instructions: Option<Option<String>>,
  pub trigger_kind: Option<String>,
  pub poll_interval: Option<u64>,
  pub label_filter: Option<Vec<String>>,
  pub state_filter: Option<Vec<String>>,
  pub project_key: Option<Option<String>>,
  pub team_key: Option<Option<String>>,
  pub max_retries: Option<u32>,
  pub stall_timeout: Option<u64>,
  pub base_branch: Option<String>,
  pub worktree_root_dir: Option<Option<String>>,
  pub state_on_dispatch: Option<String>,
  pub state_on_complete: Option<String>,
  pub prompt_template: Option<String>,
  pub tracker: Option<String>,
}

fn default_tracker() -> String {
  "linear".to_string()
}

pub(crate) fn slugify_mission_name(name: &str) -> String {
  name
    .to_lowercase()
    .chars()
    .map(|c| if c.is_alphanumeric() { c } else { '-' })
    .collect::<String>()
    .split('-')
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join("-")
}

fn default_provider() -> String {
  "claude".to_string()
}
