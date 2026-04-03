use std::sync::Arc;
use std::time::Duration;

use tokio::sync::oneshot;
use tracing::{error, info};

use orbitdock_protocol::{
  CodexConfigMode, CodexConfigSource, CodexSessionOverrides, Provider, SessionSummary,
};

use crate::connectors::claude_session::{ClaudeSession, ClaudeSessionConfig};
use crate::connectors::codex_session::CodexSession;
use crate::infrastructure::persistence::{load_session_permission_mode, PersistCommand};
use crate::runtime::codex_config::{resolve_codex_settings, CodexConfigSelection};
use crate::runtime::restored_sessions::PreparedResumeSession;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
  activate_direct_session_runtime, claim_codex_thread_for_direct_session,
  direct_resume_failure_changes,
};
use crate::support::session_paths::resolve_claude_resume_cwd;

pub(crate) struct ResumeSessionLaunch {
  pub summary: SessionSummary,
  pub startup_ready: Option<oneshot::Receiver<()>>,
}

pub(crate) enum ResumeSessionError {
  MissingClaudeResumeId,
}

impl ResumeSessionError {
  pub(crate) fn code(&self) -> &'static str {
    match self {
      Self::MissingClaudeResumeId => "resume_failed",
    }
  }

  pub(crate) fn message(&self) -> String {
    match self {
      Self::MissingClaudeResumeId => {
        "Cannot resume — no valid Claude SDK session ID was saved".to_string()
      }
    }
  }
}

pub(crate) async fn launch_resumed_session(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  prepared: PreparedResumeSession,
) -> Result<ResumeSessionLaunch, ResumeSessionError> {
  if prepared.transcript_loaded {
    info!(
        component = "session",
        event = "session.resume.transcript_loaded",
        session_id = %session_id,
        message_count = prepared.row_count,
        "Loaded messages from transcript for resume"
    );
  }

  let session_id = session_id.to_string();
  let summary = prepared.summary.clone();

  let persist_tx = state.persist().clone();
  let _ = persist_tx
    .send(PersistCommand::ReactivateSession {
      id: session_id.clone(),
    })
    .await;

  let startup_ready = match prepared.provider {
    Provider::Claude => {
      let project = if let Some(ref transcript_path) = prepared.transcript_path {
        resolve_claude_resume_cwd(&prepared.project_path, transcript_path)
      } else {
        prepared.project_path.clone()
      };

      let Some(provider_resume_id) = prepared
        .claude_sdk_session_id
        .clone()
        .and_then(orbitdock_protocol::ProviderSessionId::new)
      else {
        let mut handle = prepared.handle;
        handle.apply_changes(&direct_resume_failure_changes(Provider::Claude));
        state.add_session(handle);
        state.publish_dashboard_snapshot();
        return Err(ResumeSessionError::MissingClaudeResumeId);
      };

      state.register_claude_thread(&session_id, provider_resume_id.as_str());
      let startup_ready = spawn_claude_resume(
        state,
        ClaudeResumeParams {
          session_id: session_id.clone(),
          project,
          model: prepared.model,
          provider_resume_id,
          handle: prepared.handle,
          message_count: prepared.row_count,
          allow_bypass_permissions: prepared.allow_bypass_permissions,
        },
      )
      .await;
      Some(startup_ready)
    }
    Provider::Codex => {
      let include_mission_tools = crate::domain::codex_tools::has_mission_context(
        prepared.summary.mission_id.as_deref(),
        prepared.summary.issue_identifier.as_deref(),
      );
      spawn_codex_resume(
        state,
        CodexResumeRequest {
          session_id: session_id.clone(),
          project_path: prepared.project_path,
          model: prepared.model,
          codex_thread_id: prepared.codex_thread_id,
          approval_policy: prepared.approval_policy,
          sandbox_mode: prepared.sandbox_mode,
          collaboration_mode: prepared.collaboration_mode,
          multi_agent: prepared.multi_agent,
          personality: prepared.personality,
          service_tier: prepared.service_tier,
          developer_instructions: prepared.developer_instructions,
          codex_config_mode: prepared.codex_config_mode,
          codex_config_profile: prepared.codex_config_profile,
          codex_model_provider: prepared.codex_model_provider,
          codex_config_source: prepared.codex_config_source,
          codex_config_overrides: prepared.codex_config_overrides,
          include_mission_tools,
          handle: prepared.handle,
          message_count: prepared.row_count,
        },
      )
      .await
    }
  };

  Ok(ResumeSessionLaunch {
    summary,
    startup_ready,
  })
}

