use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexConfigMode, CodexConfigSource, CodexIntegrationMode,
  CodexSessionOverrides, Provider, SessionSummary,
};

use crate::domain::sessions::session::{SessionConfig, SessionHandle};
use crate::infrastructure::persistence::{PersistCommand, SessionCreateParams};
use crate::runtime::session_direct_start::{
  start_direct_claude_session, start_direct_codex_session, StartDirectCodexRequest,
};
use crate::runtime::session_mutations::end_failed_direct_session;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
  verify_direct_runtime_ready_with_startup_grace, DIRECT_RUNTIME_STARTUP_GRACE,
};

pub(crate) struct DirectSessionCreationInputs {
  pub id: String,
  pub provider: Provider,
  pub cwd: String,
  pub git_branch: Option<String>,
  pub config: SessionConfig,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub allow_bypass_permissions: bool,
}

pub(crate) struct PreparedDirectSession {
  pub project_name: Option<String>,
  pub handle: SessionHandle,
  pub summary: SessionSummary,
}

#[derive(Clone)]
pub(crate) struct DirectSessionRequest {
  pub provider: Provider,
  pub cwd: String,
  pub model: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub sandbox_policy_details: Option<orbitdock_protocol::CodexSandboxPolicy>,
  pub permission_mode: Option<String>,
  pub allowed_tools: Vec<String>,
  pub disallowed_tools: Vec<String>,
  pub effort: Option<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub worktree_id: Option<String>,
  /// Dynamic tool specs for Codex sessions (mission tools).
  pub dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  /// When true, pass `--allow-dangerously-skip-permissions` to the Claude CLI,
  /// enabling mid-session switches to `bypassPermissions` mode.
  pub allow_bypass_permissions: bool,
  pub claude_extra_env: Vec<(String, String)>,
  pub codex_config_mode: Option<CodexConfigMode>,
  pub codex_config_profile: Option<String>,
  pub codex_model_provider: Option<String>,
  pub codex_config_source: Option<CodexConfigSource>,
  pub codex_config_overrides: Option<CodexSessionOverrides>,
}

pub(crate) struct PreparedPersistedDirectSession {
  pub id: String,
  pub request: DirectSessionRequest,
  pub handle: SessionHandle,
  pub summary: SessionSummary,
}

struct PersistDirectSessionCreate {
  id: String,
  provider: Provider,
  project_path: String,
  project_name: Option<String>,
  branch: Option<String>,
  model: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  permission_mode: Option<String>,
  collaboration_mode: Option<String>,
  multi_agent: Option<bool>,
  personality: Option<String>,
  service_tier: Option<String>,
  developer_instructions: Option<String>,
  effort: Option<String>,
  mission_id: Option<String>,
  issue_identifier: Option<String>,
  worktree_id: Option<String>,
  allow_bypass_permissions: bool,
  codex_config_mode: Option<CodexConfigMode>,
  codex_config_profile: Option<String>,
  codex_model_provider: Option<String>,
  codex_config_source: Option<CodexConfigSource>,
  codex_config_overrides_json: Option<String>,
}

pub(crate) fn prepare_direct_session(input: DirectSessionCreationInputs) -> PreparedDirectSession {
  let project_name = input.cwd.split('/').next_back().map(String::from);
  let mut handle = SessionHandle::new(input.id, input.provider, input.cwd);
  handle.set_git_branch(input.git_branch);

  if let Some(ref model) = input.config.model {
    handle.set_model(Some(model.clone()));
  }
  if let Some(ref effort) = input.config.effort {
    handle.set_effort(Some(effort.clone()));
  }

  if input.provider == Provider::Codex {
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    handle.set_config(input.config);
  } else if input.provider == Provider::Claude {
    handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
  }

  if input.mission_id.is_some() || input.issue_identifier.is_some() {
    handle.set_mission_context(input.mission_id, input.issue_identifier);
  }
  if input.allow_bypass_permissions {
    handle.set_allow_bypass_permissions(true);
  }

  let summary = handle.summary();

  PreparedDirectSession {
    project_name,
    handle,
    summary,
  }
}

async fn persist_direct_session_create(
  persist_tx: &mpsc::Sender<PersistCommand>,
  request: PersistDirectSessionCreate,
) {
  let PersistDirectSessionCreate {
    id,
    provider,
    project_path,
    project_name,
    branch,
    model,
    approval_policy,
    sandbox_mode,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    effort,
    mission_id,
    issue_identifier,
    worktree_id,
    allow_bypass_permissions,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides_json,
  } = request;
  let _ = persist_tx
    .send(PersistCommand::SessionCreate(Box::new(
      SessionCreateParams {
        id: id.clone(),
        provider,
        control_mode: orbitdock_protocol::SessionControlMode::Direct,
        project_path,
        project_name,
        branch,
        model,
        approval_policy,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        codex_config_mode,
        codex_config_profile,
        codex_model_provider,
        codex_config_source,
        codex_config_overrides_json,
        forked_from_session_id: None,
        mission_id,
        issue_identifier,
        allow_bypass_permissions,
        worktree_id,
      },
    )))
    .await;

  if let Some(effort_name) = effort {
    let _ = persist_tx
      .send(PersistCommand::EffortUpdate {
        session_id: id,
        effort: Some(effort_name),
      })
      .await;
  }
}

