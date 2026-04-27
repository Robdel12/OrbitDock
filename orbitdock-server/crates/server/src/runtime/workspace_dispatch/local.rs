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
      sandbox_policy_details: None,
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
#[path = "local_tests.rs"]
mod local_tests;
