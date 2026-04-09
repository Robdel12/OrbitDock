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
  /// Resolve agent settings for the given provider name.
  ///
  /// Mission agents run headless - defaults ensure agents can operate
  /// autonomously without stalling on permission prompts.
  pub fn resolve_settings(
    &self,
    provider: &str,
    defaults: Option<ResolvedAgentSettings>,
  ) -> ResolvedAgentSettings {
    let mut settings = defaults.unwrap_or_default();
    match provider {
      "claude" => {
        if let Some(config) = self.claude.as_ref() {
          settings.model = config.model.clone().or(settings.model);
          settings.effort = config.effort.clone().or(settings.effort);
          settings.permission_mode = config.permission_mode.clone().or(settings.permission_mode);
          settings.allow_bypass_permissions = config.allow_bypass_permissions;
        }
      }
      "codex" => {
        if let Some(config) = self.codex.as_ref() {
          settings.model = config.model.clone().or(settings.model);
          settings.effort = config.effort.clone().or(settings.effort);
          settings.approval_policy = config.approval_policy.clone().or(settings.approval_policy);
          settings.sandbox_mode = config.sandbox_mode.clone().or(settings.sandbox_mode);
          settings.collaboration_mode = config
            .collaboration_mode
            .clone()
            .or(settings.collaboration_mode);
          settings.multi_agent = config.multi_agent.or(settings.multi_agent);
          settings.personality = config.personality.clone().or(settings.personality);
          settings.service_tier = config.service_tier.clone().or(settings.service_tier);
          settings.developer_instructions = config
            .developer_instructions
            .clone()
            .or(settings.developer_instructions);
          settings.model_provider = config.model_provider.clone().or(settings.model_provider);
        }
      }
      _ => {}
    }
    settings
  }

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
}
