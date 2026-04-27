use super::*;
use crate::domain::sessions::session::SessionHandle;
use orbitdock_protocol::{
  CodexIntegrationMode, SessionLifecycleState, SessionStatus, StateChanges,
};

#[tokio::test]
async fn resume_session_returns_ok_when_runtime_session_is_already_active() {
  let _guard = crate::support::test_support::test_env_lock().lock().await;
  let _db_path = crate::transport::http::test_support::ensure_test_db();
  let state = crate::support::test_support::new_test_session_registry(true);
  let session_id = orbitdock_protocol::new_session_id();
  state.add_session(SessionHandle::new(
    session_id.clone(),
    orbitdock_protocol::Provider::Codex,
    "/tmp/orbitdock-resume-idempotent".to_string(),
  ));

  let Json(response) = resume_session(Path(session_id.clone()), State(state))
    .await
    .expect("resume should return active runtime summary");

  assert_eq!(response.session_id, session_id);
  assert_eq!(response.session.id, response.session_id);
  assert_eq!(response.session.status, SessionStatus::Active);
}

#[tokio::test]
async fn resume_session_falls_back_to_persisted_resume_when_direct_runtime_is_not_ready() {
  let _guard = crate::support::test_support::test_env_lock().lock().await;
  let _db_path = crate::transport::http::test_support::ensure_test_db();
  let state = crate::support::test_support::new_test_session_registry(true);
  let session_id = orbitdock_protocol::new_session_id();
  let mut handle = SessionHandle::new(
    session_id.clone(),
    orbitdock_protocol::Provider::Codex,
    "/tmp/orbitdock-resume-not-ready".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  handle.apply_changes(&StateChanges {
    lifecycle_state: Some(SessionLifecycleState::Resumable),
    ..Default::default()
  });
  state.add_session(handle);

  let (status, Json(error)) = resume_session(Path(session_id), State(state))
    .await
    .expect_err("non-ready direct runtime should not short-circuit resume");

  assert_eq!(status, StatusCode::NOT_FOUND);
  assert_eq!(error.code, "not_found");
}
