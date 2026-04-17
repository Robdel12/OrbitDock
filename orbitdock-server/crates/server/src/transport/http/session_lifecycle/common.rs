use std::sync::Arc;

use axum::{http::StatusCode, Json};
use orbitdock_protocol::SessionDetailSnapshot;

use super::super::errors::{conflict, internal, unprocessable, ApiErrorResponse};
use super::super::AcceptedResponse;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_mutations::SessionMutationError;
use crate::runtime::session_queries::{load_full_session_state, SessionLoadError};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_resume::ResumeSessionError;
use crate::runtime::session_takeover::TakeoverSessionError;

pub(super) fn resolve_developer_instructions(
  developer_instructions: Option<String>,
  system_prompt: Option<String>,
  append_system_prompt: Option<String>,
) -> Option<String> {
  if developer_instructions.is_some() {
    return developer_instructions;
  }

  match (
    system_prompt.filter(|value| !value.trim().is_empty()),
    append_system_prompt.filter(|value| !value.trim().is_empty()),
  ) {
    (Some(base), Some(append)) => Some(format!("{base}\n\n{append}")),
    (Some(base), None) => Some(base),
    (None, Some(append)) => Some(append),
    (None, None) => None,
  }
}

pub(super) fn lifecycle_error(
  status: StatusCode,
  code: &'static str,
  error: impl Into<String>,
) -> (StatusCode, Json<ApiErrorResponse>) {
  super::super::errors::api_error(status, code, error)
}

pub(super) fn map_resume_error(error: ResumeSessionError) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    ResumeSessionError::MissingClaudeResumeId => unprocessable(error.code(), error.message()),
  }
}

pub(super) fn map_takeover_error(
  error: TakeoverSessionError,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    TakeoverSessionError::NotFound(_) => {
      super::super::errors::api_error(StatusCode::NOT_FOUND, error.code(), error.message())
    }
    TakeoverSessionError::NotPassive(_) => conflict(error.code(), error.message()),
    TakeoverSessionError::TakeHandleFailed => internal(error.code(), error.message()),
    TakeoverSessionError::ConnectorFailed(_) => internal(error.code(), error.message()),
  }
}

pub(super) fn map_session_mutation_error(
  error: SessionMutationError,
) -> (StatusCode, Json<ApiErrorResponse>) {
  match error {
    SessionMutationError::NotFound(_) => {
      super::super::errors::api_error(StatusCode::NOT_FOUND, error.code(), error.message())
    }
    SessionMutationError::InvalidCodexConfig(_) => unprocessable(error.code(), error.message()),
  }
}

pub(super) async fn flush_persistence(state: &Arc<SessionRegistry>) {
  let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
  if state
    .persist()
    .send(PersistCommand::Flush { ack: ack_tx })
    .await
    .is_ok()
  {
    let _ = ack_rx.await;
  }
}

pub(super) async fn load_session_detail_snapshot(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Option<SessionDetailSnapshot> {
  match load_full_session_state(state, session_id, false, false).await {
    Ok(session) => Some(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    }),
    Err(SessionLoadError::NotFound | SessionLoadError::Db(_) | SessionLoadError::Runtime(_)) => {
      None
    }
  }
}

pub(super) async fn accepted_response(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Json<AcceptedResponse> {
  flush_persistence(state).await;
  Json(AcceptedResponse {
    accepted: true,
    session_detail_snapshot: load_session_detail_snapshot(state, session_id).await,
  })
}
