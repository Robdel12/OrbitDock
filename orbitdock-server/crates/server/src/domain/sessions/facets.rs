//! Grouped session concerns (facets).
//!
//! Each struct represents a coherent slice of session state that travels
//! together through create, restore, mutate, and project paths.

use orbitdock_protocol::{
    CodexApprovalPolicy, CodexConfigMode, CodexConfigSource, CodexSessionOverrides, Provider,
};

/// Core identity fields that are immutable after creation.
#[derive(Debug, Clone)]
pub struct SessionIdentity {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    pub transcript_path: Option<String>,
    pub project_name: Option<String>,
}

/// Durable, mutable configuration — the fields that `set_config` can change.
///
/// All fields are `Option` because every config value is optional at creation
/// and nullable in the database.  A `SessionConfig` with all-`None` fields is
/// valid (empty config).  `SessionConfigPatch` is a type alias for this same
/// struct — when used as a patch, `None` means "don't change".
#[derive(Debug, Default, Clone)]
pub struct SessionConfig {
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub approval_policy_details: Option<CodexApprovalPolicy>,
    pub sandbox_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<String>,
    pub codex_model_provider: Option<String>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides: Option<CodexSessionOverrides>,
    pub effort: Option<String>,
}

impl SessionConfig {
    /// Merge non-`None` fields from `patch` into `self`.
    pub fn merge_from(&mut self, patch: SessionConfig) {
        if patch.model.is_some() {
            self.model = patch.model;
        }
        if patch.approval_policy.is_some() {
            self.approval_policy = patch.approval_policy;
        }
        if patch.approval_policy_details.is_some() {
            self.approval_policy_details = patch.approval_policy_details;
        }
        if patch.sandbox_mode.is_some() {
            self.sandbox_mode = patch.sandbox_mode;
        }
        if patch.collaboration_mode.is_some() {
            self.collaboration_mode = patch.collaboration_mode;
        }
        if patch.multi_agent.is_some() {
            self.multi_agent = patch.multi_agent;
        }
        if patch.personality.is_some() {
            self.personality = patch.personality;
        }
        if patch.service_tier.is_some() {
            self.service_tier = patch.service_tier;
        }
        if patch.developer_instructions.is_some() {
            self.developer_instructions = patch.developer_instructions;
        }
        if patch.codex_config_mode.is_some() {
            self.codex_config_mode = patch.codex_config_mode;
        }
        if patch.codex_config_profile.is_some() {
            self.codex_config_profile = patch.codex_config_profile;
        }
        if patch.codex_model_provider.is_some() {
            self.codex_model_provider = patch.codex_model_provider;
        }
        if patch.codex_config_source.is_some() {
            self.codex_config_source = patch.codex_config_source;
        }
        if patch.codex_config_overrides.is_some() {
            self.codex_config_overrides = patch.codex_config_overrides;
        }
        if patch.effort.is_some() {
            self.effort = patch.effort;
        }
    }
}

/// User-facing display metadata.
#[derive(Debug, Default, Clone)]
pub struct SessionDisplay {
    pub custom_name: Option<String>,
    pub summary: Option<String>,
    pub first_prompt: Option<String>,
    pub last_message: Option<String>,
}

/// Git and working-directory context.
#[derive(Debug, Default, Clone)]
pub struct SessionEnvironment {
    pub git_branch: Option<String>,
    pub git_sha: Option<String>,
    pub current_cwd: Option<String>,
    pub repository_root: Option<String>,
    pub is_worktree: bool,
    pub worktree_id: Option<String>,
}

/// Temporal metadata.
#[derive(Debug, Default, Clone)]
pub struct SessionTimestamps {
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub last_progress_at: Option<String>,
}
