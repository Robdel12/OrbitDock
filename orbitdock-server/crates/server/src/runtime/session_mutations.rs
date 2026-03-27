use std::sync::Arc;

use orbitdock_protocol::{CodexApprovalPolicy, CodexConfigMode, ServerMessage};

use orbitdock_protocol::StateChanges;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::codex_config::{
  resolve_codex_settings, serialize_codex_overrides, CodexConfigSelection,
};
use crate::runtime::session_commands::{PersistOp, SessionCommand, SessionConfigPersist};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_modes::is_passive_rollout_session;

pub(crate) enum SessionMutationError {
  NotFound(String),
  InvalidCodexConfig(String),
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionConfigUpdate {
  pub approval_policy: Option<Option<String>>,
  pub approval_policy_details: Option<Option<CodexApprovalPolicy>>,
  pub sandbox_mode: Option<Option<String>>,
  pub permission_mode: Option<Option<String>>,
  pub collaboration_mode: Option<Option<String>>,
  pub multi_agent: Option<Option<bool>>,
  pub personality: Option<Option<String>>,
  pub service_tier: Option<Option<String>>,
  pub developer_instructions: Option<Option<String>>,
  pub model: Option<Option<String>>,
  pub effort: Option<Option<String>>,
  pub codex_config_mode: Option<Option<CodexConfigMode>>,
  pub codex_config_profile: Option<Option<String>>,
  pub codex_model_provider: Option<Option<String>>,
}

impl SessionMutationError {
  pub(crate) fn code(&self) -> &'static str {
    match self {
      Self::NotFound(_) => "not_found",
      Self::InvalidCodexConfig(_) => "invalid_codex_config",
    }
  }

  pub(crate) fn message(&self) -> String {
    match self {
      Self::NotFound(session_id) => format!("Session {session_id} not found"),
      Self::InvalidCodexConfig(message) => message.clone(),
    }
  }
}

pub(crate) async fn rename_session(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  name: Option<String>,
) -> Result<(), SessionMutationError> {
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
  actor
    .send(SessionCommand::SetCustomNameAndNotify {
      name: name.clone(),
      persist_op: Some(PersistOp::SetCustomName {
        session_id: session_id.to_string(),
        name: name.clone(),
      }),
      reply: reply_tx,
    })
    .await;

  if reply_rx.await.is_ok() {
    state.publish_dashboard_snapshot();
  }

  if let Some(ref name) = name {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
      let _ = tx
        .send(CodexAction::SetThreadName { name: name.clone() })
        .await;
    }
  }

  Ok(())
}

pub(crate) async fn set_summary(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  summary: String,
) -> Result<(), SessionMutationError> {
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

  // Apply summary delta to in-memory state and broadcast to session subscribers
  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        summary: Some(Some(summary.clone())),
        ..Default::default()
      }),
      persist_op: None,
    })
    .await;

  state.publish_dashboard_snapshot();

  // Persist to DB
  let _ = state
    .persist()
    .send(PersistCommand::SetSummary {
      session_id: session_id.to_string(),
      summary,
    })
    .await;

  Ok(())
}

