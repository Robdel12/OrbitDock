#[path = "config_model.rs"]
mod config_model;
mod parser;
mod scaffold;
mod serializer;

pub use self::config_model::*;
pub use self::parser::parse_mission_file;
pub use self::scaffold::generate_scaffold;
pub use self::serializer::serialize_mission_file_preserving;

// ── Public API ───────────────────────────────────────────────────────

/// Parsed MISSION.md: config + prompt template.
#[derive(Debug, Clone)]
pub struct MissionDefinition {
  pub config: MissionConfig,
  pub prompt_template: String,
}

#[cfg(test)]
mod tests {
  use super::serializer::serialize_mission_file;
  use super::*;
  use orbitdock_protocol::WorkspaceProviderKind;

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
        model_provider: None,
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
