use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use base64::Engine;
use serde_json::json;

use crate::domain::git::repo::resolve_origin_url;
use crate::infrastructure::auth_tokens;
use crate::infrastructure::daytona::{
  DaytonaClient, DaytonaConfig, DaytonaExecRequest, DaytonaWorkspaceCreateRequest,
};
use crate::infrastructure::persistence::{
  insert_workspace_record, load_workspace_record, update_workspace_record, WorkspaceRecord,
  WorkspaceRecordInsert, WorkspaceRecordUpdate,
};
use crate::runtime::session_registry::SessionRegistry;

use super::{
  local::mission_branch_name, DispatchRequest, DispatchResult, WorkspaceError, WorkspaceProvider,
};

pub(crate) struct DaytonaWorkspaceProvider {
  client: DaytonaClient,
}

impl DaytonaWorkspaceProvider {
  pub(crate) fn new() -> Result<Self> {
    let config = DaytonaConfig::load()?;
    Ok(Self {
      client: DaytonaClient::new(config)?,
    })
  }

  async fn exec_required_success(
    &self,
    workspace_external_id: &str,
    request: DaytonaExecRequest,
    context: &str,
  ) -> Result<()> {
    let result = self
      .client
      .exec_in_workspace(workspace_external_id, &request)
      .await?;
    if result.exit_code == 0 {
      return Ok(());
    }

    let stderr = result.stderr.trim();
    let stdout = result.stdout.trim();
    let detail = if !stderr.is_empty() {
      stderr
    } else if !stdout.is_empty() {
      stdout
    } else {
      "no output"
    };

    Err(anyhow::anyhow!(
      "{context} exited with code {}: {detail}",
      result.exit_code
    ))
  }
}

#[async_trait]
impl WorkspaceProvider for DaytonaWorkspaceProvider {
  async fn dispatch(&self, req: &DispatchRequest) -> Result<DispatchResult, WorkspaceError> {
    let repo_url = resolve_origin_url(&req.repo_root)
      .await
      .ok_or_else(|| WorkspaceError::Failed("Remote providers require remote.origin.url".into()))?;

    let mission_issue_row_id = resolve_mission_issue_row_id(
      req.registry.clone(),
      req.mission_id.clone(),
      req.issue.id.clone(),
    )
    .await
    .map_err(|error| {
      WorkspaceError::Failed(format!("Resolve mission issue row failed: {error}"))
    })?;

    let workspace_id = orbitdock_protocol::new_id();
    let session_id = orbitdock_protocol::new_session_id();
    let sync_token = auth_tokens::issue_token(Some("daytona-workspace"))
      .map_err(|error| WorkspaceError::Failed(format!("Issue sync token failed: {error}")))?;
    let branch_name = mission_branch_name(&req.issue.identifier);

    insert_workspace(
      req.registry.clone(),
      WorkspaceRecordInsert {
        id: &workspace_id,
        mission_issue_id: &mission_issue_row_id,
        session_id: Some(&session_id),
        provider: orbitdock_protocol::WorkspaceProviderKind::Daytona,
        repo_url: &repo_url,
        branch: &branch_name,
        sync_token: &sync_token.id,
      },
    )
    .await
    .map_err(|error| WorkspaceError::Failed(format!("Insert workspace failed: {error}")))?;

    let workspace = match self
      .client
      .create_workspace(&DaytonaWorkspaceCreateRequest {
        name: format!("orbitdock-{}", req.issue.identifier.to_lowercase()),
        repository_url: repo_url.clone(),
        branch: branch_name.clone(),
        image: req
          .workspace_config
          .image
          .clone()
          .unwrap_or_else(|| self.client.config().image.clone()),
      })
      .await
    {
      Ok(workspace) => workspace,
      Err(error) => {
        let _ = mark_workspace_failed(req.registry.clone(), workspace_id.clone()).await;
        return Err(WorkspaceError::Failed(format!(
          "Create Daytona workspace failed: {error}"
        )));
      }
    };

    let launch_plan = DaytonaLaunchPlan::build(
      self.client.config(),
      req,
      &workspace_id,
      &session_id,
      &sync_token.token,
    )
    .map_err(|error| {
      WorkspaceError::Failed(format!("Build Daytona launch plan failed: {error}"))
    })?;

    if let Err(error) = self
      .exec_required_success(
        &workspace.id,
        launch_plan.start_server_request(),
        "start remote OrbitDock",
      )
      .await
    {
      let _ = self.client.delete_workspace(&workspace.id).await;
      let _ = mark_workspace_failed(req.registry.clone(), workspace_id.clone()).await;
      return Err(WorkspaceError::Failed(format!(
        "Start remote OrbitDock failed: {error}"
      )));
    }

    if let Err(error) = self
      .exec_required_success(
        &workspace.id,
        launch_plan.wait_for_server_request(),
        "wait for managed OrbitDock health",
      )
      .await
    {
      let _ = self.client.delete_workspace(&workspace.id).await;
      let _ = mark_workspace_failed(req.registry.clone(), workspace_id.clone()).await;
      return Err(WorkspaceError::Failed(format!(
        "Managed OrbitDock did not become healthy: {error}"
      )));
    }

    if let Err(error) = self
      .exec_required_success(
        &workspace.id,
        launch_plan.start_session_request(),
        "start managed session",
      )
      .await
    {
      let _ = self.client.delete_workspace(&workspace.id).await;
      let _ = mark_workspace_failed(req.registry.clone(), workspace_id.clone()).await;
      return Err(WorkspaceError::Failed(format!(
        "Managed session start failed: {error}"
      )));
    }

    update_workspace(
      req.registry.clone(),
      WorkspaceRecordUpdate {
        id: &workspace_id,
        external_id: Some(&workspace.id),
        status: "running",
        connection_info: Some(&json!({ "daytona_workspace_name": workspace.name })),
        ready: true,
        destroyed: false,
      },
    )
    .await
    .map_err(|error| WorkspaceError::Failed(format!("Update workspace failed: {error}")))?;

    Ok(DispatchResult::Provisioning { workspace_id })
  }
}

