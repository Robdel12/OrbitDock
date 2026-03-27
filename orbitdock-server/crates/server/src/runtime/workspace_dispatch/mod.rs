//! Runtime-owned workspace dispatch providers for mission control.
//!
//! A workspace provider abstracts *where* a mission's coding agent runs
//! **and** how it gets started. The provider owns the runtime lifecycle:
//! workspace creation, session setup, agent launch, and initial prompt
//! delivery.

pub(crate) mod daytona;
pub(crate) mod local;

use std::sync::Arc;

use async_trait::async_trait;
use orbitdock_protocol::WorkspaceProviderKind;

use crate::domain::mission_control::config::{AgentConfig, WorkspaceConfig};

use super::session_registry::SessionRegistry;

/// Provision a workspace and start an agent session for a mission issue.
///
/// The provider handles the full lifecycle: workspace creation (git
/// worktree, container, VM, ...), environment setup (`.mcp.json`, hooks),
/// session creation, agent launch, and initial prompt delivery.
#[async_trait]
pub(crate) trait WorkspaceProvider: Send + Sync {
  /// Set up a workspace, start an agent, and deliver the initial prompt.
  ///
  /// Returns the session ID of the running agent on success.
  async fn dispatch(&self, request: &DispatchRequest) -> Result<DispatchResult, WorkspaceError>;
}

/// Everything a workspace provider needs to provision a workspace and
/// start an agent session.
pub(crate) struct DispatchRequest {
  /// Absolute path to the repository root.
  pub repo_root: String,
  /// Minimal issue reference (id + identifier).
  pub issue: WorkspaceIssueRef,
  /// Remote branch to base the workspace on (e.g. `"main"`).
  pub base_branch: String,
  /// Optional custom root directory for worktrees.
  pub worktree_root_dir: Option<String>,
  /// Mission row ID.
  pub mission_id: String,
  /// Tracker kind string (e.g. `"linear"`, `"github"`).
  pub tracker_kind: String,
  /// Tracker API key for MCP config injection, if available.
  pub tracker_api_key: Option<String>,
  /// Which agent provider to use (e.g. `"claude"`, `"codex"`).
  pub provider_str: String,
  /// Agent configuration from `MISSION.md`.
  pub agent_config: AgentConfig,
  /// Workspace-specific overrides from `MISSION.md`.
  pub workspace_config: WorkspaceConfig,
  /// Rendered prompt to send as the first message.
  pub prompt: String,
  /// Session registry for persistence and connector access.
  pub registry: Arc<SessionRegistry>,
}

/// Minimal issue reference needed for workspace provisioning.
pub(crate) struct WorkspaceIssueRef {
  pub id: String,
  pub identifier: String,
}

/// Result of a successful workspace dispatch.
pub(crate) enum DispatchResult {
  /// The workspace provider fully launched the agent session.
  Running {
    session_id: String,
    workspace_id: Option<String>,
  },
  /// The provider provisioned a remote workspace and handed off launch.
  Provisioning { workspace_id: String },
}

#[derive(Debug)]
pub(crate) enum WorkspaceError {
  /// Workspace provisioning or agent startup failed.
  Failed(String),
}

impl std::fmt::Display for WorkspaceError {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    match self {
      Self::Failed(msg) => write!(f, "{msg}"),
    }
  }
}

impl std::error::Error for WorkspaceError {}

pub(crate) fn build_workspace_provider(
  provider_kind: WorkspaceProviderKind,
) -> anyhow::Result<Arc<dyn WorkspaceProvider>> {
  match provider_kind {
    WorkspaceProviderKind::Local => Ok(Arc::new(local::LocalWorkspaceProvider::new())),
    WorkspaceProviderKind::Daytona => Ok(Arc::new(daytona::DaytonaWorkspaceProvider::new()?)),
  }
}
