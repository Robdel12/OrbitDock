use tokio::sync::mpsc;

use orbitdock_protocol::{
  CodexConfigMode, CodexIntegrationMode, Provider, SessionLifecycleState, SessionStatus,
  StateChanges, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::support::test_support::new_test_session_registry;

use super::*;

#[tokio::test]
async fn failed_send_does_not_create_a_ghost_accepted_row() {
  let state = new_test_session_registry(true);
  let session_id = "session-ghost-row";
  let mut handle = SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/orbitdock-test".to_string(),
  );
  handle.apply_changes(&StateChanges {
    status: Some(SessionStatus::Active),
    work_status: Some(WorkStatus::Waiting),
    lifecycle_state: Some(SessionLifecycleState::Open),
    codex_integration_mode: Some(Some(CodexIntegrationMode::Direct)),
    ..Default::default()
  });
  state.add_session(handle);

  let (action_tx, action_rx) = mpsc::channel(1);
  drop(action_rx);
  state.set_codex_action_tx(session_id, action_tx);

  let result = dispatch_send_message(
    &state,
    DispatchSendMessage {
      session_id: session_id.to_string(),
      content: "hello world".to_string(),
      model: None,
      effort: None,
      skills: vec![],
      images: vec![],
      mentions: vec![],
      message_id: "message-1".to_string(),
    },
  )
  .await;

  assert!(matches!(
    result,
    Err(DispatchMessageError::ConnectorUnavailable)
  ));

  let actor = state.get_session(session_id).expect("session actor");
  let retained_state = actor.retained_state().await.expect("retained state");
  assert_eq!(retained_state.total_row_count, 0);
  let snapshot = actor.snapshot();
  assert_eq!(snapshot.first_prompt.as_deref(), None);
  assert!(state.get_codex_action_tx(session_id).is_none());
}

#[tokio::test]
async fn steer_rejects_idle_sessions_without_creating_a_fallback_row() {
  let state = new_test_session_registry(true);
  let session_id = "session-idle-steer";
  let mut handle = SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/orbitdock-test".to_string(),
  );
  handle.apply_changes(&StateChanges {
    status: Some(SessionStatus::Active),
    work_status: Some(WorkStatus::Waiting),
    lifecycle_state: Some(SessionLifecycleState::Open),
    codex_integration_mode: Some(Some(CodexIntegrationMode::Direct)),
    steerable: Some(false),
    ..Default::default()
  });
  state.add_session(handle);

  let (action_tx, mut action_rx) = mpsc::channel(1);
  state.set_codex_action_tx(session_id, action_tx);

  let result = dispatch_steer_turn(
    &state,
    session_id.to_string(),
    "this should be a new turn".to_string(),
    vec![],
    vec![],
    "steer-1".to_string(),
  )
  .await;

  assert!(matches!(result, Err(DispatchMessageError::NotSteerable)));
  assert!(action_rx.try_recv().is_err());

  let actor = state.get_session(session_id).expect("session actor");
  let retained_state = actor.retained_state().await.expect("retained state");
  assert_eq!(retained_state.total_row_count, 0);
}

#[tokio::test]
async fn stop_active_turn_reports_connector_unavailable_when_session_exists_without_connector() {
  let state = new_test_session_registry(true);
  let session_id = "session-no-connector";
  state.add_session(SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/orbitdock-test".to_string(),
  ));

  let result = dispatch_stop_active_turn(&state, session_id).await;
  assert_eq!(result, Err("connector_unavailable"));
}

#[tokio::test]
async fn stop_active_turn_reports_session_not_found_when_actor_is_missing() {
  let state = new_test_session_registry(true);
  let result = dispatch_stop_active_turn(&state, "missing-session").await;
  assert_eq!(result, Err("session_not_found"));
}

#[test]
fn plan_send_message_ignores_codex_model_override_for_profile_sessions() {
  let plan = crate::runtime::message_dispatch_policy::plan_send_message(
    Provider::Codex,
    Some(CodexConfigMode::Profile),
    "hello world",
    Some("gpt-5.4".to_string()),
    Some("high".to_string()),
  );

  assert_eq!(plan.action_model, None);
  assert_eq!(plan.connector_effort.as_deref(), Some("high"));
  assert_eq!(plan.session_effort_update.as_deref(), Some("high"));
}

#[test]
fn plan_send_message_keeps_codex_model_override_for_custom_sessions() {
  let plan = crate::runtime::message_dispatch_policy::plan_send_message(
    Provider::Codex,
    Some(CodexConfigMode::Custom),
    "hello world",
    Some("qwen/qwen3-coder-next".to_string()),
    Some("high".to_string()),
  );

  assert_eq!(plan.action_model.as_deref(), Some("qwen/qwen3-coder-next"));
}
