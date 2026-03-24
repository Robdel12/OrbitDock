//! Pluggable workspace providers for mission dispatch.
//!
//! A workspace provider abstracts *where* a mission's coding agent runs
//! **and** how it gets started.  The provider owns the full lifecycle:
//! workspace creation, session setup, agent launch, and initial prompt
//! delivery.
//!
//! The [`LocalWorkspaceProvider`](local::LocalWorkspaceProvider) creates a
//! local git worktree and starts the agent on this machine — the same
//! behavior OrbitDock has always had.  Future providers (Daytona, Docker,
//! SSH, …) will implement the same trait to provision remote environments,
//! start OrbitDock in managed mode inside them, and relay the prompt.

pub(crate) mod local;

use std::sync::Arc;

use async_trait::async_trait;

use crate::domain::mission_control::config::AgentConfig;
use crate::runtime::session_registry::SessionRegistry;

// ── Trait ────────────────────────────────────────────────────────────────

/// Provision a workspace and start an agent session for a mission issue.
///
/// The provider handles the full lifecycle: workspace creation (git
/// worktree, container, VM, …), environment setup (.mcp.json, hooks),
/// session creation, agent launch, and initial prompt delivery.
#[async_trait]
pub(crate) trait WorkspaceProvider: Send + Sync {
    /// Set up a workspace, start an agent, and deliver the initial prompt.
    ///
    /// Returns the session ID of the running agent on success.
    async fn dispatch(&self, request: &DispatchRequest) -> Result<DispatchResult, WorkspaceError>;
}

// ── Request / Response ───────────────────────────────────────────────────

/// Everything a workspace provider needs to provision a workspace and
/// start an agent session.
pub(crate) struct DispatchRequest {
    // ── Workspace provisioning ───────────────────────────────────────
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

    // ── Tracker context (for MCP config) ─────────────────────────────
    /// Tracker kind string (e.g. `"linear"`, `"github"`).
    pub tracker_kind: String,
    /// Tracker API key for MCP config injection, if available.
    pub tracker_api_key: Option<String>,

    // ── Agent session ────────────────────────────────────────────────
    /// Which agent provider to use (e.g. `"claude"`, `"codex"`).
    pub provider_str: String,
    /// Agent configuration from MISSION.md.
    pub agent_config: AgentConfig,
    /// Rendered prompt to send as the first message.
    pub prompt: String,

    // ── Shared services ──────────────────────────────────────────────
    /// Session registry for persistence and connector access.
    pub registry: Arc<SessionRegistry>,
}

/// Minimal issue reference needed for workspace provisioning.
pub(crate) struct WorkspaceIssueRef {
    pub id: String,
    pub identifier: String,
}

/// Result of a successful workspace dispatch.
pub(crate) struct DispatchResult {
    /// The session ID of the running agent.
    pub session_id: String,
}

// ── Error ────────────────────────────────────────────────────────────────

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
