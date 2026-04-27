use std::sync::Arc;

use orbitdock_protocol::{
  CodexApprovalPolicy, CodexApprovalsReviewer, CodexConfigMode, CodexSandboxPolicy,
};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::runtime::codex_config::serialize_codex_overrides;
use crate::runtime::session_commands::{PersistOp, SessionCommand, SessionConfigPersist};
use crate::runtime::session_registry::SessionRegistry;

pub(crate) mod config_notices;
pub(crate) mod plan_snapshots;
pub(crate) mod session_lifecycle;
pub(crate) use session_lifecycle::{
  end_failed_direct_session, end_session, send_continuation_message, sync_mission_issue_on_resume,
};

#[derive(Debug)]
pub(crate) enum SessionMutationError {
  NotFound(String),
  InvalidCodexConfig(String),
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionConfigUpdate {
  pub approval_policy: Option<Option<String>>,
  pub approval_policy_details: Option<Option<CodexApprovalPolicy>>,
  pub sandbox_mode: Option<Option<String>>,
  pub sandbox_policy_details: Option<Option<CodexSandboxPolicy>>,
  pub approvals_reviewer: Option<Option<CodexApprovalsReviewer>>,
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

  let (reply_tx, _reply_rx) = tokio::sync::oneshot::channel();
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

  actor
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::SummaryUpdated(summary),
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
    sandbox_policy_details,
    approvals_reviewer,
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
    mut approval_policy,
    approval_policy_details,
    mut sandbox_mode,
    sandbox_policy_details,
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
    // Mid-session config changes go straight to the connector via
    // OverrideTurnContext — no app-server or config re-resolution needed.
    let mut overrides = current_summary
      .codex_config_overrides
      .clone()
      .unwrap_or_default();
    if let Some(ref value) = model {
      overrides.model = value.clone();
    }
    if let Some(ref value) = approval_policy {
      overrides.approval_policy_details = value
        .as_deref()
        .and_then(CodexApprovalPolicy::from_storage_text);
    }
    if let Some(value) = approval_policy_details.clone() {
      overrides.approval_policy_details = value;
    }
    if let Some(ref value) = sandbox_mode {
      overrides.sandbox_policy_details = value
        .as_deref()
        .and_then(CodexSandboxPolicy::from_storage_text);
    }
    if let Some(value) = sandbox_policy_details.clone() {
      overrides.sandbox_policy_details = value;
    }
    if let Some(value) = approvals_reviewer {
      overrides.approvals_reviewer = value;
    }
    if let Some(ref value) = collaboration_mode {
      overrides.collaboration_mode = value.clone();
    }
    if let Some(value) = multi_agent {
      overrides.multi_agent = value;
    }
    if let Some(ref value) = personality {
      overrides.personality = value.clone();
    }
    if let Some(ref value) = service_tier {
      overrides.service_tier = value.clone();
    }
    if let Some(ref value) = developer_instructions {
      overrides.developer_instructions = value.clone();
    }
    if let Some(ref value) = effort {
      overrides.effort = value.clone();
    }
    if let Some(value) = codex_model_provider.clone() {
      overrides.model_provider = value;
    }

    (
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      sandbox_policy_details,
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
      Some(overrides),
    )
  } else {
    (
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      sandbox_policy_details,
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

  // Keep compact summaries in sync when canonical policy details are updated.
  if let Some(ref details) = approval_policy_details {
    approval_policy = Some(details.as_ref().map(CodexApprovalPolicy::storage_text));
  }
  if let Some(ref details) = sandbox_policy_details {
    sandbox_mode = Some(details.as_ref().map(CodexSandboxPolicy::summary_text));
  }

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();

  let send_result = actor
    .send_checked(SessionCommand::ApplyDeltaAndWait {
      changes: Box::new(orbitdock_protocol::StateChanges {
        approval_policy: approval_policy.clone(),
        approval_policy_details: approval_policy_details.clone(),
        sandbox_mode: sandbox_mode.clone(),
        sandbox_policy_details: sandbox_policy_details.clone(),
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
      reply: reply_tx,
    })
    .await;

  if send_result.is_err() {
    return Err(SessionMutationError::NotFound(session_id.to_string()));
  }

  if reply_rx.await.is_err() {
    return Err(SessionMutationError::NotFound(session_id.to_string()));
  }

  let updated_snapshot = actor.snapshot();
  let updated_summary = actor
    .summary()
    .await
    .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;

  if let Some(entry) = config_notices::build_session_config_change_notice_row(
    session_id,
    &current_summary,
    &updated_summary,
  ) {
    let row_id = entry.id().to_string();
    actor
      .send_checked(SessionCommand::AddRowAndBroadcast { entry })
      .await
      .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
    tracing::info!(
      component = "session",
      event = "session.config.notice_row_emitted",
      session_id = %session_id,
      row_id = %row_id,
      "Emitted session-config notice row"
    );
  }

  if let Some(result) = plan_snapshots::maybe_save_plan_on_collaboration_mode_exit(
    session_id,
    current_summary.collaboration_mode.as_deref(),
    updated_summary.collaboration_mode.as_deref(),
    updated_snapshot.as_ref(),
  ) {
    match result {
      Ok(saved) => {
        let entry =
          plan_snapshots::build_plan_snapshot_saved_notice_row(session_id, &saved.relative_path);
        let row_id = entry.id().to_string();
        actor
          .send_checked(SessionCommand::AddRowAndBroadcast { entry })
          .await
          .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
        tracing::info!(
          component = "session",
          event = "session.plan_snapshot.saved",
          session_id = %session_id,
          row_id = %row_id,
          path = %saved.path,
          "Saved latest plan snapshot after collaboration mode exit"
        );
      }
      Err(error) => {
        let entry = plan_snapshots::build_plan_snapshot_failed_notice_row(session_id, &error);
        let row_id = entry.id().to_string();
        actor
          .send_checked(SessionCommand::AddRowAndBroadcast { entry })
          .await
          .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
        tracing::warn!(
          component = "session",
          event = "session.plan_snapshot.save_failed",
          session_id = %session_id,
          row_id = %row_id,
          error = %error,
          "Failed to save latest plan snapshot after collaboration mode exit"
        );
      }
    }
  }

  if let Some(entry) = plan_snapshots::maybe_build_plan_reentry_notice_row(
    session_id,
    current_summary.collaboration_mode.as_deref(),
    updated_summary.collaboration_mode.as_deref(),
    updated_snapshot.as_ref(),
  ) {
    let row_id = entry.id().to_string();
    actor
      .send_checked(SessionCommand::AddRowAndBroadcast { entry })
      .await
      .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
    tracing::info!(
      component = "session",
      event = "session.plan_context.restored",
      session_id = %session_id,
      row_id = %row_id,
      "Emitted plan re-entry reminder row"
    );
  }

  crate::runtime::session_registry::flush_and_publish_conversation(
    state.persist(),
    state,
    session_id,
  )
  .await;

  if let Some(Some(ref mode)) = permission_mode {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx
        .send(ClaudeAction::SetPermissionMode { mode: mode.clone() })
        .await;
    }
  }

  if let Some(Some(ref model_value)) = model {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx
        .send(ClaudeAction::SetModel {
          model: model_value.clone(),
        })
        .await;
    }
  }

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx
      .send(CodexAction::UpdateConfig {
        approval_policy: approval_policy.flatten(),
        approval_policy_details: approval_policy_details.flatten(),
        sandbox_mode: sandbox_mode.flatten(),
        sandbox_policy_details: sandbox_policy_details.flatten(),
        approvals_reviewer: approvals_reviewer
          .flatten()
          .map(|value| value.as_str().to_string()),
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

#[cfg(test)]
#[path = "session_mutations_tests.rs"]
mod session_mutations_tests;
