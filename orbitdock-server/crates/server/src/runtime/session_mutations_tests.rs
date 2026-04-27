use std::fs;
use std::sync::Arc;

use orbitdock_protocol::{
  conversation_contracts::ConversationRow, CodexIntegrationMode, CodexSandboxPolicy, Provider,
  ServerMessage, SessionStatus, StateChanges, WorkStatus,
};
use tokio::sync::{mpsc, oneshot};
use tokio::time::{timeout, Duration};

use super::{end_session, update_session_config, SessionConfigUpdate};
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
  let session_id = "session-detail-update-runtime";

  state.add_session(SessionHandle::new(
    session_id.to_string(),
    Provider::Claude,
    "/tmp/session-detail-update-runtime".to_string(),
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
  .expect("session config update should succeed");

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
async fn update_session_config_syncs_sandbox_summary_from_details_only() {
  let state = new_test_session_registry(true);
  let session_id = "session-detail-sandbox-summary";

  state.add_session(SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/session-detail-sandbox-summary".to_string(),
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
      .map(CodexSandboxPolicy::summary_text)
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
  let session_id = "session-detail-update-row";

  state.add_session(SessionHandle::new(
    session_id.to_string(),
    Provider::Claude,
    "/tmp/session-detail-update-row".to_string(),
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
  .expect("session config update should succeed");

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
  let session_id = "session-detail-update-noop-row";

  state.add_session(SessionHandle::new(
    session_id.to_string(),
    Provider::Claude,
    "/tmp/session-detail-update-noop-row".to_string(),
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
