use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeStatus {
  Active,
  Orphaned,
  Stale,
  Removing,
  Removed,
}

impl WorktreeStatus {
  pub fn as_str(&self) -> &'static str {
    match self {
      Self::Active => "active",
      Self::Orphaned => "orphaned",
      Self::Stale => "stale",
      Self::Removing => "removing",
      Self::Removed => "removed",
    }
  }

  pub fn from_str_opt(s: &str) -> Option<Self> {
    match s {
      "active" => Some(Self::Active),
      "orphaned" => Some(Self::Orphaned),
      "stale" => Some(Self::Stale),
      "removing" => Some(Self::Removing),
      "removed" => Some(Self::Removed),
      _ => None,
    }
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeOrigin {
  User,
  Agent,
  Discovered,
}

impl WorktreeOrigin {
  pub fn as_str(&self) -> &'static str {
    match self {
      Self::User => "user",
      Self::Agent => "agent",
      Self::Discovered => "discovered",
    }
  }

  pub fn from_str_opt(s: &str) -> Option<Self> {
    match s {
      "user" => Some(Self::User),
      "agent" => Some(Self::Agent),
      "discovered" => Some(Self::Discovered),
      _ => None,
    }
  }
}

#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct WorktreeSummary {
  pub id: String,
  pub repo_root: String,
  pub worktree_path: String,
  pub branch: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub base_branch: Option<String>,
  pub status: WorktreeStatus,
  pub active_session_count: u32,
  pub total_session_count: u32,
  pub created_at: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_session_ended_at: Option<String>,
  pub disk_present: bool,
  pub auto_prune: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub custom_name: Option<String>,
  pub created_by: WorktreeOrigin,
}