pub(crate) async fn update_session_config(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  update: SessionConfigUpdate,
) -> Result<(), SessionMutationError> {
  let SessionConfigUpdate {
    approval_policy,
    approval_policy_details,
    sandbox_mode,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
  } = update;
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;
  let current_summary = actor
    .summary()
    .await
    .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;

  if current_summary.provider == orbitdock_protocol::Provider::Codex
    && state.get_codex_action_tx(session_id).is_some()
    && (codex_config_mode.is_some()
      || codex_config_profile.is_some()
      || codex_model_provider.is_some())
  {
    return Err(SessionMutationError::InvalidCodexConfig(
            "Provider and profile selection are set when a Codex session starts. Start a new session to change them."
                .to_string(),
        ));
  }

  let (
    approval_policy,
    approval_policy_details,
    sandbox_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides,
  ) = if current_summary.provider == orbitdock_protocol::Provider::Codex {
    let mut overrides = current_summary.codex_config_overrides.unwrap_or_default();
    if let Some(value) = model {
      overrides.model = value;
    }
    if let Some(value) = approval_policy {
      overrides.approval_policy = value;
    }
    if let Some(value) = approval_policy_details.clone() {
      overrides.approval_policy_details = value;
      if let Some(ref details) = overrides.approval_policy_details {
        overrides.approval_policy = Some(details.legacy_summary());
      }
    }
    if let Some(value) = sandbox_mode {
      overrides.sandbox_mode = value;
    }
    if let Some(value) = collaboration_mode {
      overrides.collaboration_mode = value;
    }
    if let Some(value) = multi_agent {
      overrides.multi_agent = value;
    }
    if let Some(value) = personality {
      overrides.personality = value;
    }
    if let Some(value) = service_tier {
      overrides.service_tier = value;
    }
    if let Some(value) = developer_instructions {
      overrides.developer_instructions = value;
    }
    if let Some(value) = effort {
      overrides.effort = value;
    }
    if let Some(value) = codex_model_provider.clone() {
      overrides.model_provider = value;
    }

    let source = current_summary
      .codex_config_source
      .unwrap_or(orbitdock_protocol::CodexConfigSource::User);
    let config_mode = match codex_config_mode {
      Some(Some(value)) => value,
      Some(None) => orbitdock_protocol::CodexConfigMode::Inherit,
      None => current_summary
        .codex_config_mode
        .unwrap_or(orbitdock_protocol::CodexConfigMode::Inherit),
    };
    let config_profile = match codex_config_profile.clone() {
      Some(value) => value,
      None => current_summary.codex_config_profile.clone(),
    };
    let model_provider = match codex_model_provider.clone() {
      Some(value) => value,
      None => current_summary.codex_model_provider.clone(),
    };
    let resolved = resolve_codex_settings(
      &current_summary.project_path,
      CodexConfigSelection {
        config_source: source,
        config_mode,
        config_profile: config_profile.clone(),
        model_provider: model_provider.clone(),
        overrides: overrides.clone(),
      },
    )
    .await
    .map_err(SessionMutationError::InvalidCodexConfig)?;
    (
      Some(resolved.effective_settings.approval_policy.clone()),
      Some(resolved.effective_settings.approval_policy_details.clone()),
      Some(resolved.effective_settings.sandbox_mode.clone()),
      Some(resolved.effective_settings.collaboration_mode.clone()),
      Some(resolved.effective_settings.multi_agent),
      Some(resolved.effective_settings.personality.clone()),
      Some(resolved.effective_settings.service_tier.clone()),
      Some(resolved.effective_settings.developer_instructions.clone()),
      Some(resolved.effective_settings.model.clone()),
      Some(resolved.effective_settings.effort.clone()),
      Some(Some(config_mode)),
      Some(config_profile),
      Some(resolved.effective_settings.model_provider.clone()),
      Some(source),
      Some(overrides),
    )
  } else {
    (
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      model,
      effort,
      codex_config_mode,
      codex_config_profile,
      codex_model_provider,
      None,
      None,
    )
  };

  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(orbitdock_protocol::StateChanges {
        approval_policy: approval_policy.clone(),
        approval_policy_details: approval_policy_details.clone(),
        sandbox_mode: sandbox_mode.clone(),
        permission_mode: permission_mode.clone(),
        collaboration_mode: collaboration_mode.clone(),
        multi_agent,
        personality: personality.clone(),
        service_tier: service_tier.clone(),
        developer_instructions: developer_instructions.clone(),
        model: model.clone(),
        effort: effort.clone(),
        codex_config_mode,
        codex_config_profile: codex_config_profile.clone(),
        codex_model_provider: codex_model_provider.clone(),
        codex_config_source: codex_config_source.map(Some),
        codex_config_overrides: codex_config_overrides.clone().map(Some),
        ..Default::default()
      }),
      persist_op: Some(PersistOp::SetSessionConfig(Box::new(
        SessionConfigPersist {
          session_id: session_id.to_string(),
          approval_policy: approval_policy.clone(),
          sandbox_mode: sandbox_mode.clone(),
          permission_mode: permission_mode.clone(),
          collaboration_mode: collaboration_mode.clone(),
          multi_agent,
          personality: personality.clone(),
          service_tier: service_tier.clone(),
          developer_instructions: developer_instructions.clone(),
          model: model.clone(),
          effort: effort.clone(),
          codex_config_mode: codex_config_mode.flatten(),
          codex_config_profile: codex_config_profile.flatten(),
          codex_model_provider: codex_model_provider.flatten(),
          codex_config_source,
          codex_config_overrides_json: codex_config_overrides
            .as_ref()
            .and_then(serialize_codex_overrides),
        },
      ))),
    })
    .await;

  if actor.summary().await.is_ok() {
    state.publish_dashboard_snapshot();
  }

  if let Some(Some(ref mode)) = permission_mode {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx
        .send(ClaudeAction::SetPermissionMode { mode: mode.clone() })
        .await;
    }
  }

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx
      .send(CodexAction::UpdateConfig {
        approval_policy: approval_policy.flatten(),
        sandbox_mode: sandbox_mode.flatten(),
        permission_mode: permission_mode.flatten(),
        collaboration_mode: collaboration_mode.flatten(),
        multi_agent: multi_agent.flatten(),
        personality: personality.flatten(),
        service_tier: service_tier.flatten(),
        developer_instructions: developer_instructions.flatten(),
        model: model.flatten(),
        effort: effort.flatten(),
      })
      .await;
  }

  Ok(())
}

