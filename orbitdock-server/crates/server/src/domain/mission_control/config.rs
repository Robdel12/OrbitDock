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

// ── New nested config types ──────────────────────────────────────────

/// Top-level YAML wrapper: everything lives under `orbitdock:` key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowYaml {
    #[serde(default)]
    pub orbitdock: MissionConfig,
}

/// Parsed mission configuration from WORKFLOW.md YAML front matter.
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

// ── Backward-compat: legacy flat config ──────────────────────────────

/// Legacy flat config from the original WORKFLOW.md schema.
/// Used for backward-compatible parsing only.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct LegacyMissionConfig {
    tracker: String,
    provider: String,
    project_key: Option<String>,
    team_key: Option<String>,
    #[serde(default)]
    label_filter: Vec<String>,
    #[serde(default)]
    state_filter: Vec<String>,
    max_concurrent: u32,
    poll_interval_secs: u64,
    max_retries: u32,
    #[allow(dead_code)]
    max_backoff_ms: u64,
    stall_timeout_secs: u64,
    base_branch: String,
}

impl Default for LegacyMissionConfig {
    fn default() -> Self {
        Self {
            tracker: "linear".to_string(),
            provider: "claude".to_string(),
            project_key: None,
            team_key: None,
            label_filter: Vec::new(),
            state_filter: Vec::new(),
            max_concurrent: 3,
            poll_interval_secs: 60,
            max_retries: 3,
            max_backoff_ms: 300_000,
            stall_timeout_secs: 600,
            base_branch: "main".to_string(),
        }
    }
}

