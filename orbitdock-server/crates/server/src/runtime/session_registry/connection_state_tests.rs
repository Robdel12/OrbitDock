use super::ConnectionState;

#[test]
fn orchestrator_first_start_succeeds() {
  let state = ConnectionState::new(true);
  assert!(!state.is_orchestrator_running());
  assert!(state.try_start_orchestrator());
  assert!(state.is_orchestrator_running());
}

#[test]
fn orchestrator_second_start_rejected() {
  let state = ConnectionState::new(true);
  assert!(state.try_start_orchestrator());
  assert!(!state.try_start_orchestrator());
}

#[test]
fn orchestrator_can_restart_after_stop() {
  let state = ConnectionState::new(true);
  assert!(state.try_start_orchestrator());
  state.stop_orchestrator();
  assert!(!state.is_orchestrator_running());
  assert!(state.try_start_orchestrator());
}

#[test]
fn active_primary_claims_dedup_by_client_and_ignore_non_primary() {
  let state = ConnectionState::new(true);
  state.set_client_primary_claim(
    1,
    String::from("client-a"),
    String::from("MacBook Pro"),
    true,
  );
  state.set_client_primary_claim(2, String::from("client-a"), String::from("iPhone"), true);
  state.set_client_primary_claim(3, String::from("client-b"), String::from("Studio"), false);

  let claims = state.active_client_primary_claims();

  assert_eq!(claims.len(), 1);
  assert_eq!(claims[0].client_id, "client-a");
  assert_eq!(claims[0].device_name, "MacBook Pro");
}