struct ClaudeResumeParams {
  session_id: String,
  project: String,
  model: Option<String>,
  provider_resume_id: orbitdock_protocol::ProviderSessionId,
  handle: crate::domain::sessions::session::SessionHandle,
  message_count: usize,
  allow_bypass_permissions: bool,
}

fn codex_resume_selection(request: &CodexResumeRequest) -> CodexConfigSelection {
  let inferred_config_mode = request.codex_config_mode.unwrap_or({
    if request
      .codex_config_profile
      .as_deref()
      .is_some_and(|value| !value.trim().is_empty())
    {
      CodexConfigMode::Profile
    } else if request
      .codex_model_provider
      .as_deref()
      .is_some_and(|value| !value.trim().is_empty())
    {
      CodexConfigMode::Custom
    } else {
      CodexConfigMode::Inherit
    }
  });

  CodexConfigSelection {
    config_source: request
      .codex_config_source
      .unwrap_or(CodexConfigSource::User),
    config_mode: inferred_config_mode,
    config_profile: request.codex_config_profile.clone(),
    model_provider: request.codex_model_provider.clone(),
    overrides: request
      .codex_config_overrides
      .clone()
      .unwrap_or(CodexSessionOverrides {
        model: request.model.clone(),
        model_provider: request.codex_model_provider.clone(),
        approval_policy: request.approval_policy.clone(),
        approval_policy_details: None,
        sandbox_mode: request.sandbox_mode.clone(),
        approvals_reviewer: None,
        collaboration_mode: request.collaboration_mode.clone(),
        multi_agent: request.multi_agent,
        personality: request.personality.clone(),
        service_tier: request.service_tier.clone(),
        developer_instructions: request.developer_instructions.clone(),
        effort: None,
      }),
  }
  .normalized()
}