#[derive(Debug)]
struct DaytonaLaunchPlan {
  managed_request_base64: String,
  sync_url: String,
  sync_token: String,
  workspace_id: String,
}

impl DaytonaLaunchPlan {
  fn build(
    config: &DaytonaConfig,
    req: &DispatchRequest,
    workspace_id: &str,
    session_id: &str,
    sync_token: &str,
  ) -> Result<Self> {
    let resolved = req.agent_config.resolve_for_provider(&req.provider_str);
    let cli_ref = crate::domain::instructions::orbitdock_system_instructions();
    let mission_ref = crate::domain::instructions::mission_agent_instructions();
    let orbitdock_instructions = format!("{cli_ref}\n\n{mission_ref}");
    let developer_instructions = match resolved.developer_instructions {
      Some(ref existing) => Some(format!("{existing}\n\n{orbitdock_instructions}")),
      None => Some(orbitdock_instructions),
    };

    let request = json!({
      "session_id": session_id,
      "provider": req.provider_str,
      "cwd": ".",
      "model": resolved.model,
      "approval_policy": resolved.approval_policy,
      "sandbox_mode": resolved.sandbox_mode,
      "permission_mode": resolved.permission_mode,
      "allowed_tools": resolved.allowed_tools,
      "disallowed_tools": resolved.disallowed_tools,
      "effort": resolved.effort,
      "collaboration_mode": resolved.collaboration_mode,
      "multi_agent": resolved.multi_agent,
      "personality": resolved.personality,
      "service_tier": resolved.service_tier,
      "developer_instructions": developer_instructions,
      "allow_bypass_permissions": resolved.allow_bypass_permissions,
      "mission_id": req.mission_id,
      "issue_id": req.issue.id,
      "issue_identifier": req.issue.identifier,
      "workspace_id": workspace_id,
      "initial_prompt": req.prompt,
      "skills": resolved.skills,
      "tracker_kind": req.tracker_kind,
      "tracker_api_key": req.tracker_api_key,
    });
    let managed_request_base64 = base64::engine::general_purpose::STANDARD
      .encode(serde_json::to_vec(&request).context("serialize managed session request")?);

    Ok(Self {
      managed_request_base64,
      sync_url: config.server_public_url.clone(),
      sync_token: sync_token.to_string(),
      workspace_id: workspace_id.to_string(),
    })
  }

