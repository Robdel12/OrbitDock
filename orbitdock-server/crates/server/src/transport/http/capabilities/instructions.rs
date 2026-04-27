use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};

use crate::{
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::{runtime::load_session_instructions, SessionInstructionsResponse};

pub async fn get_session_instructions(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionInstructionsResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| {
      (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("Session {} not found", session_id),
        }),
      )
    })?;

  let instructions = load_session_instructions(&session).await;

  Ok(Json(SessionInstructionsResponse {
    session_id,
    provider: session.provider,
    instructions,
  }))
}
