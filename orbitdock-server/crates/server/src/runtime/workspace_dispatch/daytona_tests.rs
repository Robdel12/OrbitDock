use super::DaytonaLaunchPlan;
use crate::domain::mission_control::config::{AgentConfig, CodexAgentConfig, WorkspaceConfig};
use crate::runtime::workspace_dispatch::{DispatchRequest, WorkspaceIssueRef};

#[test]
fn launch_plan_contains_managed_handoff_commands() {
  let config = crate::infrastructure::daytona::DaytonaConfig {
    api_url: "https://daytona.example".into(),
    api_key: "secret".into(),
    server_public_url: "https://dock.example.com".into(),
    image: "image:latest".into(),
    target: None,
  };
  let request = DispatchRequest {
    repo_root: "/repo".into(),
    issue: WorkspaceIssueRef {
      id: "issue-1".into(),
      identifier: "ISS-1".into(),
    },
    base_branch: "main".into(),
    worktree_root_dir: None,
    mission_id: "mission-1".into(),
    tracker_kind: "linear".into(),
    tracker_api_key: Some("lin-key".into()),
    provider_str: "codex".into(),
    agent_config: AgentConfig {
      codex: Some(CodexAgentConfig {
        model: Some("gpt-5.4".into()),
        ..Default::default()
      }),
      ..Default::default()
    },
    workspace_config: WorkspaceConfig::default(),
    prompt: "Fix it".into(),
    registry: crate::support::test_support::new_test_session_registry(true),
  };
  let plan = DaytonaLaunchPlan::build(
    &config,
    &request,
    "workspace-1",
    "session-1",
    "token-1",
    "/sandbox/orbitdock-repo",
  )
  .expect("build launch plan");

  assert!(plan.sync_url.contains("dock.example.com"));
  assert!(plan.managed_request_base64.len() > 10);
  assert_eq!(
    plan.start_server_request().cwd.as_deref(),
    Some("/sandbox/orbitdock-repo")
  );
  assert!(plan
    .start_server_request()
    .command
    .contains("orbitdock start"));
  assert!(plan
    .start_server_request()
    .command
    .contains("orbitdock-managed.pid"));
  assert!(plan
    .start_session_request()
    .command
    .contains("managed-session-start"));
}

#[test]
fn parse_memory_gib_accepts_common_gib_forms() {
  assert_eq!(super::parse_memory_gib(Some("8Gi")), Some(8));
  assert_eq!(super::parse_memory_gib(Some("16GB")), Some(16));
  assert_eq!(super::parse_memory_gib(Some("4G")), Some(4));
  assert_eq!(super::parse_memory_gib(Some("2")), Some(2));
  assert_eq!(super::parse_memory_gib(Some("bad")), None);
}