  fn start_server_request(&self) -> DaytonaExecRequest {
    let mut env = HashMap::new();
    env.insert("ORBITDOCK_SYNC_URL".into(), self.sync_url.clone());
    env.insert("ORBITDOCK_SYNC_TOKEN".into(), self.sync_token.clone());
    env.insert("ORBITDOCK_WORKSPACE_ID".into(), self.workspace_id.clone());

    DaytonaExecRequest {
      command: vec![
        "sh".into(),
        "-lc".into(),
        "nohup orbitdock start --bind 127.0.0.1:4000 --allow-insecure-no-auth --managed --workspace-id \"$ORBITDOCK_WORKSPACE_ID\" --sync-url \"$ORBITDOCK_SYNC_URL\" --sync-token \"$ORBITDOCK_SYNC_TOKEN\" >/tmp/orbitdock-managed.log 2>&1 & echo $! >/tmp/orbitdock-managed.pid".into(),
      ],
      env,
    }
  }

  fn wait_for_server_request(&self) -> DaytonaExecRequest {
    DaytonaExecRequest {
      command: vec![
        "sh".into(),
        "-lc".into(),
        "for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:4000/health >/dev/null && exit 0; sleep 1; done; exit 1".into(),
      ],
      env: HashMap::new(),
    }
  }

  fn start_session_request(&self) -> DaytonaExecRequest {
    let mut env = HashMap::new();
    env.insert(
      "ORBITDOCK_MANAGED_SESSION_REQUEST_B64".into(),
      self.managed_request_base64.clone(),
    );
    DaytonaExecRequest {
      command: vec![
        "sh".into(),
        "-lc".into(),
        "orbitdock managed-session-start --server-url http://127.0.0.1:4000 --request-base64 \"$ORBITDOCK_MANAGED_SESSION_REQUEST_B64\"".into(),
      ],
      env,
    }
  }

  fn graceful_shutdown_request() -> DaytonaExecRequest {
    DaytonaExecRequest {
      command: vec![
        "sh".into(),
        "-lc".into(),
        "if [ ! -f /tmp/orbitdock-managed.pid ]; then exit 0; fi; pid=$(cat /tmp/orbitdock-managed.pid); kill -INT \"$pid\" 2>/dev/null || true; for _ in $(seq 1 35); do kill -0 \"$pid\" 2>/dev/null || exit 0; sleep 1; done; exit 1".into(),
      ],
      env: HashMap::new(),
    }
  }
}

async fn resolve_mission_issue_row_id(
  registry: Arc<SessionRegistry>,
  mission_id: String,
  issue_id: String,
) -> Result<String> {
  tokio::task::spawn_blocking(move || -> Result<String> {
    let conn = rusqlite::Connection::open(registry.db_path())?;
    let id = conn.query_row(
      "SELECT id FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
      rusqlite::params![mission_id, issue_id],
      |row| row.get::<_, String>(0),
    )?;
    Ok(id)
  })
  .await
  .context("join mission issue row lookup")?
}

async fn insert_workspace(
  registry: Arc<SessionRegistry>,
  insert: WorkspaceRecordInsert<'_>,
) -> Result<()> {
  let owned = (
    insert.id.to_string(),
    insert.mission_issue_id.to_string(),
    insert.session_id.map(ToString::to_string),
    insert.provider,
    insert.repo_url.to_string(),
    insert.branch.to_string(),
    insert.sync_token.to_string(),
    registry.db_path().clone(),
  );
  tokio::task::spawn_blocking(move || -> Result<()> {
    let (id, mission_issue_id, session_id, provider, repo_url, branch, sync_token, db_path) = owned;
    let conn = rusqlite::Connection::open(db_path)?;
    insert_workspace_record(
      &conn,
      &WorkspaceRecordInsert {
        id: &id,
        mission_issue_id: &mission_issue_id,
        session_id: session_id.as_deref(),
        provider,
        repo_url: &repo_url,
        branch: &branch,
        sync_token: &sync_token,
      },
    )
  })
  .await
  .context("join workspace insert")?
}