async fn spawn_claude_resume(
  state: &Arc<SessionRegistry>,
  params: ClaudeResumeParams,
) -> oneshot::Receiver<()> {
  let ClaudeResumeParams {
    session_id,
    project,
    model,
    provider_resume_id,
    mut handle,
    message_count,
    allow_bypass_permissions,
  } = params;
  let persist_tx = state.persist().clone();
  let restored_permission_mode = load_session_permission_mode(&session_id)
    .await
    .unwrap_or(None);
  let state = state.clone();
  let (startup_ready_tx, startup_ready_rx) = oneshot::channel();

  tokio::spawn(async move {
    let connector_timeout = Duration::from_secs(15);
    let sid = session_id.clone();
    let resume_id = provider_resume_id.clone();
    let permission_mode = restored_permission_mode.clone();
    let connector_task = tokio::spawn(async move {
      ClaudeSession::new(
        sid.clone(),
        ClaudeSessionConfig {
          cwd: &project,
          model: model.as_deref(),
          resume_id: Some(&resume_id),
          permission_mode: permission_mode.as_deref(),
          allowed_tools: &[],
          disallowed_tools: &[],
          effort: None,
          allow_bypass_permissions,
          extra_env: &[],
        },
      )
      .await
    });

    match tokio::time::timeout(connector_timeout, connector_task).await {
      Ok(Ok(Ok(claude_session))) => {
        state.register_claude_thread(&session_id, provider_resume_id.as_str());
        handle.set_list_tx(state.list_tx());
        handle.set_dashboard_revision_counter(state.dashboard_revision_counter());
        let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
          claude_session,
          handle,
          persist_tx.clone(),
          state.list_tx(),
          state.clone(),
        );
        state.add_session_actor(actor_handle);
        state.set_claude_action_tx(&session_id, action_tx);
        activate_direct_session_runtime(&state, &session_id, Provider::Claude).await;

        if let Some(ref mode) = restored_permission_mode {
          if let Some(actor) = state.get_session(&session_id) {
            actor
              .send(SessionCommand::ApplyDelta {
                changes: Box::new(orbitdock_protocol::StateChanges {
                  permission_mode: Some(Some(mode.clone())),
                  ..Default::default()
                }),
                persist_op: None,
              })
              .await;
          }
        }

        let _ = persist_tx
          .send(PersistCommand::SetIntegrationMode {
            session_id: session_id.clone(),
            codex_mode: None,
            claude_mode: Some("direct".into()),
          })
          .await;

        info!(
            component = "session",
            event = "session.resume.http.claude_connected",
            session_id = %session_id,
            messages = message_count,
            "HTTP: Resumed Claude session"
        );
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
      }
      Ok(Ok(Err(error))) => {
        handle.apply_changes(&direct_resume_failure_changes(Provider::Claude));
        state.add_session(handle);
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
        error!(
            component = "session",
            event = "session.resume.http.claude_failed",
            session_id = %session_id,
            error = %error,
            "HTTP: Failed to resume Claude connector"
        );
      }
      Ok(Err(join_error)) => {
        handle.apply_changes(&direct_resume_failure_changes(Provider::Claude));
        state.add_session(handle);
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
        error!(
            component = "session",
            event = "session.resume.http.claude_panicked",
            session_id = %session_id,
            error = %join_error,
            "HTTP: Claude connector panicked"
        );
      }
      Err(_) => {
        handle.apply_changes(&direct_resume_failure_changes(Provider::Claude));
        state.add_session(handle);
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
        error!(
            component = "session",
            event = "session.resume.http.claude_timeout",
            session_id = %session_id,
            "HTTP: Claude connector timed out"
        );
      }
    }
  });

  startup_ready_rx
}