impl From<LegacyMissionConfig> for MissionConfig {
    fn from(legacy: LegacyMissionConfig) -> Self {
        Self {
            tracker: legacy.tracker,
            provider: ProviderConfig {
                strategy: "single".to_string(),
                primary: legacy.provider,
                secondary: None,
                max_concurrent: legacy.max_concurrent,
                max_concurrent_primary: None,
            },
            trigger: TriggerConfig {
                kind: "polling".to_string(),
                interval: legacy.poll_interval_secs,
                filters: TriggerFilters {
                    labels: legacy.label_filter,
                    states: legacy.state_filter,
                    project: legacy.project_key,
                    team: legacy.team_key,
                },
            },
            orchestration: OrchestrationConfig {
                max_retries: legacy.max_retries,
                stall_timeout: legacy.stall_timeout_secs,
                base_branch: legacy.base_branch,
            },
        }
    }
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

/// Parsed WORKFLOW.md: config + prompt template.
#[derive(Debug, Clone)]
pub struct WorkflowDefinition {
    pub config: MissionConfig,
    pub prompt_template: String,
}

/// Parse a WORKFLOW.md file: YAML front matter between `---` fences, rest is Liquid template.
///
/// Supports both new nested `orbitdock:` schema and legacy flat schema for backward compat.
pub fn parse_workflow(content: &str) -> Result<WorkflowDefinition> {
    let content = content.trim();
    if !content.starts_with("---") {
        anyhow::bail!("WORKFLOW.md must start with YAML front matter (---)");
    }

    let after_first = &content[3..];
    let end_idx = after_first
        .find("\n---")
        .context("WORKFLOW.md missing closing --- for YAML front matter")?;

    let yaml_block = &after_first[..end_idx];
    let prompt_start = 3 + end_idx + 4; // skip past "\n---"
    let prompt_template = if prompt_start < content.len() {
        content[prompt_start..].trim().to_string()
    } else {
        String::new()
    };

    // Try new nested schema first (has `orbitdock:` key)
    let config = if yaml_block.contains("orbitdock:") {
        let wrapper: WorkflowYaml =
            serde_yaml::from_str(yaml_block).context("failed to parse WORKFLOW.md nested YAML")?;
        wrapper.orbitdock
    } else {
        // Legacy flat schema → convert
        let legacy: LegacyMissionConfig =
            serde_yaml::from_str(yaml_block).context("failed to parse WORKFLOW.md YAML config")?;

        // Reject configs that are entirely defaults (no recognized Mission Control fields)
        let defaults = LegacyMissionConfig::default();
        let has_any_config = legacy.tracker != defaults.tracker
            || legacy.provider != defaults.provider
            || legacy.project_key.is_some()
            || legacy.team_key.is_some()
            || !legacy.label_filter.is_empty()
            || !legacy.state_filter.is_empty()
            || legacy.max_concurrent != defaults.max_concurrent
            || legacy.poll_interval_secs != defaults.poll_interval_secs
            || legacy.base_branch != defaults.base_branch;

        if !has_any_config {
            anyhow::bail!(
                "WORKFLOW.md does not contain OrbitDock mission configuration. \
                 Add an `orbitdock:` section or use 'Generate WORKFLOW.md' to create one."
            );
        }

        MissionConfig::from(legacy)
    };

    Ok(WorkflowDefinition {
        config,
        prompt_template,
    })
}

/// Reconstruct WORKFLOW.md content from config + prompt template.
///
/// Always writes the new nested `orbitdock:` format.
pub fn serialize_workflow(config: &MissionConfig, prompt_template: &str) -> Result<String> {
    let wrapper = WorkflowYaml {
        orbitdock: config.clone(),
    };
    let yaml = serde_yaml::to_string(&wrapper).context("serialize config to YAML")?;
    Ok(format!("---\n{}---\n\n{}", yaml, prompt_template))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_new_nested_schema() {
        let content = r#"---
orbitdock:
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
        let def = parse_workflow(content).unwrap();
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
    fn parse_legacy_flat_schema() {
        let content = r#"---
tracker: linear
provider: claude
project_key: PROJ
max_concurrent: 5
poll_interval_secs: 30
label_filter:
  - bug
state_filter:
  - Todo
---
You are working on issue {{ issue.identifier }}: {{ issue.title }}
"#;
        let def = parse_workflow(content).unwrap();
        assert_eq!(def.config.tracker, "linear");
        assert_eq!(def.config.provider.strategy, "single");
        assert_eq!(def.config.provider.primary, "claude");
        assert_eq!(def.config.provider.max_concurrent, 5);
        assert_eq!(def.config.trigger.interval, 30);
        assert_eq!(def.config.trigger.filters.labels, vec!["bug"]);
        assert_eq!(def.config.trigger.filters.states, vec!["Todo"]);
        assert_eq!(def.config.trigger.filters.project.as_deref(), Some("PROJ"));
        assert!(def.prompt_template.contains("{{ issue.identifier }}"));
    }

    #[test]
    fn parse_defaults() {
        let content = "---\norbitdock: {}\n---\nHello";
        let def = parse_workflow(content).unwrap();
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
    fn parse_empty_front_matter_legacy_rejects_all_defaults() {
        let content = "---\n---\nHello";
        let result = parse_workflow(content);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("does not contain OrbitDock mission configuration"));
    }

    #[test]
    fn parse_unrelated_yaml_rejects() {
        let content = "---\nname: My Workflow\nsteps:\n  - build\n---\nHello";
        let result = parse_workflow(content);
        assert!(result.is_err());
    }

    #[test]
    fn parse_legacy_with_recognized_field_succeeds() {
        let content = "---\ntracker: linear\nproject_key: PROJ\n---\nHello";
        let def = parse_workflow(content).unwrap();
        assert_eq!(def.config.trigger.filters.project.as_deref(), Some("PROJ"));
        assert_eq!(def.prompt_template, "Hello");
    }

    #[test]
    fn parse_missing_front_matter() {
        let result = parse_workflow("no front matter here");
        assert!(result.is_err());
    }

    #[test]
    fn parse_missing_closing_fence() {
        let result = parse_workflow("---\ntracker: linear\nno closing fence");
        assert!(result.is_err());
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
        let content = serialize_workflow(&config, template).unwrap();

        // Should use nested format
        assert!(content.contains("orbitdock:"));

        let parsed = parse_workflow(&content).unwrap();
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
