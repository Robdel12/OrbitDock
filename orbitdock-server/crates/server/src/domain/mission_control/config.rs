use anyhow::{Context, Result};
use orbitdock_protocol::WorkspaceProviderKind;
use serde::{Deserialize, Serialize};

use super::template::default_mission_template;
use super::tracker::TrackerConfig;

// ── Default-value helpers ────────────────────────────────────────────

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

// ── Config types ─────────────────────────────────────────────────────

/// Parsed mission configuration from MISSION.md YAML front matter.
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
  /// Tracker state to set when an issue is dispatched (default: "In Progress").
  #[serde(default = "default_state_on_dispatch")]
  pub state_on_dispatch: String,
  /// Tracker state to set when a session completes (default: "Done").
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

// ── Agent config (per-provider overrides) ────────────────────────────

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
  /// When true, pass `--allow-dangerously-skip-permissions` at launch so
  /// mid-session switches to `bypassPermissions` are permitted.
  #[serde(default)]
  pub allow_bypass_permissions: bool,
  /// Skills to inject into the initial mission prompt (e.g. `["testing-philosophy"]`).
  /// Skill content is read from `~/.claude/skills/{name}/SKILL.md` and prepended to the prompt.
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
  /// Skills to attach to the initial mission prompt (e.g. `["testing-philosophy"]`).
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub skills: Vec<String>,
}

/// Resolved agent settings that map 1:1 to `DirectSessionRequest` fields.
#[derive(Debug, Clone, Default)]
pub struct ResolvedAgentSettings {
  pub model: Option<String>,
  pub effort: Option<String>,
  pub permission_mode: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub allowed_tools: Vec<String>,
  pub disallowed_tools: Vec<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub allow_bypass_permissions: bool,
  /// Skill names to attach to the initial mission prompt (Codex only).
  pub skills: Vec<String>,
}

impl AgentConfig {
  /// Resolve agent settings for the given provider name.
  ///
  /// Mission agents run headless — defaults ensure agents can operate
  /// autonomously without stalling on permission prompts:
  /// - Claude: `permission_mode` defaults to `"acceptEdits"`, `allowed_tools` to `["Bash(git:*)"]`
  /// - Codex: `approval_policy` defaults to `"never"` (fullAuto) + `"workspace-write"` sandbox
  /// - Codex: `approval_policy` defaults to `"never"` (fullAuto), `sandbox_mode` to `"workspace-write"`
  pub fn resolve_for_provider(&self, provider: &str) -> ResolvedAgentSettings {
    match provider {
      "claude" => {
        if let Some(c) = &self.claude {
          let pm = c
            .permission_mode
            .clone()
            .unwrap_or_else(|| "acceptEdits".to_string());
          // Mission sessions default to bypass enabled — unattended agents
          // that get stuck on a permission prompt are effectively dead.
          let allow_bypass = true;
          // Default allowed/disallowed tools for missions when user hasn't
          // configured any. Bash(git:*) lets the agent push branches and
          // create PRs without prompting; Bash(rm:*) prevents accidental
          // recursive deletion.
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
            allow_bypass_permissions: allow_bypass,
            skills: c.skills.clone(),
            ..Default::default()
          }
        } else {
          // No claude config at all — still apply mission-safe default
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
          // No codex config at all — fullAuto + sandbox for unattended work
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

// ── Symphony WORKFLOW.md migration ───────────────────────────────────

/// Symphony's WORKFLOW.md tracker config.
#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyTracker {
  #[serde(default)]
  kind: String,
  #[serde(default)]
  project_slug: Option<String>,
  #[serde(default)]
  active_states: Vec<String>,
}

/// Symphony's WORKFLOW.md polling config.
#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyPolling {
  #[serde(default)]
  interval_ms: u64,
}

/// Symphony's WORKFLOW.md agent config.
#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyAgent {
  #[serde(default)]
  max_concurrent_agents: u32,
}

/// Symphony's WORKFLOW.md codex config.
#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyCodex {
  #[serde(default)]
  command: Option<String>,
}

/// Top-level Symphony WORKFLOW.md schema.
#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyWorkflow {
  #[serde(default)]
  tracker: SymphonyTracker,
  #[serde(default)]
  polling: SymphonyPolling,
  #[serde(default)]
  agent: SymphonyAgent,
  #[serde(default)]
  codex: SymphonyCodex,
}

