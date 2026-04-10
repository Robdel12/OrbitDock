use axum::{http::StatusCode, Json};

use super::super::errors::{conflict, internal, unprocessable, ApiErrorResponse};
use crate::runtime::session_mutations::SessionMutationError;
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