pub(crate) async fn prepare_persist_direct_session(
  state: &Arc<SessionRegistry>,
  id: String,
  request: DirectSessionRequest,
) -> PreparedPersistedDirectSession {
  let git_branch = crate::domain::git::repo::resolve_git_branch(&request.cwd).await;
  let prepared = prepare_direct_session(DirectSessionCreationInputs {
    id: id.clone(),
    provider: request.provider,
    cwd: request.cwd.clone(),
    git_branch: git_branch.clone(),
    config: SessionConfig {
      model: request.model.clone(),
      approval_policy: request.approval_policy.clone(),
      sandbox_mode: request.sandbox_mode.clone(),
      sandbox_policy_details: request.sandbox_policy_details.clone(),
      collaboration_mode: request.collaboration_mode.clone(),
      multi_agent: request.multi_agent,
      personality: request.personality.clone(),
      service_tier: request.service_tier.clone(),
      developer_instructions: request.developer_instructions.clone(),
      effort: request.effort.clone(),
      codex_config_mode: request.codex_config_mode,
      codex_config_profile: request.codex_config_profile.clone(),
      codex_model_provider: request.codex_model_provider.clone(),
      codex_config_source: request.codex_config_source,
      codex_config_overrides: request.codex_config_overrides.clone(),
      ..Default::default()
    },
    mission_id: request.mission_id.clone(),
    issue_identifier: request.issue_identifier.clone(),
    allow_bypass_permissions: request.allow_bypass_permissions,
  });

  let persist_tx = state.persist().clone();
  persist_direct_session_create(
    &persist_tx,
    PersistDirectSessionCreate {
      id: id.clone(),
      provider: request.provider,
      project_path: request.cwd.clone(),
      project_name: prepared.project_name,
      branch: git_branch,
      model: request.model.clone(),
      approval_policy: request.approval_policy.clone(),
      sandbox_mode: request.sandbox_mode.clone(),
      permission_mode: request.permission_mode.clone(),
      collaboration_mode: request.collaboration_mode.clone(),
      multi_agent: request.multi_agent,
      personality: request.personality.clone(),
      service_tier: request.service_tier.clone(),
      developer_instructions: request.developer_instructions.clone(),
      effort: request.effort.clone(),
      mission_id: request.mission_id.clone(),
      issue_identifier: request.issue_identifier.clone(),
      worktree_id: request.worktree_id.clone(),
      allow_bypass_permissions: request.allow_bypass_permissions,
      codex_config_mode: request.codex_config_mode,
      codex_config_profile: request.codex_config_profile.clone(),
      codex_model_provider: request.codex_model_provider.clone(),
      codex_config_source: request.codex_config_source,
      codex_config_overrides_json: request
        .codex_config_overrides
        .as_ref()
        .and_then(crate::runtime::codex_config::serialize_codex_overrides),
    },
  )
  .await;

  PreparedPersistedDirectSession {
    id,
    request,
    handle: prepared.handle,
    summary: prepared.summary,
  }
}

pub(crate) async fn launch_prepared_direct_session(
  state: &Arc<SessionRegistry>,
  prepared: PreparedPersistedDirectSession,
) -> Result<(), String> {
  let session_id = prepared.id.clone();
  let request = prepared.request.clone();
  let handle = prepared.handle;

  let start_result = match request.provider {
    Provider::Codex => {
      let dynamic_tools = crate::domain::codex_tools::with_default_codex_workspace_tools(
        request.dynamic_tools.clone(),
      );
      start_direct_codex_session(
        state,
        StartDirectCodexRequest {
          handle,
          session_id: &session_id,
          cwd: &request.cwd,
          model: request.model.as_deref(),
          approval_policy: request.approval_policy.as_deref(),
          sandbox_mode: request.sandbox_mode.as_deref(),
          sandbox_policy_details: request.sandbox_policy_details.as_ref(),
          collaboration_mode: request.collaboration_mode.as_deref(),
          multi_agent: request.multi_agent,
          personality: request.personality.as_deref(),
          service_tier: request.service_tier.as_deref(),
          developer_instructions: request.developer_instructions.as_deref(),
          config_profile: request.codex_config_profile.as_deref(),
          model_provider: request.codex_model_provider.as_deref(),
          dynamic_tools,
        },
      )
      .await
    }
    Provider::Claude => {
      start_direct_claude_session(
        state,
        crate::runtime::session_direct_start::StartDirectClaudeRequest {
          handle,
          session_id: &session_id,
          cwd: &request.cwd,
          model: request.model.as_deref(),
          permission_mode: request.permission_mode.as_deref(),
          allowed_tools: &request.allowed_tools,
          disallowed_tools: &request.disallowed_tools,
          effort: request.effort.as_deref(),
          allow_bypass_permissions: request.allow_bypass_permissions,
          extra_env: &request.claude_extra_env,
        },
      )
      .await
    }
  };

  if start_result.is_err() {
    end_failed_direct_session(state, &session_id).await;
    return start_result;
  }

  if let Err(readiness_error) = verify_direct_runtime_ready_with_startup_grace(
    state,
    &session_id,
    request.provider,
    DIRECT_RUNTIME_STARTUP_GRACE,
  )
  .await
  {
    end_failed_direct_session(state, &session_id).await;
    return Err(readiness_error);
  }

  Ok(())
}

#[cfg(test)]
#[path = "session_creation_tests.rs"]
mod session_creation_tests;
