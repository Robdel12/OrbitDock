use anyhow::{Context, Result};
use serde::Deserialize;

use super::{
  parse_mission_file, serialize_mission_file, AgentConfig, MissionConfig, ProviderConfig,
  TriggerConfig, TriggerFilters, WorkspaceConfig,
};
use crate::domain::mission_control::template::default_mission_template;

#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyTracker {
  #[serde(default)]
  kind: String,
  #[serde(default)]
  project_slug: Option<String>,
  #[serde(default)]
  active_states: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyPolling {
  #[serde(default)]
  interval_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyAgent {
  #[serde(default)]
  max_concurrent_agents: u32,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct SymphonyCodex {
  #[serde(default)]
  command: Option<String>,
}

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
pub fn try_parse_symphony_workflow(content: &str) -> Option<MissionConfig> {
  let content = content.trim();
  if !content.starts_with("---") {
    return None;
  }

  let after_first = &content[3..];
  let end_idx = after_first.find("\n---")?;
  let yaml_block = &after_first[..end_idx];

  if !yaml_block.contains("tracker:")
    && !yaml_block.contains("polling:")
    && !yaml_block.contains("agent:")
    && !yaml_block.contains("codex:")
  {
    return None;
  }

  let symphony: SymphonyWorkflow = serde_yaml::from_str(yaml_block).ok()?;
  let has_config = !symphony.tracker.kind.is_empty()
    || symphony.tracker.project_slug.is_some()
    || !symphony.tracker.active_states.is_empty()
    || symphony.polling.interval_ms > 0
    || symphony.agent.max_concurrent_agents > 0;

  if !has_config {
    return None;
  }

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
    orchestration: Default::default(),
  })
}

/// Convert a Symphony WORKFLOW.md content string into MISSION.md format.
pub fn migrate_workflow_content(
  workflow_content: &str,
  fallback_provider: &str,
) -> Result<(String, MissionConfig, String)> {
  let config = try_parse_symphony_workflow(workflow_content)
    .context("WORKFLOW.md does not contain recognized Symphony configuration")?;

  let prompt_template = {
    let trimmed = workflow_content.trim();
    let body = if let Some(after_first) = trimmed.strip_prefix("---") {
      if let Some(end_idx) = after_first.find("\n---") {
        let prompt_start = end_idx + 4;
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
        .map(|definition| definition.prompt_template)
        .unwrap_or_default()
    } else {
      body.to_string()
    }
  };

  let file_content =
    serialize_mission_file(&config, &prompt_template).context("serialize migrated MISSION.md")?;
  Ok((file_content, config, prompt_template))
}