/// Try to parse a Symphony WORKFLOW.md and convert to MissionConfig.
/// Returns None if the content doesn't look like a Symphony workflow.
pub fn try_parse_symphony_workflow(content: &str) -> Option<MissionConfig> {
  let content = content.trim();
  if !content.starts_with("---") {
    return None;
  }

  let after_first = &content[3..];
  let end_idx = after_first.find("\n---")?;
  let yaml_block = &after_first[..end_idx];

  // Must have at least one Symphony-specific key
  if !yaml_block.contains("tracker:")
    && !yaml_block.contains("polling:")
    && !yaml_block.contains("agent:")
    && !yaml_block.contains("codex:")
  {
    return None;
  }

  let symphony: SymphonyWorkflow = serde_yaml::from_str(yaml_block).ok()?;

  // Only convert if there's meaningful config (not all defaults)
  let has_config = !symphony.tracker.kind.is_empty()
    || symphony.tracker.project_slug.is_some()
    || !symphony.tracker.active_states.is_empty()
    || symphony.polling.interval_ms > 0
    || symphony.agent.max_concurrent_agents > 0;

  if !has_config {
    return None;
  }

  // Detect provider from codex command
  let primary = if symphony.codex.command.is_some() {
    "codex".to_string()
  } else {
    "claude".to_string()
  };

  let interval = if symphony.polling.interval_ms > 0 {
    symphony.polling.interval_ms / 1000
  } else {
    60
  };

  let max_concurrent = if symphony.agent.max_concurrent_agents > 0 {
    symphony.agent.max_concurrent_agents
  } else {
    3
  };

  Some(MissionConfig {
    tracker: if symphony.tracker.kind.is_empty() {
      "linear".to_string()
    } else {
      symphony.tracker.kind
    },
    provider: ProviderConfig {
      strategy: "single".to_string(),
      primary,
      secondary: None,
      max_concurrent,
      max_concurrent_primary: None,
    },
    agent: AgentConfig::default(),
    workspace: WorkspaceConfig::default(),
    trigger: TriggerConfig {
      kind: "polling".to_string(),
      interval,
      filters: TriggerFilters {
        labels: Vec::new(),
        states: symphony.tracker.active_states,
        project: symphony.tracker.project_slug,
        team: None,
      },
    },
    orchestration: OrchestrationConfig::default(),
  })
}

// ── Public API ───────────────────────────────────────────────────────

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

/// Parsed MISSION.md: config + prompt template.
#[derive(Debug, Clone)]
pub struct MissionDefinition {
  pub config: MissionConfig,
  pub prompt_template: String,
}

/// Parse a MISSION.md file: YAML front matter between `---` fences, rest is Liquid template.
///
/// Supports the top-level `MissionConfig` schema and legacy flat schema for backward compat.
pub fn parse_mission_file(content: &str) -> Result<MissionDefinition> {
  let content = content.trim();
  if !content.starts_with("---") {
    anyhow::bail!("MISSION.md must start with YAML front matter (---)");
  }

  let after_first = &content[3..];
  let end_idx = after_first
    .find("\n---")
    .context("MISSION.md missing closing --- for YAML front matter")?;

  let yaml_block = &after_first[..end_idx];
  let prompt_start = 3 + end_idx + 4; // skip past "\n---"
  let prompt_template = if prompt_start < content.len() {
    content[prompt_start..].trim().to_string()
  } else {
    String::new()
  };

  // Try parsing as MissionConfig directly (top-level keys).
  // This can fail if the YAML has legacy fields (e.g. `provider: "claude"` string
  // instead of `provider: {strategy: ...}` struct), so we fall back to legacy.
  if let Ok(config) = serde_yaml::from_str::<MissionConfig>(yaml_block) {
    // Check if parsed config differs from defaults — if it's all defaults,
    // the YAML may not contain any recognized Mission Control fields.
    let defaults = MissionConfig::default();
    let has_mission_config = config.tracker != defaults.tracker
      || config.provider.strategy != defaults.provider.strategy
      || config.provider.primary != defaults.provider.primary
      || config.provider.secondary.is_some()
      || config.provider.max_concurrent != defaults.provider.max_concurrent
      || config.provider.max_concurrent_primary.is_some()
      || !config.workspace.is_empty()
      || config.trigger.kind != defaults.trigger.kind
      || config.trigger.interval != defaults.trigger.interval
      || !config.trigger.filters.labels.is_empty()
      || !config.trigger.filters.states.is_empty()
      || config.trigger.filters.project.is_some()
      || config.trigger.filters.team.is_some()
      || config.orchestration.max_retries != defaults.orchestration.max_retries
      || config.orchestration.stall_timeout != defaults.orchestration.stall_timeout
      || config.orchestration.base_branch != defaults.orchestration.base_branch;

    if has_mission_config {
      return Ok(MissionDefinition {
        config,
        prompt_template,
      });
    }

    // MissionConfig parsed but is all defaults — check if the YAML has any
    // recognized MissionConfig top-level keys (even with default values).
    let has_recognized_keys = yaml_block.contains("tracker:")
      || yaml_block.contains("provider:")
      || yaml_block.contains("workspace:")
      || yaml_block.contains("agent:")
      || yaml_block.contains("trigger:")
      || yaml_block.contains("orchestration:");

    if has_recognized_keys {
      return Ok(MissionDefinition {
        config,
        prompt_template,
      });
    }
  }

  anyhow::bail!(
    "MISSION.md does not contain OrbitDock mission configuration. \
         Use 'Generate MISSION.md' to create one."
  )
}

