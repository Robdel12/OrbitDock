use std::sync::Arc;

use orbitdock_protocol::{CodexIntegrationMode, Provider, StateChanges, WorkStatus};
use tokio::sync::mpsc;

use crate::domain::sessions::session::SessionHandle;
use crate::support::test_support::ensure_server_test_data_dir;

use super::{hydrate_ephemeral_state, load_light_session_state, SessionRegistry};

#[tokio::test]
async fn hydration_overlays_live_interrupt_affordance_for_detail_snapshots() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  let mut live_session = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-live".to_string(),
  );
  live_session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  live_session.apply_changes(&StateChanges {
    work_status: Some(WorkStatus::Working),
    steerable: Some(true),
    ..Default::default()
  });
  live_session.refresh_snapshot();

  let mut stale_snapshot = live_session.retained_state();
  stale_snapshot.accepts_user_input = false;
  stale_snapshot.steerable = false;
  stale_snapshot.connector_attached = false;
  stale_snapshot.can_interrupt = false;

  registry.add_session(live_session);
  let (action_tx, _action_rx) = mpsc::channel(8);
  registry.set_codex_action_tx("session-1", action_tx);
  hydrate_ephemeral_state(&mut stale_snapshot, &registry, "session-1").await;

  assert_eq!(stale_snapshot.work_status, WorkStatus::Working);
  assert!(stale_snapshot.connector_attached);
  assert!(stale_snapshot.accepts_user_input);
  assert!(stale_snapshot.steerable);
  assert!(stale_snapshot.can_interrupt);
}

#[tokio::test]
async fn hydration_disables_direct_input_affordances_without_live_connector() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  let mut live_session = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-live".to_string(),
  );
  live_session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  live_session.apply_changes(&StateChanges {
    work_status: Some(WorkStatus::Working),
    steerable: Some(true),
    ..Default::default()
  });
  live_session.refresh_snapshot();

  let mut snapshot = live_session.retained_state();
  registry.add_session(live_session);
  hydrate_ephemeral_state(&mut snapshot, &registry, "session-1").await;

  assert_eq!(snapshot.work_status, WorkStatus::Working);
  assert!(!snapshot.connector_attached);
  assert!(!snapshot.accepts_user_input);
  assert!(!snapshot.steerable);
  assert!(!snapshot.can_interrupt);
}

#[tokio::test]
async fn light_session_state_falls_back_to_live_actor_without_heavy_payloads() {
  ensure_server_test_data_dir();
  let (persist_tx, _persist_rx) = mpsc::channel(8);
  let registry = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  let mut live_session = SessionHandle::new(
    "session-1".to_string(),
    Provider::Codex,
    "/tmp/orbitdock-live".to_string(),
  );
  live_session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  live_session.apply_changes(&StateChanges {
    work_status: Some(WorkStatus::Working),
    steerable: Some(true),
    current_diff: Some(Some("diff --git a/heavy b/heavy".to_string())),
    ..Default::default()
  });
  live_session.refresh_snapshot();

  registry.add_session(live_session);
  let (action_tx, _action_rx) = mpsc::channel(8);
  registry.set_codex_action_tx("session-1", action_tx);

  let session = load_light_session_state(&registry, "session-1")
    .await
    .expect("live runtime session should be returned");

  assert_eq!(session.work_status, WorkStatus::Working);
  assert!(session.connector_attached);
  assert!(session.can_interrupt);
  assert!(session.current_diff.is_none());
  assert!(session.turn_diffs.is_empty());
  assert!(session.rows.is_empty());
}
