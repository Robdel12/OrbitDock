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
    approval_policy,
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
      overrides.approval_policy = value.clone();
    }
    if let Some(value) = approval_policy_details.clone() {
      overrides.approval_policy_details = value;
      if let Some(ref details) = overrides.approval_policy_details {
        overrides.approval_policy = Some(details.legacy_summary());
      }
    }
    if let Some(ref value) = sandbox_mode {
      overrides.sandbox_mode = value.clone();
    }
    if let Some(value) = sandbox_policy_details.clone() {
      overrides.sandbox_policy_details = value;
      if let Some(ref details) = overrides.sandbox_policy_details {
        overrides.sandbox_mode = Some(details.legacy_summary());
      }
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

  // Keep legacy compatibility in sync when canonical sandbox details are updated.
  if let Some(ref details) = sandbox_policy_details {
    sandbox_mode = Some(details.as_ref().map(CodexSandboxPolicy::legacy_summary));
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
mod tests {
  use std::fs;
  use std::sync::Arc;

  use orbitdock_protocol::{
    conversation_contracts::ConversationRow, CodexIntegrationMode, CodexSandboxPolicy, Provider,
    ServerMessage, SessionStatus, StateChanges, WorkStatus,
  };
  use tokio::sync::{mpsc, oneshot};
  use tokio::time::{timeout, Duration};

  use super::{
    config_notices, end_session, plan_snapshots, update_session_config, SessionConfigUpdate,
  };
  use crate::domain::sessions::session::SessionHandle;
  use crate::runtime::session_commands::{SessionCommand, SubscribeResult};
  use crate::runtime::session_registry::SessionRegistry;
  use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};

  fn count_settings_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Session settings updated"
        )
      })
      .count()
  }

  fn count_plan_snapshot_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Plan snapshot saved"
        )
      })
      .count()
  }

  fn count_plan_context_restored_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Plan context restored"
        )
      })
      .count()
  }

  #[tokio::test]
  async fn ending_direct_session_emits_local_ended_delta_before_removal() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(32);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    let session_id = "direct-end-test";
    let mut handle = SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/direct-end-test".to_string(),
    );
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    handle.set_status(SessionStatus::Active);
    handle.set_work_status(WorkStatus::Waiting);
    handle.refresh_snapshot();

    let actor = state.add_session(handle);

    let (reply_tx, reply_rx) = oneshot::channel();
    actor
      .send(SessionCommand::Subscribe {
        since_revision: None,
        reply: reply_tx,
      })
      .await;
    let mut rx = match reply_rx.await.expect("subscribe response should arrive") {
      SubscribeResult::Replay { rx, .. } | SubscribeResult::ResyncRequired { rx } => rx,
    };

    let _ = end_session(&state, session_id).await;

    let msg = timeout(Duration::from_secs(2), rx.recv())
      .await
      .expect("session should emit a local ended delta before teardown")
      .expect("session delta channel should remain open");

    match msg {
      ServerMessage::SessionDelta { changes, .. } => {
        assert_eq!(changes.status, Some(SessionStatus::Ended));
        assert_eq!(changes.work_status, Some(WorkStatus::Ended));
      }
      other => panic!("expected SessionDelta with ended state, got {other:?}"),
    }

    assert!(
      state.get_session(session_id).is_none(),
      "direct session should be removed from runtime after local ended delta"
    );
  }

  #[tokio::test]
  async fn update_session_config_updates_runtime_snapshot_before_handler_returns() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-runtime";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-runtime".to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("opus-4.1".to_string())),
        effort: Some(Some("high".to_string())),
        permission_mode: Some(Some("full".to_string())),
        collaboration_mode: Some(Some("enabled".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("control deck config update should succeed");

    let snapshot = state
      .get_session(session_id)
      .expect("session still exists after config update")
      .summary()
      .await
      .expect("summary command should be answered");

    assert_eq!(snapshot.model.as_deref(), Some("opus-4.1"));
    assert_eq!(snapshot.effort.as_deref(), Some("high"));
    assert_eq!(snapshot.permission_mode.as_deref(), Some("full"));
    assert_eq!(snapshot.collaboration_mode.as_deref(), Some("enabled"));
  }

  #[tokio::test]
  async fn update_session_config_syncs_legacy_sandbox_mode_from_details_only() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-sandbox-compat";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/control-deck-sandbox-compat".to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        sandbox_policy_details: Some(CodexSandboxPolicy::from_storage_text(
          "workspace-write-network",
        )),
        ..Default::default()
      },
    )
    .await
    .expect("sandbox details update should succeed");

    let summary = state
      .get_session(session_id)
      .expect("session still exists after config update")
      .summary()
      .await
      .expect("summary command should be answered");

    assert_eq!(
      summary.sandbox_mode.as_deref(),
      Some("workspace-write-network")
    );
    assert_eq!(
      summary
        .sandbox_policy_details
        .as_ref()
        .map(CodexSandboxPolicy::legacy_summary)
        .as_deref(),
      Some("workspace-write-network")
    );
  }

  #[tokio::test]
  async fn update_codex_session_model_mid_session() {
    let state = new_test_session_registry(true);
    let session_id = "codex-model-switch";

    let mut handle = SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/codex-model-switch".to_string(),
    );
    handle.set_model(Some("gpt-5-codex".to_string()));
    handle.refresh_snapshot();
    state.add_session(handle);

    let result = update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("gpt-5-codex-mini".to_string())),
        ..Default::default()
      },
    )
    .await;

    match &result {
      Ok(()) => {}
      Err(e) => eprintln!("update_session_config failed: {:?}", e),
    }
    result.expect("codex model switch should succeed");

    let snapshot = state
      .get_session(session_id)
      .expect("session still exists after config update")
      .summary()
      .await
      .expect("summary command should be answered");

    assert_eq!(snapshot.model.as_deref(), Some("gpt-5-codex-mini"));
  }

  #[tokio::test]
  async fn update_session_config_emits_notice_row_for_effective_changes() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-row";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-row".to_string(),
    ));

    let actor = state
      .get_session(session_id)
      .expect("session should exist before config update");
    let before = actor
      .summary()
      .await
      .expect("summary should be available before update");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("control deck config update should succeed");

    let actor = state
      .get_session(session_id)
      .expect("session still exists after config update");
    let after = actor
      .summary()
      .await
      .expect("summary should be available after update");
    assert_ne!(
      before.model, after.model,
      "test requires an actual model change to validate notice-row behavior"
    );
    assert_eq!(after.model.as_deref(), Some("row-test-model"));

    let page = actor
      .conversation_page(None, 50)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_settings_notice_rows(&page.rows),
      1,
      "one settings notice row should be appended"
    );
    let row = page
      .rows
      .first()
      .expect("notice row should be present after config update");

    let ConversationRow::Notice(notice) = &row.row else {
      panic!("expected notice row for config change, got {:?}", row.row);
    };

    assert_eq!(notice.title, "Session settings updated");
    let summary = notice
      .summary
      .as_deref()
      .expect("summary should describe changed settings");
    assert!(summary.contains("Model:"));
    assert!(summary.contains("row-test-model"));
    assert!(
      notice.body.is_none(),
      "single-change settings notice should not duplicate summary in body"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_notice_row_when_values_do_not_change() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-noop-row";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-noop-row".to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("initial config update should succeed");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("second config update should succeed");

    let page = state
      .get_session(session_id)
      .expect("session should still exist")
      .conversation_page(None, 50)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_settings_notice_rows(&page.rows),
      1,
      "no-op config update should not append an extra settings notice row"
    );
  }

  #[tokio::test]
  async fn update_session_config_saves_plan_snapshot_on_plan_mode_exit() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-exit-snapshot";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let actor = state
      .get_session(session_id)
      .expect("session should exist after entering plan mode");
    actor
      .send(SessionCommand::ApplyDelta {
        changes: Box::new(StateChanges {
          current_plan: Some(Some(
            "## Implementation Plan\n- [ ] Add a plan_write integration\n".to_string(),
          )),
          ..Default::default()
        }),
        persist_op: None,
      })
      .await;

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("default".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should exit plan mode");

    let plan_path = temp.path().join("plans/auto/plan-exit-snapshot.md");
    let content = fs::read_to_string(&plan_path).expect("plan snapshot should be written");
    assert!(content.contains("# Plan Snapshot"));
    assert!(content.contains("## Implementation Plan"));
    assert!(content.contains("collaboration mode exit"));

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_snapshot_notice_rows(&page.rows),
      1,
      "plan mode exit should emit exactly one plan snapshot notice row"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_plan_snapshot_on_plan_exit_without_plan() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-exit-no-plan";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("default".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should exit plan mode");

    assert!(
      !temp.path().join("plans/auto/plan-exit-no-plan.md").exists(),
      "no plan snapshot should be written when there is no current plan"
    );

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_snapshot_notice_rows(&page.rows),
      0,
      "no plan snapshot notice row should be emitted without a plan"
    );
  }

  #[tokio::test]
  async fn update_session_config_emits_plan_context_restored_notice_on_plan_reentry() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-context-restored";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    let actor = state
      .get_session(session_id)
      .expect("session should exist before update");
    actor
      .send(SessionCommand::ApplyDelta {
        changes: Box::new(StateChanges {
          current_plan: Some(Some(
            "## Existing Plan\n- [ ] Keep iterating in plan mode\n".to_string(),
          )),
          ..Default::default()
        }),
        persist_op: None,
      })
      .await;

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_context_restored_notice_rows(&page.rows),
      1,
      "entering plan mode with an existing plan should emit a re-entry reminder row"
    );

    let restored_notice = page
      .rows
      .iter()
      .find_map(|entry| match &entry.row {
        ConversationRow::Notice(notice) if notice.title == "Plan context restored" => Some(notice),
        _ => None,
      })
      .expect("plan context restored notice should exist");
    assert!(
      restored_notice
        .summary
        .as_deref()
        .is_some_and(|summary| summary.contains("plans/auto/plan-context-restored.md")),
      "re-entry notice should include the auto-save path"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_plan_context_restored_notice_without_existing_plan() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-context-no-existing-plan";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_context_restored_notice_rows(&page.rows),
      0,
      "entering plan mode without a prior plan should not emit a re-entry reminder row"
    );
  }
}
