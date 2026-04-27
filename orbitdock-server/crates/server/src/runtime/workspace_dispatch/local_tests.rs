use super::*;

#[test]
fn branch_name_basic_identifier() {
  assert_eq!(mission_branch_name("PROJ-42"), "mission/proj-42");
}

#[test]
fn branch_name_lowercases() {
  assert_eq!(mission_branch_name("ISSUE-123"), "mission/issue-123");
}

#[test]
fn branch_name_replaces_spaces() {
  assert_eq!(
    mission_branch_name("My Issue Name"),
    "mission/my-issue-name"
  );
}

#[test]
fn branch_name_replaces_slashes_and_hash() {
  assert_eq!(
    mission_branch_name("owner/repo#123"),
    "mission/owner-repo-123"
  );
}

#[test]
fn branch_name_sanitizes_reserved_url_characters() {
  assert_eq!(
    mission_branch_name("org/repo#42?q=1&x=2"),
    "mission/org-repo-42-q-1-x-2"
  );
}

#[test]
fn branch_name_collapses_consecutive_special_chars() {
  assert_eq!(
    mission_branch_name("foo---bar!!!baz"),
    "mission/foo-bar-baz"
  );
}

#[test]
fn branch_name_replaces_mixed_separators() {
  assert_eq!(
    mission_branch_name("Org/Team Project 99"),
    "mission/org-team-project-99"
  );
}

#[test]
fn branch_name_preserves_hyphens() {
  assert_eq!(
    mission_branch_name("already-hyphenated"),
    "mission/already-hyphenated"
  );
}

#[test]
fn mcp_config_linear_tracker() {
  let config = build_mcp_config("/usr/bin/orbitdock");

  let server = &config["mcpServers"]["orbitdock-mission"];
  assert_eq!(server["command"], "/usr/bin/orbitdock");
  assert_eq!(server["args"][0], "mcp-mission-tools");
  assert!(server.get("env").is_none());
}

#[test]
fn mission_tool_env_linear_tracker() {
  let env = build_mission_tool_env(
    "linear",
    "lin_api_test123",
    "issue-1",
    "PROJ-42",
    "mission-1",
  );

  let env_map: std::collections::HashMap<_, _> = env.into_iter().collect();
  assert_eq!(
    env_map.get("LINEAR_API_KEY").map(String::as_str),
    Some("lin_api_test123")
  );
  assert_eq!(
    env_map.get("ORBITDOCK_TRACKER_KIND").map(String::as_str),
    Some("linear")
  );
  assert_eq!(
    env_map.get("ORBITDOCK_ISSUE_ID").map(String::as_str),
    Some("issue-1")
  );
  assert_eq!(
    env_map
      .get("ORBITDOCK_ISSUE_IDENTIFIER")
      .map(String::as_str),
    Some("PROJ-42")
  );
  assert_eq!(
    env_map.get("ORBITDOCK_MISSION_ID").map(String::as_str),
    Some("mission-1")
  );
  assert!(!env_map.contains_key("GITHUB_TOKEN"));
}

#[test]
fn mission_tool_env_github_tracker() {
  let env = build_mission_tool_env(
    "github",
    "ghp_test456",
    "issue-2",
    "owner/repo#7",
    "mission-2",
  );

  let env_map: std::collections::HashMap<_, _> = env.into_iter().collect();
  assert_eq!(
    env_map.get("GITHUB_TOKEN").map(String::as_str),
    Some("ghp_test456")
  );
  assert_eq!(
    env_map.get("ORBITDOCK_TRACKER_KIND").map(String::as_str),
    Some("github")
  );
  assert!(!env_map.contains_key("LINEAR_API_KEY"));
}

#[test]
fn mission_tool_env_unknown_tracker_defaults_to_linear() {
  let env = build_mission_tool_env("jira", "jira_key", "issue-3", "JIRA-99", "mission-3");

  let env_map: std::collections::HashMap<_, _> = env.into_iter().collect();
  assert_eq!(
    env_map.get("LINEAR_API_KEY").map(String::as_str),
    Some("jira_key")
  );
  assert_eq!(
    env_map.get("ORBITDOCK_TRACKER_KIND").map(String::as_str),
    Some("linear")
  );
}

#[test]
fn workspace_error_display() {
  let err = WorkspaceError::Failed("git worktree add failed".to_string());
  assert_eq!(err.to_string(), "git worktree add failed");
}