/// Reconstruct MISSION.md content from config + prompt template.
///
/// Writes config keys at the top level of the YAML front matter.
pub fn serialize_mission_file(config: &MissionConfig, prompt_template: &str) -> Result<String> {
  let yaml = serde_yaml::to_string(config).context("serialize config to YAML")?;
  Ok(format!("---\n{}---\n\n{}", yaml, prompt_template))
}

/// Serialize config while preserving non-mission content from an existing MISSION.md.
///
/// - If `existing_content` has YAML front matter with non-mission keys, they are preserved.
/// - If `prompt_template` is empty, the existing body (text after front matter) is kept.
/// - If `existing_content` has no front matter, the mission config is prepended and
///   the existing content becomes the prompt body.
pub fn serialize_mission_file_preserving(
  config: &MissionConfig,
  prompt_template: &str,
  existing_content: Option<&str>,
) -> Result<String> {
  let Some(existing) = existing_content else {
    return serialize_mission_file(config, prompt_template);
  };

  let trimmed = existing.trim();
  if !trimmed.starts_with("---") {
    // No front matter — prepend mission config
    let body = if prompt_template.is_empty() {
      trimmed
    } else {
      prompt_template
    };
    return serialize_mission_file(config, body);
  }

  // Has front matter — parse existing YAML, inject/replace mission config keys
  let after_first = &trimmed[3..];
  let end_idx = after_first
    .find("\n---")
    .context("existing MISSION.md missing closing ---")?;
  let existing_yaml = &after_first[..end_idx];
  let existing_body_start = 3 + end_idx + 4;
  let existing_body = if existing_body_start < trimmed.len() {
    trimmed[existing_body_start..].trim()
  } else {
    ""
  };

  // Parse existing YAML as generic mapping, inject mission config keys
  let mut mapping: serde_yaml::Mapping = serde_yaml::from_str(existing_yaml).unwrap_or_default();
  let config_value =
    serde_yaml::to_value(config).context("serialize mission config to YAML value")?;

  // Inject each config key directly into the mapping (flat, no wrapper)
  if let serde_yaml::Value::Mapping(config_map) = config_value {
    for (k, v) in config_map {
      mapping.insert(k, v);
    }
  }

  let yaml = serde_yaml::to_string(&mapping).context("serialize merged YAML")?;

  // Body: use provided prompt_template if non-empty, else preserve existing body
  let body = if prompt_template.is_empty() {
    existing_body
  } else {
    prompt_template
  };

  Ok(format!("---\n{}---\n\n{}", yaml, body))
}

/// Flat partial-update for mission configuration — mirrors the REST request
/// but lives in the domain so it can be tested independently.
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