async fn spawn_codex_resume(
  state: &Arc<SessionRegistry>,
  request: CodexResumeRequest,
) -> Option<oneshot::Receiver<()>> {
  let normalized_selection = codex_resume_selection(&request);
  let CodexResumeRequest {
    session_id,
    project_path,
    codex_thread_id,
    include_mission_tools,
    mut handle,
    message_count,
    ..
  } = request;
  let session_id = session_id.to_string();
  let persist_tx = state.persist().clone();
  let state = state.clone();
  let (startup_ready_tx, startup_ready_rx) = oneshot::channel();

  tokio::spawn(async move {
    let connector_timeout = Duration::from_secs(15);
    let resolved = resolve_codex_settings(&project_path, normalized_selection.clone())
      .await
      .ok();
    let effective = resolved
      .as_ref()
      .map(|resolved| &resolved.effective_settings);
    let effective_model = effective
      .and_then(|value| value.model.clone())
      .or_else(|| normalized_selection.overrides.model.clone());
    let effective_approval = effective
      .and_then(|value| value.approval_policy.clone())
      .or_else(|| normalized_selection.overrides.approval_policy.clone());
    let effective_sandbox = effective
      .and_then(|value| value.sandbox_mode.clone())
      .or_else(|| normalized_selection.overrides.sandbox_mode.clone());
    let effective_collaboration_mode = effective
      .and_then(|value| value.collaboration_mode.clone())
      .or_else(|| normalized_selection.overrides.collaboration_mode.clone());
    let effective_multi_agent = effective
      .and_then(|value| value.multi_agent)
      .or(normalized_selection.overrides.multi_agent);
    let effective_personality = effective
      .and_then(|value| value.personality.clone())
      .or_else(|| normalized_selection.overrides.personality.clone());
    let effective_service_tier = effective
      .and_then(|value| value.service_tier.clone())
      .or_else(|| normalized_selection.overrides.service_tier.clone());
    let effective_developer_instructions = effective
      .and_then(|value| value.developer_instructions.clone())
      .or_else(|| {
        normalized_selection
          .overrides
          .developer_instructions
          .clone()
      });
    let effective_effort = effective
      .and_then(|value| value.effort.clone())
      .or_else(|| normalized_selection.overrides.effort.clone());
    let effective_model_provider = effective
      .and_then(|value| value.model_provider.clone())
      .or_else(|| normalized_selection.model_provider.clone())
      .or_else(|| normalized_selection.overrides.model_provider.clone());
    let effective_config_profile = effective
      .and_then(|value| value.config_profile.clone())
      .or_else(|| normalized_selection.config_profile.clone());
    let resumed_session_model = effective_model.clone();
    let task_session_id = session_id.clone();
    let mut connector_task = tokio::spawn(async move {
      let dynamic_tools_json =
        crate::domain::codex_tools::default_codex_dynamic_tools_json(include_mission_tools);
      let control_plane = orbitdock_connector_codex::CodexControlPlane {
        approvals_reviewer: normalized_selection
          .overrides
          .approvals_reviewer
          .map(|value| value.as_str().to_string()),
        collaboration_mode: effective_collaboration_mode.clone(),
        multi_agent: effective_multi_agent,
        personality: effective_personality.clone(),
        service_tier: effective_service_tier.clone(),
        developer_instructions: effective_developer_instructions.clone(),
        effort: effective_effort.clone(),
      };
      let build_session_config = |cp: orbitdock_connector_codex::CodexControlPlane| {
        orbitdock_connector_codex::session::CodexSessionConfig {
          cwd: &project_path,
          model: effective_model.as_deref(),
          approval_policy: effective_approval.as_deref(),
          sandbox_mode: effective_sandbox.as_deref(),
          config_overrides: orbitdock_connector_codex::CodexConfigOverrides {
            model_provider: effective_model_provider.clone(),
            config_profile: effective_config_profile.clone(),
          },
          control_plane: cp,
          dynamic_tools_json: dynamic_tools_json.clone(),
        }
      };

      if let Some(thread_id) = codex_thread_id.as_deref() {
        match CodexSession::resume_with_config(
          task_session_id.clone(),
          thread_id,
          build_session_config(control_plane.clone()),
        )
        .await
        {
          Ok(session) => Ok(session),
          Err(_) => {
            CodexSession::new_with_config(task_session_id, build_session_config(control_plane))
              .await
          }
        }
      } else {
        CodexSession::new_with_config(task_session_id, build_session_config(control_plane)).await
      }
    });

    let codex_start = match tokio::time::timeout(connector_timeout, &mut connector_task).await {
      Ok(Ok(Ok(session))) => Ok(session),
      Ok(Ok(Err(error))) => Err(error.to_string()),
      Ok(Err(join_error)) => Err(format!("Connector task panicked: {join_error}")),
      Err(_) => {
        connector_task.abort();
        Err("Connector creation timed out".to_string())
      }
    };

    match codex_start {
      Ok(codex_session) => {
        handle.set_model(resumed_session_model);
        let thread_id = codex_session.thread_id().to_string();
        claim_codex_thread_for_direct_session(
          &state,
          &persist_tx,
          &session_id,
          &thread_id,
          "http_resume_thread_cleanup",
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
        activate_direct_session_runtime(&state, &session_id, Provider::Codex).await;
        info!(
            component = "session",
            event = "session.resume.http.codex_connected",
            session_id = %session_id,
            messages = message_count,
            "HTTP: Resumed Codex session"
        );
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
      }
      Err(error) => {
        handle.apply_changes(&direct_resume_failure_changes(Provider::Codex));
        state.add_session(handle);
        state.publish_dashboard_snapshot();
        let _ = startup_ready_tx.send(());
        error!(
            component = "session",
            event = "session.resume.http.codex_failed",
            session_id = %session_id,
            error = %error,
            "HTTP: Failed to resume Codex connector"
        );
      }
    }
  });

  Some(startup_ready_rx)
}

struct CodexResumeRequest {
  session_id: String,
  project_path: String,
  model: Option<String>,
  codex_thread_id: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  collaboration_mode: Option<String>,
  multi_agent: Option<bool>,
  personality: Option<String>,
  service_tier: Option<String>,
  developer_instructions: Option<String>,
  codex_config_mode: Option<CodexConfigMode>,
  codex_config_profile: Option<String>,
  codex_model_provider: Option<String>,
  codex_config_source: Option<CodexConfigSource>,
  codex_config_overrides: Option<CodexSessionOverrides>,
  include_mission_tools: bool,
  handle: crate::domain::sessions::session::SessionHandle,
  message_count: usize,
}

#[cfg(test)]
mod tests {
  use super::*;

  fn codex_resume_request(
    model: Option<&str>,
    codex_config_mode: Option<CodexConfigMode>,
    codex_config_profile: Option<&str>,
    codex_model_provider: Option<&str>,
  ) -> CodexResumeRequest {
    CodexResumeRequest {
      session_id: "session-1".to_string(),
      project_path: "/tmp/project".to_string(),
      model: model.map(str::to_string),
      codex_thread_id: None,
      approval_policy: None,
      sandbox_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode,
      codex_config_profile: codex_config_profile.map(str::to_string),
      codex_model_provider: codex_model_provider.map(str::to_string),
      codex_config_source: Some(CodexConfigSource::User),
      codex_config_overrides: None,
      include_mission_tools: false,
      handle: crate::domain::sessions::session::SessionHandle::new(
        "session-1".to_string(),
        Provider::Codex,
        "/tmp/project".to_string(),
      ),
      message_count: 0,
    }
  }

  #[test]
  fn codex_resume_selection_clears_stale_model_for_profile_mode() {
    let request = codex_resume_request(
      Some("gpt-5.4"),
      Some(CodexConfigMode::Profile),
      Some("qwen"),
      Some("openrouter"),
    );
    let selection = codex_resume_selection(&request);

    assert_eq!(selection.config_mode, CodexConfigMode::Profile);
    assert_eq!(selection.config_profile.as_deref(), Some("qwen"));
    assert_eq!(selection.overrides.model, None);
    assert_eq!(selection.overrides.model_provider, None);
  }

  #[test]
  fn codex_resume_selection_preserves_explicit_model_for_custom_mode() {
    let request = codex_resume_request(
      Some("qwen/qwen3-coder-next"),
      Some(CodexConfigMode::Custom),
      None,
      Some("openrouter"),
    );
    let selection = codex_resume_selection(&request);

    assert_eq!(selection.config_mode, CodexConfigMode::Custom);
    assert_eq!(
      selection.overrides.model.as_deref(),
      Some("qwen/qwen3-coder-next")
    );
    assert_eq!(
      selection.overrides.model_provider.as_deref(),
      Some("openrouter")
    );
  }

  #[test]
  fn codex_resume_selection_infers_profile_mode_for_legacy_rows() {
    let request = codex_resume_request(
      Some("qwen/qwen3-coder-next"),
      None,
      Some("qwen"),
      Some("openrouter"),
    );
    let selection = codex_resume_selection(&request);

    assert_eq!(selection.config_mode, CodexConfigMode::Profile);
    assert_eq!(selection.config_profile.as_deref(), Some("qwen"));
    assert_eq!(selection.overrides.model, None);
    assert_eq!(selection.overrides.model_provider, None);
  }

  #[test]
  fn codex_resume_selection_infers_custom_mode_for_legacy_provider_rows() {
    let request = codex_resume_request(
      Some("qwen/qwen3-coder-next"),
      None,
      None,
      Some("openrouter"),
    );
    let selection = codex_resume_selection(&request);

    assert_eq!(selection.config_mode, CodexConfigMode::Custom);
    assert_eq!(
      selection.overrides.model.as_deref(),
      Some("qwen/qwen3-coder-next")
    );
    assert_eq!(
      selection.overrides.model_provider.as_deref(),
      Some("openrouter")
    );
  }
}
