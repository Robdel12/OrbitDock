use serde::Serialize;

use super::{DashboardConversationItem, MissionSummary, Provider};

/// Error payload for provider usage probe responses.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct UsageErrorInfo {
  pub code: String,
  pub message: String,
}

/// A client device that currently claims this server as its primary control plane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
pub struct ClientPrimaryClaim {
  pub client_id: String,
  pub device_name: String,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct ServerHello {
  pub server_version: String,
  pub minimum_client_version: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct ServerMeta {
  pub server_version: String,
  pub minimum_client_version: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub capabilities: Vec<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub server_instance_id: Option<String>,
  pub is_primary: bool,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub client_primary_claims: Vec<ClientPrimaryClaim>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub update_status: Option<UpdateStatus>,
}

/// Cached result of the latest update check, included in ServerMeta.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct UpdateStatus {
  pub update_available: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub latest_version: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub release_url: Option<String>,
  pub channel: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub checked_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct DashboardCounts {
  pub attention: u32,
  pub running: u32,
  pub ready: u32,
  pub direct: u32,
}

/// Pre-computed project group for dashboard display.
/// Server computes grouping once; clients render directly without re-grouping.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct DashboardProjectGroup {
  /// Project path used for grouping (e.g., "/Users/dev/myproject")
  pub path: String,
  /// Display name for the project (e.g., "myproject")
  pub name: String,
  /// Endpoint ID for multi-server setups
  pub endpoint_id: String,
  /// Optional endpoint display name
  #[serde(skip_serializing_if = "Option::is_none")]
  pub endpoint_name: Option<String>,
  /// Count of sessions needing attention (permission/question)
  pub attention_count: u32,
  /// Count of sessions currently working
  pub working_count: u32,
  /// Count of sessions ready/waiting
  pub ready_count: u32,
  /// Session IDs in this group (references into conversations array)
  pub session_ids: Vec<String>,
  /// Most recent activity timestamp in this group
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct DashboardSnapshot {
  pub revision: u64,
  pub conversations: Vec<DashboardConversationItem>,
  pub counts: DashboardCounts,
  /// Pre-computed project groups for efficient client rendering.
  /// Groups are sorted alphabetically by name.
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub project_groups: Vec<DashboardProjectGroup>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageSummaryModelCost {
  pub model: String,
  pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageSummaryBucket {
  pub session_count: u64,
  #[serde(default)]
  pub distinct_session_count: u64,
  pub total_tokens: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_cost_usd: f64,
  #[serde(default)]
  pub cost_by_model: Vec<UsageSummaryModelCost>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageSummarySnapshot {
  pub today: UsageSummaryBucket,
  pub all_time: UsageSummaryBucket,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageOverviewSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub today_start_unix: Option<u64>,
  pub summary: UsageSummarySnapshot,
  pub today_provider_breakdown: UsageBreakdownSnapshot,
  pub today_model_breakdown: UsageBreakdownSnapshot,
  pub day_breakdown: UsageBreakdownSnapshot,
}

#[derive(Debug, Clone, Copy, Serialize, serde::Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum UsageBreakdownGroupBy {
  Provider,
  #[default]
  Model,
  Session,
  Day,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageBreakdownEntry {
  pub group_key: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub provider: Option<Provider>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_id: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub day_start_unix: Option<u64>,
  pub turn_count: u64,
  pub session_count: u64,
  #[serde(default)]
  pub distinct_session_count: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_tokens: u64,
  pub total_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageBreakdownSnapshot {
  pub group_by: UsageBreakdownGroupBy,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub end_unix: Option<u64>,
  pub totals: UsageSummaryBucket,
  #[serde(default)]
  pub groups: Vec<UsageBreakdownEntry>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct UsageSessionSummary {
  pub session_id: String,
  pub provider: Provider,
  pub display_name: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub project_name: Option<String>,
  pub project_path: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub context_line: Option<String>,
  pub turn_count: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_tokens: u64,
  pub total_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsageSessionsSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub end_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub next_offset: Option<u64>,
  pub total_count: u64,
  #[serde(default)]
  pub sessions: Vec<UsageSessionSummary>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct UsagePricingSnapshotPayload {
  pub source: String,
  pub version: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_key: Option<String>,
  pub input_cost_per_token: f64,
  pub output_cost_per_token: f64,
  pub cache_read_cost_per_token: f64,
  pub cache_write_cost_per_token: f64,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct SessionUsageTurnEntry {
  pub turn_id: String,
  pub turn_seq: u64,
  pub provider: Provider,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub observed_at: Option<String>,
  pub snapshot_kind: super::TokenUsageSnapshotKind,
  pub raw_usage: super::TokenUsage,
  pub billable_input_tokens: u64,
  pub billable_output_tokens: u64,
  pub cache_read_tokens: u64,
  pub cache_write_tokens: u64,
  pub context_input_tokens: u64,
  pub estimated_cost_usd: f64,
  pub pricing: UsagePricingSnapshotPayload,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
pub struct SessionUsageTurnsPage {
  pub session_id: String,
  pub total_turn_count: u64,
  pub has_more_before: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub oldest_turn_seq: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub newest_turn_seq: Option<u64>,
  pub summary: UsageSummaryBucket,
  #[serde(default)]
  pub rows: Vec<SessionUsageTurnEntry>,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct MissionsSnapshot {
  pub revision: u64,
  pub missions: Vec<MissionSummary>,
}

/// Codex rate-limit window.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct CodexRateLimitWindow {
  pub used_percent: f64,
  pub window_duration_mins: u32,
  pub resets_at_unix: f64,
}

/// Codex-specific reason the account is currently blocked by usage limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRateLimitReachedType {
  RateLimitReached,
  WorkspaceOwnerCreditsDepleted,
  WorkspaceMemberCreditsDepleted,
  WorkspaceOwnerUsageLimitReached,
  WorkspaceMemberUsageLimitReached,
}

/// Endpoint-scoped Codex usage snapshot.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct CodexUsageSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub primary: Option<CodexRateLimitWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary: Option<CodexRateLimitWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub rate_limit_reached_type: Option<CodexRateLimitReachedType>,
  pub fetched_at_unix: f64,
}

/// Claude subscription usage window.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct ClaudeUsageWindow {
  pub utilization: f64,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub resets_at: Option<String>,
}

/// Endpoint-scoped Claude subscription usage snapshot.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct ClaudeUsageSnapshot {
  pub five_hour: ClaudeUsageWindow,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub seven_day: Option<ClaudeUsageWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub seven_day_sonnet: Option<ClaudeUsageWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub seven_day_opus: Option<ClaudeUsageWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub rate_limit_tier: Option<String>,
  pub fetched_at_unix: f64,
}
