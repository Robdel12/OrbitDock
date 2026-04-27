use super::*;

#[test]
fn template_includes_provider_and_core_structure() {
  let tmpl = default_mission_template("codex", "linear");
  assert!(tmpl.contains("primary: codex"));
  assert!(!tmpl.contains("PROVIDER_PLACEHOLDER"));
  assert!(tmpl.starts_with("---\n"));
  assert!(tmpl.matches("---").count() >= 2);
  assert!(!tmpl.contains("orbitdock:"));
  assert!(tmpl.contains("provider:"));
  assert!(tmpl.contains("strategy: single"));
  assert!(tmpl.contains("trigger:"));
  assert!(tmpl.contains("orchestration:"));
  assert!(tmpl.contains("{{ issue.identifier }}"));
  assert!(tmpl.contains("{{ issue.title }}"));
  assert!(tmpl.contains("{% if attempt > 1 %}"));
  assert!(tmpl.contains("## Workflow"));
  assert!(tmpl.contains("## Rules"));
  assert!(tmpl.contains("workpad"));
}

#[test]
fn template_parses_as_valid_mission_file() {
  let tmpl = default_mission_template("claude", "linear");
  let def = crate::domain::mission_control::config::parse_mission_file(&tmpl).unwrap();
  assert_eq!(def.config.tracker, "linear");
  assert_eq!(def.config.provider.strategy, "single");
  assert_eq!(def.config.provider.primary, "claude");
  assert_eq!(def.config.provider.max_concurrent, 3);
  assert_eq!(def.config.trigger.kind, "polling");
  assert_eq!(def.config.trigger.interval, 60);
  assert_eq!(def.config.orchestration.max_retries, 3);
  assert_eq!(def.config.orchestration.stall_timeout, 600);
  assert_eq!(def.config.orchestration.base_branch, "main");
  assert_eq!(def.config.orchestration.state_on_dispatch, "In Progress");
  assert_eq!(def.config.orchestration.state_on_complete, "In Review");
}

#[test]
fn template_documents_authoring_knobs() {
  let tmpl = default_mission_template("claude", "linear");
  assert!(tmpl.contains("single"));
  assert!(tmpl.contains("priority"));
  assert!(tmpl.contains("round_robin"));
  assert!(tmpl.contains("secondary:"));
  assert!(tmpl.contains("max_concurrent_primary:"));
  assert!(tmpl.contains("permission_mode:"));
  assert!(tmpl.contains("plan | default | auto-edit | auto | bypass"));
  assert!(tmpl.contains("allowed_tools:"));
  assert!(tmpl.contains("disallowed_tools:"));
  assert!(tmpl.contains("effort:"));
  assert!(tmpl.contains("low | medium | high"));
  assert!(tmpl.contains("skills:"));
  assert!(tmpl.contains("approval_policy:"));
  assert!(tmpl.contains("untrusted | on-failure | on-request | never"));
  assert!(tmpl.contains("sandbox_mode:"));
  assert!(tmpl.contains("workspace-write | danger-full-access"));
  assert!(tmpl.contains("collaboration_mode:"));
  assert!(tmpl.contains("multi_agent:"));
  assert!(tmpl.contains("service_tier:"));
  assert!(tmpl.contains("developer_instructions:"));
  assert!(tmpl.contains("polling | manual_only"));
  assert!(tmpl.contains("labels:"));
  assert!(tmpl.contains("states:"));
  assert!(tmpl.contains("project:"));
  assert!(tmpl.contains("team:"));
  assert!(tmpl.contains("worktree_root_dir:"));
  assert!(tmpl.contains("stall_timeout:"));
  assert!(tmpl.contains("state_on_dispatch:"));
  assert!(tmpl.contains("state_on_complete:"));
}

#[test]
fn template_github_tracker_uses_github_hints() {
  let tmpl = default_mission_template("claude", "github");
  assert!(tmpl.contains("tracker: github"));
  assert!(tmpl.contains("GitHub issue"));
  assert!(tmpl.contains("GitHub project key"));
  assert!(tmpl.contains("GitHub team key"));
  assert!(tmpl.contains("[Ready, Backlog]"));
}

#[test]
fn template_linear_tracker_uses_linear_hints() {
  let tmpl = default_mission_template("claude", "linear");
  assert!(tmpl.contains("tracker: linear"));
  assert!(tmpl.contains("Linear issue"));
  assert!(tmpl.contains("Linear project key"));
  assert!(tmpl.contains("Linear team key"));
}

#[test]
fn template_github_parses_as_valid_mission_file() {
  let tmpl = default_mission_template("codex", "github");
  let def = crate::domain::mission_control::config::parse_mission_file(&tmpl).unwrap();
  assert_eq!(def.config.tracker, "github");
  assert_eq!(def.config.provider.primary, "codex");
  assert_eq!(def.config.orchestration.state_on_dispatch, "In progress");
  assert_eq!(def.config.orchestration.state_on_complete, "In review");
}
