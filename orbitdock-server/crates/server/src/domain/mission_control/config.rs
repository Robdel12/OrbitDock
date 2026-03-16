use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

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

// ── Config types ─────────────────────────────────────────────────────

/// Parsed mission configuration from MISSION.md YAML front matter.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MissionConfig {
    #[serde(default = "default_tracker")]
    pub tracker: String,
    #[serde(default)]
    pub provider: ProviderConfig,
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
}

impl Default for OrchestrationConfig {
    fn default() -> Self {
        Self {
            max_retries: default_max_retries(),
            stall_timeout: default_stall_timeout(),
            base_branch: default_base_branch(),
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
        let existing = "---\nname: My Workflow\nsteps:\n  - build\n  - test\n---\n\nSome existing body content";
        let config = MissionConfig {
            provider: ProviderConfig {
                strategy: "priority".to_string(),
                ..Default::default()
            },
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
            serialize_mission_file_preserving(&config, "New template body", Some(existing))
                .unwrap();
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
}