async fn update_workspace(
  registry: Arc<SessionRegistry>,
  update: WorkspaceRecordUpdate<'_>,
) -> Result<()> {
  let owned = (
    update.id.to_string(),
    update.external_id.map(ToString::to_string),
    update.status.to_string(),
    update.connection_info.cloned(),
    update.ready,
    update.destroyed,
    registry.db_path().clone(),
  );
  tokio::task::spawn_blocking(move || -> Result<()> {
    let (id, external_id, status, connection_info, ready, destroyed, db_path) = owned;
    let conn = rusqlite::Connection::open(db_path)?;
    update_workspace_record(
      &conn,
      &WorkspaceRecordUpdate {
        id: &id,
        external_id: external_id.as_deref(),
        status: &status,
        connection_info: connection_info.as_ref(),
        ready,
        destroyed,
      },
    )
  })
  .await
  .context("join workspace update")?
}

async fn load_workspace(
  registry: Arc<SessionRegistry>,
  workspace_id: String,
) -> Result<Option<WorkspaceRecord>> {
  tokio::task::spawn_blocking(move || -> Result<Option<WorkspaceRecord>> {
    let conn = rusqlite::Connection::open(registry.db_path())?;
    load_workspace_record(&conn, &workspace_id)
  })
  .await
  .context("join workspace lookup")?
}

async fn mark_workspace_failed(registry: Arc<SessionRegistry>, workspace_id: String) -> Result<()> {
  update_workspace(
    registry,
    WorkspaceRecordUpdate {
      id: &workspace_id,
      external_id: None,
      status: "failed",
      connection_info: None,
      ready: false,
      destroyed: false,
    },
  )
  .await
}

pub(crate) async fn destroy_daytona_workspace(
  registry: Arc<SessionRegistry>,
  workspace_id: &str,
) -> Result<()> {
  let Some(workspace) = load_workspace(registry.clone(), workspace_id.to_string()).await? else {
    return Ok(());
  };

  if workspace.provider != orbitdock_protocol::WorkspaceProviderKind::Daytona {
    return Ok(());
  }

  if workspace.destroyed_at.is_some() || workspace.status == "destroyed" {
    return Ok(());
  }

  update_workspace(
    registry.clone(),
    WorkspaceRecordUpdate {
      id: &workspace.id,
      external_id: workspace.external_id.as_deref(),
      status: "destroying",
      connection_info: None,
      ready: false,
      destroyed: false,
    },
  )
  .await?;

  if let Some(external_id) = workspace.external_id.as_deref() {
    let client = DaytonaClient::new(DaytonaConfig::load()?)?;
    let shutdown = client
      .exec_in_workspace(external_id, &DaytonaLaunchPlan::graceful_shutdown_request())
      .await?;
    if shutdown.exit_code != 0 {
      tracing::warn!(
        component = "workspace_provider",
        event = "daytona.shutdown.nonzero_exit",
        workspace_id = %workspace.id,
        external_id = %external_id,
        exit_code = shutdown.exit_code,
        stderr = %shutdown.stderr,
        "Managed workspace shutdown did not exit cleanly before delete"
      );
    }
    client.delete_workspace(external_id).await?;
  }

  update_workspace(
    registry,
    WorkspaceRecordUpdate {
      id: &workspace.id,
      external_id: workspace.external_id.as_deref(),
      status: "destroyed",
      connection_info: None,
      ready: false,
      destroyed: true,
    },
  )
  .await
}

#[cfg(test)]
mod tests {
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
    let plan = DaytonaLaunchPlan::build(&config, &request, "workspace-1", "session-1", "token-1")
      .expect("build launch plan");

    assert!(plan.sync_url.contains("dock.example.com"));
    assert!(plan.managed_request_base64.len() > 10);
    assert!(plan.start_server_request().command[2].contains("orbitdock start"));
    assert!(plan.start_server_request().command[2].contains("orbitdock-managed.pid"));
    assert!(plan.start_session_request().command[2].contains("managed-session-start"));
  }
}
