use std::{sync::Arc, time::Duration};

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use serde::Serialize;

use super::super::errors::{internal, ApiErrorResponse};
use super::super::session_not_found_error;
use super::common::map_resume_error;
use crate::runtime::restored_sessions::load_prepared_resume_session;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_resume::launch_resumed_session;
use crate::runtime::session_runtime_helpers::verify_direct_runtime_ready_snapshot;

#[derive(Debug, Serialize)]
pub struct ResumeSessionResponse {
  pub session_id: String,
  pub session: orbitdock_protocol::SessionSummary,
}

pub async fn resume_session(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<ResumeSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  use orbitdock_protocol::{SessionControlMode, SessionLifecycleState, SessionStatus};

  if let Some(handle) = state.get_session(&session_id) {
    let snap = handle.snapshot();
    if snap.status == SessionStatus::Active {
      let requires_direct_relaunch = snap.control_mode == SessionControlMode::Direct
        && snap.lifecycle_state == SessionLifecycleState::Resumable;
      if requires_direct_relaunch {
        state.remove_session(&session_id);
      } else {
        let is_direct_runtime_ready = snap.control_mode != SessionControlMode::Direct
          || verify_direct_runtime_ready_snapshot(&state, &session_id, snap.provider).is_ok();

        if is_direct_runtime_ready {
          let summary = handle
            .summary()
            .await
            .map_err(|error| internal("runtime_error", error))?;

          if let Some(ref mission_id) = summary.mission_id {
            crate::runtime::session_mutations::sync_mission_issue_on_resume(
              &state,
              &session_id,
              mission_id,
            )
            .await;
          }

          return Ok(Json(ResumeSessionResponse {
            session_id,
            session: summary,
          }));
        }

        state.remove_session(&session_id);
      }
    } else {
      state.remove_session(&session_id);
    }
  }

  let prepared = match load_prepared_resume_session(&session_id).await {
    Ok(Some(prepared)) => prepared,
    Ok(None) => return Err(session_not_found_error(&session_id)),
    Err(error) => return Err(internal("db_error", error.to_string())),
  };

  let resume_mission_id = prepared.summary.mission_id.clone();
  let launch = launch_resumed_session(&state, &session_id, prepared)
    .await
    .map_err(map_resume_error)?;
  let mut summary = launch.summary;

  if let Some(startup_ready) = launch.startup_ready {
    let _ = tokio::time::timeout(Duration::from_secs(16), startup_ready).await;
    if let Some(handle) = state.get_session(&session_id) {
      if let Ok(fresh_summary) = handle.summary().await {
        summary = fresh_summary;
      }
    }
  }

  if let Some(ref mid) = resume_mission_id {
    crate::runtime::session_mutations::sync_mission_issue_on_resume(&state, &session_id, mid).await;
  }

  Ok(Json(ResumeSessionResponse {
    session_id,
    session: summary,
  }))
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::domain::sessions::session::SessionHandle;
  use orbitdock_protocol::{
    CodexIntegrationMode, SessionLifecycleState, SessionStatus, StateChanges,
  };

  #[tokio::test]
  async fn resume_session_returns_ok_when_runtime_session_is_already_active() {
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
}
