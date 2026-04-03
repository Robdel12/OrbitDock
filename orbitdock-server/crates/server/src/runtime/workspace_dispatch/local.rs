//! Local workspace provider for mission dispatch.
//!
//! This provider creates a git worktree on the host machine and starts the
//! agent session locally. It preserves OrbitDock's existing local behavior
//! behind the runtime-owned workspace dispatch boundary.

use async_trait::async_trait;
use orbitdock_protocol::Provider;
use tracing::warn;

use crate::runtime::session_creation::{
  launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_prompt::send_initial_prompt;

use super::{DispatchRequest, DispatchResult, WorkspaceError, WorkspaceProvider};

/// Derive a git branch name from an issue identifier.
///
/// Lowercases the identifier, replaces any non-alphanumeric character with a
/// hyphen, and collapses consecutive hyphens. This produces a slug that is
/// safe for filesystem paths, URLs, and module specifiers.
pub(crate) fn mission_branch_name(identifier: &str) -> String {
  let slug: String = identifier
    .to_lowercase()
    .chars()
    .map(|c| if c.is_alphanumeric() { c } else { '-' })
    .collect::<String>()
    .split('-')
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join("-");

  format!("mission/{slug}")
}

/// Pre-v0.8 naming: only replaced spaces and slashes. Returns `None` when the
/// legacy name would be identical to the current one (no cleanup needed).
fn legacy_mission_branch_name(identifier: &str) -> Option<String> {
  let legacy = format!(
    "mission/{}",
    identifier.to_lowercase().replace([' ', '/'], "-")
  );
  let current = mission_branch_name(identifier);
  if legacy != current {
    Some(legacy)
  } else {
    None
  }
}

/// Best-effort cleanup of a worktree + branch left behind by the old naming
/// scheme. Failures are logged but never block dispatch.
async fn cleanup_legacy_worktree(
  repo_root: &str,
  legacy_branch: &str,
  worktree_root: Option<&str>,
) {
  let worktree_path = if let Some(root) = worktree_root.filter(|r| !r.trim().is_empty()) {
    format!("{}/{}", root.trim().trim_end_matches('/'), legacy_branch)
  } else {
    format!(
      "{}/.orbitdock-worktrees/{}",
      repo_root.trim().trim_end_matches('/'),
      legacy_branch
    )
  };

  if let Err(err) = crate::domain::git::repo::remove_worktree(repo_root, &worktree_path, true).await
  {
    tracing::debug!(
        component = "mission_control",
        event = "dispatch.legacy_worktree_cleanup",
        legacy_branch,
        error = %err,
        "No legacy worktree to clean up (expected on fresh installs)"
    );
  }

  // Delete the stale branch regardless of whether the worktree was present
  if let Err(err) = crate::domain::git::repo::delete_branch(repo_root, legacy_branch).await {
    tracing::debug!(
        component = "mission_control",
        event = "dispatch.legacy_branch_cleanup",
        legacy_branch,
        error = %err,
        "No legacy branch to clean up"
    );
  }
}

/// Build inherited env vars for mission tools.
pub(crate) fn build_mission_tool_env(
  tracker_kind: &str,
  tracker_api_key: &str,
  issue_id: &str,
  issue_identifier: &str,
  mission_id: &str,
) -> Vec<(String, String)> {
  let (api_key_env, tracker_kind_str) = match tracker_kind {
    "github" => ("GITHUB_TOKEN", "github"),
    _ => ("LINEAR_API_KEY", "linear"),
  };

  vec![
    (api_key_env.to_string(), tracker_api_key.to_string()),
    (
      "ORBITDOCK_TRACKER_KIND".to_string(),
      tracker_kind_str.to_string(),
    ),
    ("ORBITDOCK_ISSUE_ID".to_string(), issue_id.to_string()),
    (
      "ORBITDOCK_ISSUE_IDENTIFIER".to_string(),
      issue_identifier.to_string(),
    ),
    ("ORBITDOCK_MISSION_ID".to_string(), mission_id.to_string()),
  ]
}

/// Build the `.mcp.json` content for mission tools without secrets.
pub(crate) fn build_mcp_config(orbitdock_bin: &str) -> serde_json::Value {
  serde_json::json!({
      "mcpServers": {
          "orbitdock-mission": {
              "command": orbitdock_bin,
              "args": ["mcp-mission-tools"]
          }
      }
  })
}

/// Workspace provider that creates a local git worktree and starts the
/// agent session on the host machine.
pub(crate) struct LocalWorkspaceProvider;

impl LocalWorkspaceProvider {
  pub(crate) fn new() -> Self {
    Self
  }
}

#[async_trait]
impl WorkspaceProvider for LocalWorkspaceProvider {
  async fn dispatch(&self, req: &DispatchRequest) -> Result<DispatchResult, WorkspaceError> {
    let branch_name = mission_branch_name(&req.issue.identifier);

    // Clean up worktrees created under the pre-v0.8 naming scheme (which
    // preserved `#` and other reserved chars). Without this, a retry after
    // upgrade would create a second worktree at the new sanitized path while
    // the old one stays orphaned on disk.
    if let Some(legacy) = legacy_mission_branch_name(&req.issue.identifier) {
      cleanup_legacy_worktree(&req.repo_root, &legacy, req.worktree_root_dir.as_deref()).await;
    }

    if let Err(err) = crate::domain::git::repo::fetch_origin(&req.repo_root).await {
      warn!(
          component = "mission_control",
          event = "dispatch.fetch_failed",
          error = %err,
          "git fetch origin failed — worktree will use local state"
      );
    }

    let remote_base = format!("origin/{}", req.base_branch);
    let (worktree_path, worktree_id) =
      match crate::runtime::worktree_creation::create_tracked_worktree(
        &req.registry,
        &req.repo_root,
        &branch_name,
        Some(&remote_base),
        orbitdock_protocol::WorktreeOrigin::Agent,
        req.worktree_root_dir.as_deref(),
        true,
      )
      .await
      {
        Ok(summary) => (summary.worktree_path, summary.id),
        Err(err) => {
          return Err(WorkspaceError::Failed(format!(
            "Worktree creation failed: {err}"
          )));
        }
      };

    let claude_extra_env = req
      .tracker_api_key
      .as_ref()
      .map(|api_key_value| {
        build_mission_tool_env(
          &req.tracker_kind,
          api_key_value,
          &req.issue.id,
          &req.issue.identifier,
          &req.mission_id,
        )
      })
      .unwrap_or_default();

    if !claude_extra_env.is_empty() {
      let orbitdock_bin = std::env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "orbitdock".to_string());

      let mcp_config = build_mcp_config(&orbitdock_bin);

      let mcp_path = format!("{worktree_path}/.mcp.json");
      if let Err(err) = tokio::fs::write(
        &mcp_path,
        serde_json::to_string_pretty(&mcp_config).unwrap_or_default(),
      )
      .await
      {
        warn!(
            component = "mission_control",
            event = "dispatch.mcp_write_failed",
            worktree_path = %worktree_path,
            error = %err,
            "Failed to write .mcp.json for mission tools; continuing without"
        );
      }
    }

    let provider: Provider = req.provider_str.parse().map_err(|_| {
      WorkspaceError::Failed(format!("Invalid mission provider: {}", req.provider_str))
    })?;

    let resolved = req.agent_config.resolve_for_provider(&req.provider_str);

    let cli_ref = crate::domain::instructions::orbitdock_system_instructions();
    let mission_ref = crate::domain::instructions::mission_agent_instructions();
    let orbitdock_instructions = format!("{cli_ref}\n\n{mission_ref}");
    let developer_instructions = match resolved.developer_instructions {
      Some(ref existing) => Some(format!("{existing}\n\n{orbitdock_instructions}")),
      None => Some(orbitdock_instructions),
    };

    let dynamic_tools = crate::domain::codex_tools::default_codex_dynamic_tool_specs(true);

    let session_id = orbitdock_protocol::new_session_id();
    let request = DirectSessionRequest {
      provider,
      cwd: worktree_path,
      model: resolved.model.clone(),
      approval_policy: resolved.approval_policy,
      sandbox_mode: resolved.sandbox_mode,
      permission_mode: resolved.permission_mode,
      allowed_tools: resolved.allowed_tools,
      disallowed_tools: resolved.disallowed_tools,
      effort: resolved.effort.clone(),
      collaboration_mode: resolved.collaboration_mode,
      multi_agent: resolved.multi_agent,
      personality: resolved.personality,
      service_tier: resolved.service_tier,
      developer_instructions,
      mission_id: Some(req.mission_id.clone()),
      issue_identifier: Some(req.issue.identifier.clone()),
      worktree_id: Some(worktree_id),
      dynamic_tools,
      allow_bypass_permissions: resolved.allow_bypass_permissions,
      claude_extra_env,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides: None,
    };

    let persisted =
      prepare_persist_direct_session(&req.registry, session_id.clone(), request).await;
    launch_prepared_direct_session(&req.registry, persisted)
      .await
      .map_err(|e| WorkspaceError::Failed(format!("Failed to launch session: {e}")))?;

    send_initial_prompt(
      &req.registry,
      &session_id,
      provider,
      &req.prompt,
      resolved.model,
      resolved.effort,
      &resolved.skills,
    )
    .await;

    Ok(DispatchResult::Running {
      session_id,
      workspace_id: None,
    })
  }
}

#[cfg(test)]
mod tests {
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
  fn legacy_name_returns_some_when_identifier_has_reserved_chars() {
    // GitHub-style identifier — old naming preserved `#`
    assert_eq!(
      legacy_mission_branch_name("owner/repo#123"),
      Some("mission/owner-repo#123".to_string())
    );
  }

  #[test]
  fn legacy_name_returns_none_when_names_match() {
    // Linear-style identifier — no reserved chars, old == new
    assert_eq!(legacy_mission_branch_name("PROJ-42"), None);
  }

  #[test]
  fn legacy_name_returns_none_for_plain_text() {
    assert_eq!(legacy_mission_branch_name("already-hyphenated"), None);
  }

  #[test]
  fn workspace_error_display() {
    let err = WorkspaceError::Failed("git worktree add failed".to_string());
    assert_eq!(err.to_string(), "git worktree add failed");
  }
}
