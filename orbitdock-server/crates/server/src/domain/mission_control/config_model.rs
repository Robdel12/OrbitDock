use anyhow::Result;
use orbitdock_protocol::WorkspaceProviderKind;
use serde::{Deserialize, Serialize};

use crate::domain::mission_control::tracker::TrackerConfig;

fn default_tracker() -> String {
  "linear".to_string()
}
fn default_strategy() -> String {
  "single".to_string()
}
fn default_provider() -> String {
  "claude".to_string()
}
fn default_max_concurrent() -> u32 {
  3
}
fn default_trigger_kind() -> String {
  "polling".to_string()
}
fn default_poll_interval() -> u64 {
  60
}
fn default_max_retries() -> u32 {
  3
}
fn default_stall_timeout() -> u64 {
  600
}
fn default_base_branch() -> String {
  "main".to_string()
}
fn default_state_on_dispatch() -> String {
  "In Progress".to_string()
}
fn default_state_on_complete() -> String {
  "In Review".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MissionConfig {
  #[serde(default = "default_tracker")]
  pub tracker: String,
  #[serde(default)]
  pub provider: ProviderConfig,
  #[serde(default, skip_serializing_if = "WorkspaceConfig::is_empty")]
  pub workspace: WorkspaceConfig,
  #[serde(default)]
  pub agent: AgentConfig,
  #[serde(default)]
  pub trigger: TriggerConfig,
  #[serde(default)]
  pub orchestration: OrchestrationConfig,
}

impl Default for MissionConfig {
  fn default() -> Self {
    Self {
      tracker: default_tracker(),
      provider: ProviderConfig::default(),
      workspace: WorkspaceConfig::default(),
      agent: AgentConfig::default(),
      trigger: TriggerConfig::default(),
      orchestration: OrchestrationConfig::default(),
    }
  }
}

/// Flat partial-update for mission configuration.
#[derive(Default)]
pub struct MissionConfigUpdate {
  // Provider
  pub provider_strategy: Option<String>,
  pub primary_provider: Option<String>,
  pub secondary_provider: Option<Option<String>>,
  pub max_concurrent: Option<u32>,
  pub max_concurrent_primary: Option<Option<u32>>,
  // Agent — Claude
  pub agent_claude_model: Option<Option<String>>,
  pub agent_claude_effort: Option<Option<String>>,
  pub agent_claude_permission_mode: Option<Option<String>>,
  pub agent_claude_allowed_tools: Option<Vec<String>>,
  pub agent_claude_disallowed_tools: Option<Vec<String>>,
  pub agent_claude_allow_bypass_permissions: Option<bool>,
  // Agent — Codex
  pub agent_codex_model: Option<Option<String>>,
  pub agent_codex_effort: Option<Option<String>>,
  pub agent_codex_approval_policy: Option<Option<String>>,
  pub agent_codex_sandbox_mode: Option<Option<String>>,
  pub agent_codex_collaboration_mode: Option<Option<String>>,
  pub agent_codex_multi_agent: Option<Option<bool>>,
  pub agent_codex_personality: Option<Option<String>>,
  pub agent_codex_service_tier: Option<Option<String>>,
  pub agent_codex_developer_instructions: Option<Option<String>>,
  // Trigger
  pub trigger_kind: Option<String>,
  pub poll_interval: Option<u64>,
  pub label_filter: Option<Vec<String>>,
  pub state_filter: Option<Vec<String>>,
  pub project_key: Option<Option<String>>,
  pub team_key: Option<Option<String>>,
  // Orchestration
  pub max_retries: Option<u32>,
  pub stall_timeout: Option<u64>,
  pub base_branch: Option<String>,
  pub worktree_root_dir: Option<Option<String>>,
  pub state_on_dispatch: Option<String>,
  pub state_on_complete: Option<String>,
  // Tracker
  pub tracker: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ProviderConfig {
  #[serde(default = "default_strategy")]
  pub strategy: String,
  #[serde(default = "default_provider")]
  pub primary: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary: Option<String>,
  #[serde(default = "default_max_concurrent")]
  pub max_concurrent: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub max_concurrent_primary: Option<u32>,
}

impl Default for ProviderConfig {
  fn default() -> Self {
    Self {
      strategy: default_strategy(),
      primary: default_provider(),
      secondary: None,
      max_concurrent: default_max_concurrent(),
      max_concurrent_primary: None,
    }
  }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct WorkspaceConfig {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub provider: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub image: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub retention: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub retention_ttl: Option<u64>,
  #[serde(default, skip_serializing_if = "WorkspaceResources::is_empty")]
  pub resources: WorkspaceResources,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub setup_commands: Vec<String>,
}

impl WorkspaceConfig {
  pub fn is_empty(&self) -> bool {
    self.provider.is_none()
      && self.image.is_none()
      && self.retention.is_none()
      && self.retention_ttl.is_none()
      && self.resources.is_empty()
      && self.setup_commands.is_empty()
  }

  pub fn provider_kind(&self) -> Result<Option<WorkspaceProviderKind>> {
    match self
      .provider
      .as_deref()
      .map(str::trim)
      .filter(|value| !value.is_empty())
    {
      Some(value) => Ok(Some(
        value
          .parse()
          .map_err(|error: String| anyhow::anyhow!(error))?,
      )),
      None => Ok(None),
    }
  }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct WorkspaceResources {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cpu: Option<u32>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub memory: Option<String>,
}

impl WorkspaceResources {
  pub fn is_empty(&self) -> bool {
    self.cpu.is_none() && self.memory.is_none()
  }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TriggerConfig {
  #[serde(default = "default_trigger_kind")]
  pub kind: String,
  #[serde(default = "default_poll_interval")]
  pub interval: u64,
  #[serde(default)]
  pub filters: TriggerFilters,
}

impl Default for TriggerConfig {
  fn default() -> Self {
    Self {
      kind: default_trigger_kind(),
      interval: default_poll_interval(),
      filters: TriggerFilters::default(),
    }
  }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct TriggerFilters {
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub labels: Vec<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub states: Vec<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub project: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub team: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct OrchestrationConfig {
  #[serde(default = "default_max_retries")]
  pub max_retries: u32,
  #[serde(default = "default_stall_timeout")]
  pub stall_timeout: u64,
  #[serde(default = "default_base_branch")]
  pub base_branch: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub worktree_root_dir: Option<String>,
  #[serde(default = "default_state_on_dispatch")]
  pub state_on_dispatch: String,
  #[serde(default = "default_state_on_complete")]
  pub state_on_complete: String,
}

impl Default for OrchestrationConfig {
  fn default() -> Self {
    Self {
      max_retries: default_max_retries(),
      stall_timeout: default_stall_timeout(),
      base_branch: default_base_branch(),
      worktree_root_dir: None,
      state_on_dispatch: default_state_on_dispatch(),
      state_on_complete: default_state_on_complete(),
    }
  }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentConfig {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub claude: Option<ClaudeAgentConfig>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub codex: Option<CodexAgentConfig>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ClaudeAgentConfig {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub allowed_tools: Vec<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub disallowed_tools: Vec<String>,
  #[serde(default)]
  pub allow_bypass_permissions: bool,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub skills: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CodexAgentConfig {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub collaboration_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub multi_agent: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub personality: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub service_tier: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub skills: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ResolvedAgentSettings {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub collaboration_mode: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub multi_agent: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub personality: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub service_tier: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
  pub allow_bypass_permissions: bool,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub allowed_tools: Vec<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub disallowed_tools: Vec<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub skills: Vec<String>,
}

impl AgentConfig {
  /// Resolve mission runtime settings for the given provider name.
  pub fn resolve_for_provider(&self, provider: &str) -> ResolvedAgentSettings {
    match provider {
      "claude" => {
        if let Some(c) = &self.claude {
          let pm = c
            .permission_mode
            .clone()
            .unwrap_or_else(|| "acceptEdits".to_string());
          let allowed = if c.allowed_tools.is_empty() {
            vec!["Bash(git:*)".to_string()]
          } else {
            c.allowed_tools.clone()
          };
          let disallowed = if c.disallowed_tools.is_empty() {
            vec!["Bash(rm:*)".to_string()]
          } else {
            c.disallowed_tools.clone()
          };
          ResolvedAgentSettings {
            model: c.model.clone(),
            effort: c.effort.clone(),
            permission_mode: Some(pm),
            allowed_tools: allowed,
            disallowed_tools: disallowed,
            allow_bypass_permissions: true,
            skills: c.skills.clone(),
            ..Default::default()
          }
        } else {
          ResolvedAgentSettings {
            permission_mode: Some("acceptEdits".to_string()),
            allow_bypass_permissions: true,
            ..Default::default()
          }
        }
      }
      "codex" => {
        if let Some(x) = &self.codex {
          ResolvedAgentSettings {
            model: x.model.clone(),
            effort: x.effort.clone(),
            approval_policy: Some(
              x.approval_policy
                .clone()
                .unwrap_or_else(|| "never".to_string()),
            ),
            sandbox_mode: Some(
              x.sandbox_mode
                .clone()
                .unwrap_or_else(|| "workspace-write".to_string()),
            ),
            collaboration_mode: x.collaboration_mode.clone(),
            multi_agent: x.multi_agent,
            personality: x.personality.clone(),
            service_tier: x.service_tier.clone(),
            developer_instructions: x.developer_instructions.clone(),
            skills: x.skills.clone(),
            ..Default::default()
          }
        } else {
          ResolvedAgentSettings {
            approval_policy: Some("never".to_string()),
            sandbox_mode: Some("workspace-write".to_string()),
            ..Default::default()
          }
        }
      }
      _ => ResolvedAgentSettings::default(),
    }
  }
}

impl MissionConfig {
  pub fn to_tracker_config(&self) -> TrackerConfig {
    TrackerConfig {
      project_key: self.trigger.filters.project.clone(),
      team_key: self.trigger.filters.team.clone(),
      label_filter: self.trigger.filters.labels.clone(),
      state_filter: self.trigger.filters.states.clone(),
    }
  }

  /// Apply a partial update, merging only the fields that are `Some`.
  pub fn apply_update(&mut self, u: MissionConfigUpdate) {
    // Provider
    if let Some(v) = u.provider_strategy {
      self.provider.strategy = v;
    }
    if let Some(v) = u.primary_provider {
      self.provider.primary = v;
    }
    if let Some(v) = u.secondary_provider {
      self.provider.secondary = v;
    }
    if let Some(v) = u.max_concurrent {
      self.provider.max_concurrent = v;
    }
    if let Some(v) = u.max_concurrent_primary {
      self.provider.max_concurrent_primary = v;
    }

    // Agent — Claude
    let has_claude = u.agent_claude_model.is_some()
      || u.agent_claude_effort.is_some()
      || u.agent_claude_permission_mode.is_some()
      || u.agent_claude_allowed_tools.is_some()
      || u.agent_claude_disallowed_tools.is_some()
      || u.agent_claude_allow_bypass_permissions.is_some();
    if has_claude {
      let claude = self
        .agent
        .claude
        .get_or_insert_with(ClaudeAgentConfig::default);
      if let Some(v) = u.agent_claude_model {
        claude.model = v;
      }
      if let Some(v) = u.agent_claude_effort {
        claude.effort = v;
      }
      if let Some(v) = u.agent_claude_permission_mode {
        claude.permission_mode = v;
      }
      if let Some(v) = u.agent_claude_allowed_tools {
        claude.allowed_tools = v;
      }
      if let Some(v) = u.agent_claude_disallowed_tools {
        claude.disallowed_tools = v;
      }
      if let Some(v) = u.agent_claude_allow_bypass_permissions {
        claude.allow_bypass_permissions = v;
      }
    }

    // Agent — Codex
    let has_codex = u.agent_codex_model.is_some()
      || u.agent_codex_effort.is_some()
      || u.agent_codex_approval_policy.is_some()
      || u.agent_codex_sandbox_mode.is_some()
      || u.agent_codex_collaboration_mode.is_some()
      || u.agent_codex_multi_agent.is_some()
      || u.agent_codex_personality.is_some()
      || u.agent_codex_service_tier.is_some()
      || u.agent_codex_developer_instructions.is_some();
    if has_codex {
      let codex = self
        .agent
        .codex
        .get_or_insert_with(CodexAgentConfig::default);
      if let Some(v) = u.agent_codex_model {
        codex.model = v;
      }
      if let Some(v) = u.agent_codex_effort {
        codex.effort = v;
      }
      if let Some(v) = u.agent_codex_approval_policy {
        codex.approval_policy = v;
      }
      if let Some(v) = u.agent_codex_sandbox_mode {
        codex.sandbox_mode = v;
      }
      if let Some(v) = u.agent_codex_collaboration_mode {
        codex.collaboration_mode = v;
      }
      if let Some(v) = u.agent_codex_multi_agent {
        codex.multi_agent = v;
      }
      if let Some(v) = u.agent_codex_personality {
        codex.personality = v;
      }
      if let Some(v) = u.agent_codex_service_tier {
        codex.service_tier = v;
      }
      if let Some(v) = u.agent_codex_developer_instructions {
        codex.developer_instructions = v;
      }
    }

    // Trigger
    if let Some(v) = u.trigger_kind {
      self.trigger.kind = v;
    }
    if let Some(v) = u.poll_interval {
      self.trigger.interval = v;
    }
    if let Some(v) = u.label_filter {
      self.trigger.filters.labels = v;
    }
    if let Some(v) = u.state_filter {
      self.trigger.filters.states = v;
    }
    if let Some(v) = u.project_key {
      self.trigger.filters.project = v;
    }
    if let Some(v) = u.team_key {
      self.trigger.filters.team = v;
    }

    // Orchestration
    if let Some(v) = u.max_retries {
      self.orchestration.max_retries = v;
    }
    if let Some(v) = u.stall_timeout {
      self.orchestration.stall_timeout = v;
    }
    if let Some(v) = u.base_branch {
      self.orchestration.base_branch = v;
    }
    if let Some(v) = u.worktree_root_dir {
      self.orchestration.worktree_root_dir = v;
    }
    if let Some(v) = u.state_on_dispatch {
      self.orchestration.state_on_dispatch = v;
    }
    if let Some(v) = u.state_on_complete {
      self.orchestration.state_on_complete = v;
    }

    // Tracker
    if let Some(v) = u.tracker {
      self.tracker = v;
    }
  }
}
