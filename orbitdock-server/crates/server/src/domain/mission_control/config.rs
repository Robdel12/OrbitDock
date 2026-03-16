use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::tracker::TrackerConfig;

/// Parsed mission configuration from WORKFLOW.md YAML front matter.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MissionConfig {
    /// Issue tracker type ("linear", "github").
    pub tracker: String,
    /// Provider to use for agent sessions ("claude", "codex").
    pub provider: String,
    /// Linear/GitHub project key for issue filtering.
    pub project_key: Option<String>,
    /// Linear team key.
    pub team_key: Option<String>,
    /// Only pick up issues with these labels.
    #[serde(default)]
    pub label_filter: Vec<String>,
    /// Only pick up issues in these states.
    #[serde(default)]
    pub state_filter: Vec<String>,
    /// Maximum concurrent running sessions.
    pub max_concurrent: u32,
    /// Polling interval in seconds.
    pub poll_interval_secs: u64,
    /// Maximum retry attempts per issue.
    pub max_retries: u32,
    /// Maximum backoff in milliseconds for retries.
    pub max_backoff_ms: u64,
    /// Stall timeout in seconds — kill + retry if no activity.
    pub stall_timeout_secs: u64,
    /// Base branch for worktrees (default: main).
    pub base_branch: String,
}

impl Default for MissionConfig {
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

impl MissionConfig {
    pub fn to_tracker_config(&self) -> TrackerConfig {
        TrackerConfig {
            project_key: self.project_key.clone(),
            team_key: self.team_key.clone(),
            label_filter: self.label_filter.clone(),
            state_filter: self.state_filter.clone(),
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

    let config: MissionConfig =
        serde_yaml::from_str(yaml_block).context("failed to parse WORKFLOW.md YAML config")?;

    Ok(WorkflowDefinition {
        config,
        prompt_template,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_basic_workflow() {
        let content = r#"---
tracker: linear
provider: claude
project_key: PROJ
max_concurrent: 5
---
You are working on issue {{ issue.identifier }}: {{ issue.title }}

{{ issue.description }}
"#;
        let def = parse_workflow(content).unwrap();
        assert_eq!(def.config.tracker, "linear");
        assert_eq!(def.config.provider, "claude");
        assert_eq!(def.config.project_key.as_deref(), Some("PROJ"));
        assert_eq!(def.config.max_concurrent, 5);
        assert!(def.prompt_template.contains("{{ issue.identifier }}"));
    }

    #[test]
    fn parse_defaults() {
        let content = "---\n---\nHello";
        let def = parse_workflow(content).unwrap();
        assert_eq!(def.config.tracker, "linear");
        assert_eq!(def.config.max_concurrent, 3);
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
}