pub(crate) async fn end_session(state: &Arc<SessionRegistry>, session_id: &str) -> usize {
  let actor = state.get_session(session_id);
  let is_passive_rollout = actor.as_ref().is_some_and(|actor| {
    let snap = actor.snapshot();
    is_passive_rollout_session(
      snap.provider,
      snap.codex_integration_mode,
      snap.transcript_path.is_some(),
    )
  });

  let canceled_shells = state.shell_service().cancel_session(session_id);

  if !is_passive_rollout {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
      let _ = tx.send(CodexAction::EndSession).await;
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx.send(ClaudeAction::EndSession).await;
    }
  }

  let _ = state
    .persist()
    .send(PersistCommand::SessionEnd {
      id: session_id.to_string(),
      reason: "user_requested".to_string(),
    })
    .await;

  if is_passive_rollout {
    if let Some(actor) = actor {
      actor.send(SessionCommand::EndLocally).await;
    }
    state.broadcast_to_list(ServerMessage::SessionEnded {
      session_id: session_id.to_string(),
      reason: "user_requested".to_string(),
    });
  } else if state.remove_session(session_id).is_some() {
    state.broadcast_to_list(ServerMessage::SessionEnded {
      session_id: session_id.to_string(),
      reason: "user_requested".to_string(),
    });
  }

  canceled_shells
}

pub(crate) async fn send_continuation_message(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  content: &str,
) -> bool {
  if let Some(tx) = state.get_claude_action_tx(session_id) {
    tx.send(ClaudeAction::SendMessage {
      content: content.to_string(),
      model: None,
      effort: None,
      images: vec![],
    })
    .await
    .is_ok()
  } else {
    false
  }
}

/// When a session with a mission_id is resumed, update the linked mission issue
/// back to `running` so mission control reflects reality.
pub(crate) async fn sync_mission_issue_on_resume(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  mission_id: &str,
) {
  let now = chrono::Utc::now().to_rfc3339();

  // Find the mission issue linked to this session_id
  let db_path = state.db_path().clone();
  let sid = session_id.to_string();
  let mid = mission_id.to_string();
  let issue_id = tokio::task::spawn_blocking(move || {
    let conn = rusqlite::Connection::open(&db_path).ok()?;
    let mut stmt = conn
      .prepare(
        "SELECT issue_id FROM mission_issues \
                 WHERE mission_id = ?1 AND session_id = ?2 \
                 LIMIT 1",
      )
      .ok()?;
    stmt
      .query_row(rusqlite::params![mid, sid], |row| row.get::<_, String>(0))
      .ok()
  })
  .await
  .ok()
  .flatten();

  let Some(issue_id) = issue_id else {
    tracing::debug!(
        component = "mission_control",
        event = "resume_hook.no_linked_issue",
        session_id = %session_id,
        mission_id = %mission_id,
        "No mission issue linked to resumed session"
    );
    return;
  };

  // Update the issue back to running
  let _ = state
    .persist()
    .send(PersistCommand::MissionIssueUpdateState {
      mission_id: mission_id.to_string(),
      issue_id: issue_id.clone(),
      orchestration_state: "running".to_string(),
      session_id: Some(session_id.to_string()),
      attempt: None,
      last_error: Some(None), // clear error
      retry_due_at: None,
      started_at: Some(Some(now)),
      completed_at: Some(None), // clear completed_at
    })
    .await;

  // Broadcast updated mission state
  crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id(state, mission_id).await;

  tracing::info!(
      component = "mission_control",
      event = "resume_hook.issue_reactivated",
      session_id = %session_id,
      mission_id = %mission_id,
      issue_id = %issue_id,
      "Reactivated mission issue on session resume"
  );
}

pub(crate) async fn end_failed_direct_session(state: &Arc<SessionRegistry>, session_id: &str) {
  let _ = state
    .persist()
    .send(PersistCommand::SessionEnd {
      id: session_id.to_string(),
      reason: "connector_failed".to_string(),
    })
    .await;
  state.broadcast_to_list(ServerMessage::SessionEnded {
    session_id: session_id.to_string(),
    reason: "connector_failed".into(),
  });
}
