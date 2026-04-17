use orbitdock_protocol::{
  ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption, CodexUsageSnapshot, UsageErrorInfo,
};
use serde::{Deserialize, Serialize};

mod models;
mod usage;

pub use models::{list_claude_models, list_codex_models};
pub use usage::{fetch_claude_usage, fetch_codex_usage, fetch_usage_summary};

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

#[derive(Debug, Default, Serialize)]
pub struct UsageSummarySnapshot {
  pub today: UsageSummaryBucket,
  pub all_time: UsageSummaryBucket,
}

#[derive(Debug, Default, Serialize)]
pub struct UsageSummaryBucket {
  pub session_count: u64,
  pub total_tokens: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_cost_usd: f64,
  pub cost_by_model: Vec<UsageSummaryModelCost>,
}

#[derive(Debug, Serialize)]
pub struct UsageSummaryModelCost {
  pub model: String,
  pub cost_usd: f64,
}

#[derive(Debug, Clone)]
struct SessionSummaryRow {
  id: String,
  started_at_unix: Option<u64>,
}

#[derive(Debug, Clone)]
struct UsageLedgerRow {
  session_id: String,
  model: Option<String>,
  observed_at_unix: Option<u64>,
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
  cost_usd: f64,
}

#[cfg(test)]
mod tests;
