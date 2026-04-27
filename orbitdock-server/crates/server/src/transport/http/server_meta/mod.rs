use orbitdock_protocol::{
  ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption, CodexUsageSnapshot,
  UsageBreakdownGroupBy, UsageErrorInfo,
};
use serde::{Deserialize, Serialize};

mod models;
mod usage;

pub use models::{list_claude_models, list_codex_models};
pub use usage::{
  fetch_claude_usage, fetch_codex_usage, fetch_usage_breakdown, fetch_usage_overview,
  fetch_usage_sessions, fetch_usage_summary,
};

#[derive(Debug, Serialize)]
pub struct CodexUsageResponse {
  pub usage: Option<CodexUsageSnapshot>,
  pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeUsageResponse {
  pub usage: Option<ClaudeUsageSnapshot>,
  pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct CodexModelsResponse {
  pub models: Vec<CodexModelOption>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeModelsResponse {
  pub models: Vec<ClaudeModelOption>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CodexModelsQuery {
  #[serde(default)]
  pub cwd: Option<String>,
  #[serde(default)]
  pub model_provider: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct UsageSummaryQuery {
  #[serde(default)]
  pub today_start_unix: Option<u64>,
}

fn default_usage_breakdown_group_by() -> UsageBreakdownGroupBy {
  UsageBreakdownGroupBy::Model
}

#[derive(Debug, Deserialize)]
pub struct UsageBreakdownQuery {
  #[serde(default = "default_usage_breakdown_group_by")]
  pub group_by: UsageBreakdownGroupBy,
  #[serde(default)]
  pub start_unix: Option<u64>,
  #[serde(default)]
  pub end_unix: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct UsageOverviewQuery {
  #[serde(default)]
  pub today_start_unix: Option<u64>,
  #[serde(default)]
  pub range_start_unix: Option<u64>,
  #[serde(default)]
  pub range_end_unix: Option<u64>,
}

fn default_usage_sessions_limit() -> u64 {
  10
}

#[derive(Debug, Deserialize)]
pub struct UsageSessionsQuery {
  #[serde(default)]
  pub start_unix: Option<u64>,
  #[serde(default)]
  pub end_unix: Option<u64>,
  #[serde(default = "default_usage_sessions_limit")]
  pub limit: u64,
  #[serde(default)]
  pub offset: u64,
}

#[derive(Debug, Clone)]
struct SessionSummaryRow {
  id: String,
  provider: orbitdock_protocol::Provider,
  project_path: String,
  project_name: Option<String>,
  model: Option<String>,
  custom_name: Option<String>,
  summary: Option<String>,
  first_prompt: Option<String>,
  last_message: Option<String>,
  started_at: Option<String>,
  last_activity_at: Option<String>,
  started_at_unix: Option<u64>,
}

#[derive(Debug, Clone)]
struct UsageLedgerRow {
  session_id: String,
  provider: orbitdock_protocol::Provider,
  model: Option<String>,
  observed_at_unix: Option<u64>,
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
  cost_usd: f64,
}

#[cfg(test)]
mod tests;
