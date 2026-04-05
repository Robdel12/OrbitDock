use std::sync::Arc;
use std::time::Duration;

use tracing::info;

use crate::connectors::claude_session::{ClaudeSession, ClaudeSessionConfig};
use crate::connectors::codex_session::CodexSession;
use crate::domain::sessions::session::SessionHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
  activate_direct_session_runtime, claim_codex_thread_for_direct_session,
};
use orbitdock_connector_codex::{CodexConfigOverrides, CodexControlPlane};
use orbitdock_protocol::Provider;

pub(crate) struct StartDirectCodexRequest<'a> {
  pub handle: SessionHandle,
  pub session_id: &'a str,
  pub cwd: &'a str,
  pub model: Option<&'a str>,
  pub approval_policy: Option<&'a str>,
  pub sandbox_mode: Option<&'a str>,
  pub collaboration_mode: Option<&'a str>,
  pub multi_agent: Option<bool>,
  pub personality: Option<&'a str>,
  pub service_tier: Option<&'a str>,
  pub developer_instructions: Option<&'a str>,
  pub config_profile: Option<&'a str>,
  pub model_provider: Option<&'a str>,
  pub dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
}

pub(crate) async fn start_direct_codex_session(
  state: &Arc<SessionRegistry>,
  request: StartDirectCodexRequest<'_>,
) -> Result<(), String> {
  let StartDirectCodexRequest {
    mut handle,
    session_id,
    cwd,
    model,
    approval_policy,
    sandbox_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    config_profile,
    model_provider,
    dynamic_tools,
  } = request;
  let session_id = session_id.to_string();
  let cwd = cwd.to_string();
  let model = model.map(ToOwned::to_owned);
  let approval_policy = approval_policy.map(ToOwned::to_owned);
  let sandbox_mode = sandbox_mode.map(ToOwned::to_owned);
  let collaboration_mode = collaboration_mode.map(ToOwned::to_owned);
  let personality = personality.map(ToOwned::to_owned);
  let service_tier = service_tier.map(ToOwned::to_owned);
  let developer_instructions = developer_instructions.map(ToOwned::to_owned);
  let config_profile = config_profile.map(ToOwned::to_owned);
  let model_provider = model_provider.map(ToOwned::to_owned);
  let persist_tx = state.persist().clone();
  let connector_timeout = Duration::from_secs(15);
  let task_session_id = session_id.clone();

  let dynamic_tools_json: Vec<serde_json::Value> = dynamic_tools
    .iter()
    .filter_map(|t| serde_json::to_value(t).ok())
    .collect();

  let mut connector_task = tokio::spawn(async move {
    CodexSession::new_with_config(
      task_session_id,
      orbitdock_connector_codex::session::CodexSessionConfig {
        cwd: &cwd,
        model: model.as_deref(),
        approval_policy: approval_policy.as_deref(),
        sandbox_mode: sandbox_mode.as_deref(),
        config_overrides: CodexConfigOverrides {
          model_provider,
          config_profile,
        },
        control_plane: CodexControlPlane {
          approvals_reviewer: None,
          collaboration_mode,
          multi_agent,
          personality,
          service_tier,
          developer_instructions,
          effort: None,
        },
        dynamic_tools_json,
      },
    )
    .await
  });

  let codex_session = match tokio::time::timeout(connector_timeout, &mut connector_task).await {
    Ok(Ok(Ok(session))) => session,
    Ok(Ok(Err(error))) => return Err(error.to_string()),
    Ok(Err(join_error)) => return Err(format!("Connector task panicked: {join_error}")),
    Err(_) => {
      connector_task.abort();
      return Err("Connector creation timed out".to_string());
    }
  };

  let thread_id = codex_session.thread_id().to_string();
  claim_codex_thread_for_direct_session(
    state,
    &persist_tx,
    &session_id,
    &thread_id,
    "legacy_codex_thread_row_cleanup",
  )
  .await;

  handle.set_list_tx(state.list_tx());
  handle.set_dashboard_revision_counter(state.dashboard_revision_counter());
  let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
    codex_session,
    handle,
    persist_tx,
    state.clone(),
  );
  state.add_session_actor(actor_handle);
  state.set_codex_action_tx(&session_id, action_tx);
  activate_direct_session_runtime(state, &session_id, Provider::Codex).await;

  info!(
      component = "session",
      event = "session.create.connector_started",
      session_id = %session_id,
      "Codex connector started"
  );

  Ok(())
}

pub(crate) async fn start_direct_claude_session(
  state: &Arc<SessionRegistry>,
  request: StartDirectClaudeRequest<'_>,
) -> Result<(), String> {
  let StartDirectClaudeRequest {
    mut handle,
    session_id,
    cwd,
    model,
    permission_mode,
    allowed_tools,
    disallowed_tools,
    effort,
    allow_bypass_permissions,
    extra_env,
  } = request;
  let session_id = session_id.to_string();
  let claude_session = ClaudeSession::new(
    session_id.clone(),
    ClaudeSessionConfig {
      cwd,
      model,
      resume_id: None,
      permission_mode,
      allowed_tools,
      disallowed_tools,
      effort,
      allow_bypass_permissions,
      extra_env,
      orbitdock_session_id: &session_id,
    },
  )
  .await
  .map_err(|error| error.to_string())?;

  handle.set_list_tx(state.list_tx());
  handle.set_dashboard_revision_counter(state.dashboard_revision_counter());
  let persist_tx = state.persist().clone();
  let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
    claude_session,
    handle,
    persist_tx.clone(),
    state.list_tx(),
    state.clone(),
  );

  if let Some(mode) = permission_mode {
    let _ = actor_handle
      .send(SessionCommand::ApplyDelta {
        changes: Box::new(orbitdock_protocol::StateChanges {
          permission_mode: Some(Some(mode.to_string())),
          ..Default::default()
        }),
        persist_op: None,
      })
      .await;
  }

  state.add_session_actor(actor_handle);
  state.set_claude_action_tx(&session_id, action_tx.clone());
  activate_direct_session_runtime(state, &session_id, Provider::Claude).await;

  info!(
      component = "session",
      event = "session.create.claude_connector_started",
      session_id = %session_id,
      "Claude connector started"
  );

  Ok(())
}

pub(crate) struct StartDirectClaudeRequest<'a> {
  pub handle: SessionHandle,
  pub session_id: &'a str,
  pub cwd: &'a str,
  pub model: Option<&'a str>,
  pub permission_mode: Option<&'a str>,
  pub allowed_tools: &'a [String],
  pub disallowed_tools: &'a [String],
  pub effort: Option<&'a str>,
  pub allow_bypass_permissions: bool,
  pub extra_env: &'a [(String, String)],
}
