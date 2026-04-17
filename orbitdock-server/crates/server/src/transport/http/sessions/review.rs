use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::SessionReviewSnapshot;

use crate::{
  infrastructure::persistence::list_review_comments,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::common::map_session_load_error;

pub async fn get_session_review(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionReviewSnapshot> {
  let session = load_full_session_state(&state, &session_id, false, true)
    .await
    .map_err(|error| map_session_load_error(&session_id, error))?;

  let comments = list_review_comments(&session_id, None)
    .await
    .map_err(|err| {
      (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiErrorResponse {
          code: "db_error",
          error: err.to_string(),
        }),
      )
    })?;

  Ok(Json(SessionReviewSnapshot {
    session_id,
    revision: session.revision.unwrap_or_default(),
    current_diff: session.current_diff,
    cumulative_diff: session.cumulative_diff,
    turn_diffs: session.turn_diffs,
    comments,
  }))
}
