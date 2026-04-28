use serde::{Deserialize, Serialize};

/// AI provider type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
  Claude,
  Codex,
}

impl std::str::FromStr for Provider {
  type Err = std::convert::Infallible;

  fn from_str(s: &str) -> Result<Self, Self::Err> {
    Ok(match s {
      "codex" => Provider::Codex,
      _ => Provider::Claude,
    })
  }
}

/// Where mission workspaces should be provisioned and run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceProviderKind {
  #[default]
  Local,
  Daytona,
}

impl WorkspaceProviderKind {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Local => "local",
      Self::Daytona => "daytona",
    }
  }
}

impl std::str::FromStr for WorkspaceProviderKind {
  type Err = String;

  fn from_str(s: &str) -> Result<Self, Self::Err> {
    match s.trim().to_ascii_lowercase().as_str() {
      "local" => Ok(Self::Local),
      "daytona" => Ok(Self::Daytona),
      other => Err(format!("unsupported workspace provider '{other}'")),
    }
  }
}

/// Session status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
  Active,
  Ended,
}

/// Outcome of a steer-turn attempt, surfaced to clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SteerOutcome {
  /// The steer was accepted by the active turn.
  Accepted,
}

/// Work status - what the agent is currently doing
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkStatus {
  Working,
  Waiting,
  Permission,
  Question,
  Reply,
  Ended,
}

/// Terminal outcome of a shell command execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellExecutionOutcome {
  Completed,
  Failed,
  TimedOut,
  Canceled,
}

/// Normalized approval decision used by OrbitDock's client-facing API.
///
/// This stays stable for UI and transport code, then gets translated into
/// provider-native approval commands before reaching a connector.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolApprovalDecision {
  Approved,
  ApprovedForSession,
  ApprovedAlways,
  Denied,
  Abort,
}

impl ToolApprovalDecision {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Approved => "approved",
      Self::ApprovedForSession => "approved_for_session",
      Self::ApprovedAlways => "approved_always",
      Self::Denied => "denied",
      Self::Abort => "abort",
    }
  }
}

impl std::fmt::Display for ToolApprovalDecision {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    f.write_str(self.as_str())
  }
}

/// Rate limit information from the Claude SDK
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateLimitInfo {
  pub status: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub resets_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub rate_limit_type: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub utilization: Option<f64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub is_using_overage: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub overage_status: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub surpassed_threshold: Option<f64>,
}

/// Token usage information
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenUsage {
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub context_window: u64,
}

/// Semantics for a token usage snapshot.
///
/// OrbitDock receives token values with different meaning depending on provider/integration mode.
/// Persist this explicitly so analytics and rollups stay correct.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenUsageSnapshotKind {
  /// Snapshot semantics are unknown.
  #[default]
  Unknown,
  /// Snapshot represents current turn/context occupancy, not lifetime totals.
  ContextTurn,
  /// Snapshot represents lifetime cumulative totals.
  LifetimeTotals,
  /// Snapshot mixes semantics (e.g. context input + cumulative output).
  Mixed,
  /// Snapshot was emitted after a compaction reset event.
  CompactionReset,
}

impl TokenUsage {
  /// Calculate context fill percentage
  pub fn context_fill_percent(&self) -> f64 {
    if self.context_window == 0 {
      return 0.0;
    }
    (self.input_tokens as f64 / self.context_window as f64) * 100.0
  }

  /// Calculate cache hit percentage
  pub fn cache_hit_percent(&self) -> f64 {
    if self.input_tokens == 0 {
      return 0.0;
    }
    (self.cached_tokens as f64 / self.input_tokens as f64) * 100.0
  }
}
