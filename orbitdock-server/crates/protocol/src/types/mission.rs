use serde::Serialize;

use super::{Provider, WorkStatus};

/// Orchestration state for a mission issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrchestrationState {
  Queued,
  Claimed,
  Provisioning,
  Running,
  RetryQueued,
  Completed,
  Failed,
  Blocked,
}

impl OrchestrationState {
  /// Returns the valid admin transitions from this state.
  pub fn allowed_transitions(&self) -> Vec<OrchestrationState> {
    match self {
      Self::Queued => vec![Self::Completed, Self::Blocked],
      Self::Claimed => vec![
        Self::Queued,
        Self::Provisioning,
        Self::Completed,
        Self::Blocked,
        Self::Failed,
      ],
      Self::Provisioning => {
        vec![
          Self::Queued,
          Self::Running,
          Self::Completed,
          Self::Blocked,
          Self::Failed,
        ]
      }
      Self::Running => vec![Self::Queued, Self::Completed, Self::Blocked, Self::Failed],
      Self::RetryQueued => vec![Self::Queued, Self::Completed, Self::Blocked],
      Self::Failed => vec![Self::Queued, Self::Completed],
      Self::Blocked => vec![Self::Queued, Self::Completed],
      Self::Completed => vec![Self::Queued],
    }
  }

  /// Check if transitioning to the target state is valid.
  pub fn can_transition_to(&self, target: &Self) -> bool {
    self.allowed_transitions().contains(target)
  }

  /// Convert to the DB string representation.
  pub fn as_db_str(&self) -> &'static str {
    match self {
      Self::Queued => "queued",
      Self::Claimed => "claimed",
      Self::Provisioning => "provisioning",
      Self::Running => "running",
      Self::RetryQueued => "retry_queued",
      Self::Completed => "completed",
      Self::Failed => "failed",
      Self::Blocked => "blocked",
    }
  }

  /// Parse from DB string representation.
  pub fn from_db_str(s: &str) -> Option<Self> {
    match s {
      "queued" => Some(Self::Queued),
      "claimed" => Some(Self::Claimed),
      "provisioning" => Some(Self::Provisioning),
      "running" => Some(Self::Running),
      "retry_queued" => Some(Self::RetryQueued),
      "completed" => Some(Self::Completed),
      "failed" => Some(Self::Failed),
      "blocked" => Some(Self::Blocked),
      _ => None,
    }
  }
}

/// Summary of a configured mission.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct MissionSummary {
  pub id: String,
  pub name: String,
  pub repo_root: String,
  pub enabled: bool,
  pub paused: bool,
  pub tracker_kind: String,
  pub provider_strategy: String,
  pub primary_provider: Provider,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary_provider: Option<Provider>,
  pub active_count: u32,
  pub queued_count: u32,
  pub completed_count: u32,
  pub failed_count: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub parse_error: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub orchestrator_status: Option<String>,
  /// ISO-8601 timestamp of the last orchestrator poll for this mission.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_polled_at: Option<String>,
  /// Configured poll interval in seconds.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub poll_interval: Option<u64>,
  /// Custom mission file path (e.g. `MISSION-foo.md`). `None` means default `MISSION.md`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub mission_file_path: Option<String>,
  /// Where the tracker credential comes from: "mission", "env", "global", or `None`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub tracker_key_source: Option<String>,
}

/// Server-authored prompt metadata for mission worktree cleanup UX.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct MissionCleanupPrompt {
  /// Number of mission-linked worktrees that are still present on disk and
  /// eligible for review/cleanup in the client.
  pub lingering_worktree_count: u32,
}

/// A single issue tracked by a mission.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct MissionIssueItem {
  pub issue_id: String,
  pub identifier: String,
  pub title: String,
  pub tracker_state: String,
  pub orchestration_state: OrchestrationState,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_id: Option<String>,
  pub provider: Provider,
  pub attempt: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub error: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub url: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub completed_at: Option<String>,
  /// Valid admin transitions from the current state (server-driven UX).
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub allowed_transitions: Vec<OrchestrationState>,
  /// Live work status from the linked session (only present for running issues).
  #[serde(skip_serializing_if = "Option::is_none")]
  pub work_status: Option<WorkStatus>,
  /// Most recent agent message or activity summary.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_message: Option<String>,
  /// URL of the linked pull request (set by `mission_link_pr`).
  #[serde(skip_serializing_if = "Option::is_none")]
  pub pr_url: Option<String>,
}