impl MissionConfig {
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

// ── Scaffold & migration ─────────────────────────────────────────────

/// Generate a scaffold MISSION.md for a given provider.
///
/// Returns `(file_content, parsed_config, prompt_template)`.
pub fn generate_scaffold(provider: &str, tracker: &str) -> Result<(String, MissionConfig, String)> {
  let file_content = default_mission_template(provider, tracker);
  let parsed = parse_mission_file(&file_content).context("parse scaffolded template")?;
  let prompt_template = parsed.prompt_template.clone();
  Ok((file_content, parsed.config, prompt_template))
}

/// Convert a Symphony WORKFLOW.md content string into MISSION.md format.
///
/// Returns `(file_content, parsed_config, prompt_template)`.
pub fn migrate_workflow_content(
  workflow_content: &str,
  fallback_provider: &str,
) -> Result<(String, MissionConfig, String)> {
  let config = try_parse_symphony_workflow(workflow_content)
    .context("WORKFLOW.md does not contain recognized Symphony configuration")?;

  // Extract body from the WORKFLOW.md (everything after the YAML front matter).
  let prompt_template = {
    let trimmed = workflow_content.trim();
    let body = if let Some(after_first) = trimmed.strip_prefix("---") {
      if let Some(end_idx) = after_first.find("\n---") {
        let prompt_start = end_idx + 4; // skip past "\n---"
        if prompt_start < after_first.len() {
          after_first[prompt_start..].trim()
        } else {
          ""
        }
      } else {
        ""
      }
    } else {
      ""
    };

    if body.is_empty() {
      let full_template = default_mission_template(fallback_provider, &config.tracker);
      parse_mission_file(&full_template)
        .map(|def| def.prompt_template)
        .unwrap_or_default()
    } else {
      body.to_string()
    }
  };

  let file_content =
    serialize_mission_file(&config, &prompt_template).context("serialize migrated MISSION.md")?;
  Ok((file_content, config, prompt_template))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn parse_top_level_schema() {
    let content = r#"---
tracker: linear
provider:
  strategy: priority
  primary: claude
  secondary: codex
  max_concurrent: 5
  max_concurrent_primary: 3
workspace:
  provider: daytona
  image: team/custom:v2
  retention: keep_duration
  retention_ttl: 3600
  resources:
    cpu: 4
    memory: 8Gi
  setup_commands:
    - npm install
    - cargo build
trigger:
  kind: polling
  interval: 30
  filters:
    labels: [bug, agent-ready]
    states: [Todo]
    project: PROJ
    team: Engineering
orchestration:
  max_retries: 5
  stall_timeout: 300
  base_branch: develop
---
You are working on issue {{ issue.identifier }}: {{ issue.title }}
"#;
    let def = parse_mission_file(content).unwrap();
    assert_eq!(def.config.tracker, "linear");
    assert_eq!(def.config.provider.strategy, "priority");
    assert_eq!(def.config.provider.primary, "claude");
    assert_eq!(def.config.provider.secondary.as_deref(), Some("codex"));
    assert_eq!(def.config.provider.max_concurrent, 5);
    assert_eq!(def.config.provider.max_concurrent_primary, Some(3));
    assert_eq!(def.config.workspace.provider.as_deref(), Some("daytona"));
    assert_eq!(
      def.config.workspace.image.as_deref(),
      Some("team/custom:v2")
    );
    assert_eq!(
      def.config.workspace.retention.as_deref(),
      Some("keep_duration")
    );
    assert_eq!(def.config.workspace.retention_ttl, Some(3600));
    assert_eq!(def.config.workspace.resources.cpu, Some(4));
    assert_eq!(
      def.config.workspace.resources.memory.as_deref(),
      Some("8Gi")
    );
    assert_eq!(
      def.config.workspace.setup_commands,
      vec!["npm install", "cargo build"]
    );
    assert_eq!(def.config.trigger.kind, "polling");
    assert_eq!(def.config.trigger.interval, 30);
    assert_eq!(
      def.config.trigger.filters.labels,
      vec!["bug", "agent-ready"]
    );
    assert_eq!(def.config.trigger.filters.states, vec!["Todo"]);
    assert_eq!(def.config.trigger.filters.project.as_deref(), Some("PROJ"));
    assert_eq!(
      def.config.trigger.filters.team.as_deref(),
      Some("Engineering")
    );
    assert_eq!(def.config.orchestration.max_retries, 5);
    assert_eq!(def.config.orchestration.stall_timeout, 300);
    assert_eq!(def.config.orchestration.base_branch, "develop");
    assert!(def.prompt_template.contains("{{ issue.identifier }}"));
  }

  #[test]
  fn parse_defaults_with_recognized_key() {
    let content = "---\ntracker: linear\n---\nHello";
    let def = parse_mission_file(content).unwrap();
    assert_eq!(def.config.tracker, "linear");
    assert_eq!(def.config.provider.strategy, "single");
    assert_eq!(def.config.provider.primary, "claude");
    assert_eq!(def.config.provider.max_concurrent, 3);
    assert_eq!(def.config.trigger.kind, "polling");
    assert_eq!(def.config.trigger.interval, 60);
    assert_eq!(def.config.orchestration.max_retries, 3);
    assert_eq!(def.config.orchestration.stall_timeout, 600);
    assert_eq!(def.config.orchestration.base_branch, "main");
    assert_eq!(def.prompt_template, "Hello");
  }

  #[test]
  fn parse_empty_front_matter_rejects_all_defaults() {
    let content = "---\n---\nHello";
    let result = parse_mission_file(content);
    assert!(result.is_err());
    let err = result.unwrap_err().to_string();
    assert!(err.contains("does not contain OrbitDock mission configuration"));
  }

  #[test]
  fn parse_unrelated_yaml_rejects() {
    let content = "---\nname: My Workflow\nsteps:\n  - build\n---\nHello";
    let result = parse_mission_file(content);
    assert!(result.is_err());
  }

  #[test]
  fn parse_with_trigger_filters_succeeds() {
    let content = "---\ntracker: linear\ntrigger:\n  filters:\n    project: PROJ\n---\nHello";
    let def = parse_mission_file(content).unwrap();
    assert_eq!(def.config.trigger.filters.project.as_deref(), Some("PROJ"));
    assert_eq!(def.prompt_template, "Hello");
  }

  #[test]
  fn parse_missing_front_matter() {
    let result = parse_mission_file("no front matter here");
    assert!(result.is_err());
  }

  #[test]
  fn parse_missing_closing_fence() {
    let result = parse_mission_file("---\ntracker: linear\nno closing fence");
    assert!(result.is_err());
  }

  #[test]
  fn serialize_preserving_keeps_extra_yaml_keys() {
    let existing =
      "---\nname: My Workflow\nsteps:\n  - build\n  - test\n---\n\nSome existing body content";
    let config = MissionConfig {
      provider: ProviderConfig {
        strategy: "priority".to_string(),
        ..Default::default()
      },
      workspace: WorkspaceConfig::default(),
      ..Default::default()
    };
    let result = serialize_mission_file_preserving(&config, "", Some(existing)).unwrap();
    assert!(result.contains("tracker:"));
    assert!(result.contains("provider:"));
    assert!(result.contains("name: My Workflow"));
    assert!(result.contains("Some existing body content"));
    // Should NOT have orbitdock: wrapper
    assert!(!result.contains("orbitdock:"));
  }

  #[test]
  fn serialize_preserving_replaces_body_when_template_provided() {
    let existing = "---\nname: My Workflow\n---\n\nOld body";
    let config = MissionConfig::default();
    let result =
      serialize_mission_file_preserving(&config, "New template body", Some(existing)).unwrap();
    assert!(result.contains("tracker:"));
    assert!(result.contains("name: My Workflow"));
    assert!(result.contains("New template body"));
    assert!(!result.contains("Old body"));
  }

  #[test]
  fn serialize_preserving_no_frontmatter_prepends_config() {
    let existing = "Just a regular markdown file\n\nWith some content.";
    let config = MissionConfig::default();
    let result = serialize_mission_file_preserving(&config, "", Some(existing)).unwrap();
    assert!(result.contains("tracker:"));
    assert!(result.contains("Just a regular markdown file"));
  }

  #[test]
  fn serialize_preserving_none_uses_standard() {
    let config = MissionConfig::default();
    let result = serialize_mission_file_preserving(&config, "Hello", None).unwrap();
    assert!(result.contains("tracker:"));
    assert!(result.contains("Hello"));
  }

  #[test]
  fn symphony_migration_extracts_settings() {
    let content = r#"---
tracker:
  kind: linear
  project_slug: my-project
  active_states:
    - Todo
    - "In Progress"
polling:
  interval_ms: 15000
agent:
  max_concurrent_agents: 10
codex:
  command: codex --model gpt-5
---
Some prompt body
"#;
    let config = try_parse_symphony_workflow(content).unwrap();
    assert_eq!(config.tracker, "linear");
    assert_eq!(
      config.trigger.filters.project.as_deref(),
      Some("my-project")
    );
    assert_eq!(config.trigger.filters.states, vec!["Todo", "In Progress"]);
    assert_eq!(config.trigger.interval, 15);
    assert_eq!(config.provider.max_concurrent, 10);
    assert_eq!(config.provider.primary, "codex");
  }

  #[test]
  fn symphony_migration_rejects_unrelated_yaml() {
    let content = "---\nname: Not a Symphony workflow\n---\nHello";
    assert!(try_parse_symphony_workflow(content).is_none());
  }

  #[test]
  fn serialize_roundtrip() {
    let config = MissionConfig {
      tracker: "linear".to_string(),
      provider: ProviderConfig {
        strategy: "priority".to_string(),
        primary: "claude".to_string(),
        secondary: Some("codex".to_string()),
        max_concurrent: 5,
        max_concurrent_primary: Some(3),
      },
      agent: AgentConfig::default(),
      workspace: WorkspaceConfig::default(),
      trigger: TriggerConfig {
        kind: "polling".to_string(),
        interval: 30,
        filters: TriggerFilters {
          labels: vec!["bug".to_string()],
          project: Some("PROJ".to_string()),
          ..Default::default()
        },
      },
      orchestration: OrchestrationConfig {
        base_branch: "develop".to_string(),
        ..Default::default()
      },
    };
    let template = "Fix {{ issue.identifier }}";
    let content = serialize_mission_file(&config, template).unwrap();

    // Should NOT have orbitdock: wrapper
    assert!(!content.contains("orbitdock:"));
    // Should have top-level keys
    assert!(content.contains("tracker:"));
    assert!(content.contains("provider:"));

    let parsed = parse_mission_file(&content).unwrap();
    assert_eq!(parsed.config.tracker, "linear");
    assert_eq!(parsed.config.provider.strategy, "priority");
    assert_eq!(parsed.config.provider.primary, "claude");
    assert_eq!(parsed.config.provider.secondary.as_deref(), Some("codex"));
    assert_eq!(parsed.config.provider.max_concurrent, 5);
    assert_eq!(
      parsed.config.trigger.filters.project.as_deref(),
      Some("PROJ")
    );
    assert_eq!(parsed.config.orchestration.base_branch, "develop");
    assert!(parsed.prompt_template.contains("{{ issue.identifier }}"));
  }

  // ── AgentConfig tests ────────────────────────────────────────────

  #[test]
  fn resolve_claude_agent_settings() {
    let agent = AgentConfig {
      claude: Some(ClaudeAgentConfig {
        model: Some("claude-sonnet-4-6".to_string()),
        effort: Some("high".to_string()),
        permission_mode: Some("acceptEdits".to_string()),
        allowed_tools: vec!["Bash".to_string()],
        disallowed_tools: vec![],
        allow_bypass_permissions: false,
        skills: vec!["testing-philosophy".to_string()],
      }),
      codex: None,
    };
    let resolved = agent.resolve_for_provider("claude");
    assert_eq!(resolved.model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(resolved.effort.as_deref(), Some("high"));
    assert_eq!(resolved.permission_mode.as_deref(), Some("acceptEdits"));
    assert_eq!(resolved.allowed_tools, vec!["Bash"]);
    assert_eq!(resolved.skills, vec!["testing-philosophy"]);
    // Claude resolve doesn't set codex-specific fields
    assert!(resolved.approval_policy.is_none());
    assert!(resolved.sandbox_mode.is_none());
  }

  #[test]
  fn resolve_codex_agent_settings() {
    let agent = AgentConfig {
      claude: None,
      codex: Some(CodexAgentConfig {
        model: Some("gpt-5.3-codex".to_string()),
        effort: Some("medium".to_string()),
        approval_policy: Some("on-request".to_string()),
        sandbox_mode: Some("workspace-write".to_string()),
        multi_agent: Some(true),
        collaboration_mode: Some("plan".to_string()),
        personality: Some("pragmatic".to_string()),
        service_tier: Some("fast".to_string()),
        developer_instructions: Some("Be concise".to_string()),
        skills: vec!["testing-philosophy".to_string()],
      }),
    };
    let resolved = agent.resolve_for_provider("codex");
    assert_eq!(resolved.model.as_deref(), Some("gpt-5.3-codex"));
    assert_eq!(resolved.effort.as_deref(), Some("medium"));
    assert_eq!(resolved.approval_policy.as_deref(), Some("on-request"));
    assert_eq!(resolved.sandbox_mode.as_deref(), Some("workspace-write"));
    assert_eq!(resolved.multi_agent, Some(true));
    assert_eq!(resolved.collaboration_mode.as_deref(), Some("plan"));
    assert_eq!(resolved.personality.as_deref(), Some("pragmatic"));
    assert_eq!(resolved.service_tier.as_deref(), Some("fast"));
    assert_eq!(
      resolved.developer_instructions.as_deref(),
      Some("Be concise")
    );
    assert_eq!(resolved.skills, vec!["testing-philosophy"]);
    // Codex resolve doesn't set claude-specific fields
    assert!(resolved.permission_mode.is_none());
    assert!(resolved.allowed_tools.is_empty());
  }

  #[test]
  fn resolve_empty_claude_gets_mission_safe_defaults() {
    let agent = AgentConfig::default();
    let resolved = agent.resolve_for_provider("claude");
    assert!(resolved.model.is_none());
    assert!(resolved.effort.is_none());
    // Mission-safe: acceptEdits even with no config
    assert_eq!(resolved.permission_mode.as_deref(), Some("acceptEdits"));
  }

  #[test]
  fn resolve_empty_codex_gets_mission_safe_defaults() {
    let agent = AgentConfig::default();
    let resolved = agent.resolve_for_provider("codex");
    assert!(resolved.model.is_none());
    // Mission-safe: fullAuto + workspace-write sandbox
    assert_eq!(resolved.approval_policy.as_deref(), Some("never"));
    assert_eq!(resolved.sandbox_mode.as_deref(), Some("workspace-write"));
  }

  #[test]
  fn resolve_claude_without_permission_gets_safe_default() {
    let agent = AgentConfig {
      claude: Some(ClaudeAgentConfig {
        model: Some("test-model".to_string()),
        permission_mode: None,
        ..Default::default()
      }),
      codex: None,
    };
    let resolved = agent.resolve_for_provider("claude");
    assert_eq!(resolved.model.as_deref(), Some("test-model"));
    assert_eq!(resolved.permission_mode.as_deref(), Some("acceptEdits"));
  }

  #[test]
  fn resolve_codex_without_policy_gets_safe_default() {
    let agent = AgentConfig {
      claude: None,
      codex: Some(CodexAgentConfig {
        model: Some("test-model".to_string()),
        approval_policy: None,
        sandbox_mode: None,
        ..Default::default()
      }),
    };
    let resolved = agent.resolve_for_provider("codex");
    assert_eq!(resolved.model.as_deref(), Some("test-model"));
    assert_eq!(resolved.approval_policy.as_deref(), Some("never"));
    assert_eq!(resolved.sandbox_mode.as_deref(), Some("workspace-write"));
  }

  #[test]
  fn resolve_explicit_permission_overrides_default() {
    let agent = AgentConfig {
      claude: Some(ClaudeAgentConfig {
        permission_mode: Some("bypass".to_string()),
        ..Default::default()
      }),
      codex: None,
    };
    let resolved = agent.resolve_for_provider("claude");
    assert_eq!(resolved.permission_mode.as_deref(), Some("bypass"));
  }

  #[test]
  fn resolve_unknown_provider_returns_defaults() {
    let agent = AgentConfig {
      claude: Some(ClaudeAgentConfig {
        model: Some("test".to_string()),
        ..Default::default()
      }),
      codex: None,
    };
    let resolved = agent.resolve_for_provider("gemini");
    assert!(resolved.model.is_none());
  }

  #[test]
  fn parse_mission_with_agent_config() {
    let content = r#"---
tracker: linear
provider:
  strategy: single
  primary: claude
agent:
  claude:
    model: claude-sonnet-4-6
    effort: high
    permission_mode: acceptEdits
  codex:
    model: gpt-5.3-codex
    approval_policy: on-request
trigger:
  kind: polling
---
Hello
"#;
    let def = parse_mission_file(content).unwrap();
    assert_eq!(def.config.tracker, "linear");

    let claude = def.config.agent.claude.as_ref().unwrap();
    assert_eq!(claude.model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(claude.effort.as_deref(), Some("high"));
    assert_eq!(claude.permission_mode.as_deref(), Some("acceptEdits"));

    let codex = def.config.agent.codex.as_ref().unwrap();
    assert_eq!(codex.model.as_deref(), Some("gpt-5.3-codex"));
    assert_eq!(codex.approval_policy.as_deref(), Some("on-request"));
  }

  #[test]
  fn yaml_roundtrip_with_agent_config() {
    let config = MissionConfig {
      agent: AgentConfig {
        claude: Some(ClaudeAgentConfig {
          model: Some("claude-sonnet-4-6".to_string()),
          effort: Some("high".to_string()),
          permission_mode: Some("acceptEdits".to_string()),
          allowed_tools: vec!["Read".to_string(), "Edit".to_string()],
          disallowed_tools: vec![],
          allow_bypass_permissions: false,
          skills: vec!["testing-philosophy".to_string()],
        }),
        codex: Some(CodexAgentConfig {
          model: Some("gpt-5.3-codex".to_string()),
          effort: Some("medium".to_string()),
          approval_policy: Some("never".to_string()),
          sandbox_mode: Some("danger-full-access".to_string()),
          multi_agent: Some(true),
          skills: vec!["react-best-practices".to_string()],
          ..Default::default()
        }),
      },
      ..Default::default()
    };

    let content = serialize_mission_file(&config, "Test prompt").unwrap();
    assert!(content.contains("agent:"));

    let parsed = parse_mission_file(&content).unwrap();
    let claude = parsed.config.agent.claude.as_ref().unwrap();
    assert_eq!(claude.model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(claude.effort.as_deref(), Some("high"));
    assert_eq!(claude.allowed_tools, vec!["Read", "Edit"]);
    assert_eq!(claude.skills, vec!["testing-philosophy"]);

    let codex = parsed.config.agent.codex.as_ref().unwrap();
    assert_eq!(codex.model.as_deref(), Some("gpt-5.3-codex"));
    assert_eq!(codex.approval_policy.as_deref(), Some("never"));
    assert_eq!(codex.multi_agent, Some(true));
    assert_eq!(codex.skills, vec!["react-best-practices"]);
  }

  #[test]
  fn parse_mission_without_agent_still_works() {
    let content = "---\ntracker: linear\nprovider:\n  strategy: single\n---\nHello";
    let def = parse_mission_file(content).unwrap();
    assert!(def.config.agent.claude.is_none());
    assert!(def.config.agent.codex.is_none());
  }

  #[test]
  fn parse_agent_only_key_recognized() {
    let content = "---\nagent:\n  claude:\n    model: test-model\n---\nHello";
    let def = parse_mission_file(content).unwrap();
    let claude = def.config.agent.claude.as_ref().unwrap();
    assert_eq!(claude.model.as_deref(), Some("test-model"));
  }

  #[test]
  fn workspace_provider_kind_parses_when_present() {
    let content = "---\nworkspace:\n  provider: daytona\n---\nHello";
    let def = parse_mission_file(content).unwrap();
    assert_eq!(
      def
        .config
        .workspace
        .provider_kind()
        .expect("parse provider kind"),
      Some(WorkspaceProviderKind::Daytona)
    );
  }

  // ── apply_update: tracker ─────────────────────────────────────────

  #[test]
  fn apply_update_changes_tracker() {
    let mut config = MissionConfig::default();
    assert_eq!(config.tracker, "linear");

    config.apply_update(MissionConfigUpdate {
      tracker: Some("github".to_string()),
      ..Default::default()
    });
    assert_eq!(config.tracker, "github");
  }

  #[test]
  fn apply_update_leaves_tracker_unchanged_when_none() {
    let mut config = MissionConfig {
      tracker: "github".to_string(),
      ..Default::default()
    };

    config.apply_update(MissionConfigUpdate {
      tracker: None,
      ..Default::default()
    });
    assert_eq!(config.tracker, "github");
  }
}
