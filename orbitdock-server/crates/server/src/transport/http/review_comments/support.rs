use axum::{http::StatusCode, Json};
use orbitdock_protocol::{ReviewComment, ReviewCommentStatus, ReviewCommentTag};

use crate::infrastructure::persistence::load_review_comment_by_id;
use crate::transport::http::ApiErrorResponse;

pub async fn load_existing_comment(
  comment_id: &str,
) -> Result<ReviewComment, (StatusCode, Json<ApiErrorResponse>)> {
  let existing = load_review_comment_by_id(comment_id).await.map_err(|err| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "review_comment_load_failed",
        error: err.to_string(),
      }),
    )
  })?;

  existing.ok_or_else(|| {
    (
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "review_comment_not_found",
        error: format!("review comment {comment_id} not found"),
      }),
    )
  })
}

pub fn serialize_review_comment_tag(tag: ReviewCommentTag) -> String {
  match tag {
    ReviewCommentTag::Clarity => "clarity",
    ReviewCommentTag::Scope => "scope",
    ReviewCommentTag::Risk => "risk",
    ReviewCommentTag::Nit => "nit",
  }
  .to_string()
}

pub fn serialize_review_comment_status(status: ReviewCommentStatus) -> String {
  match status {
    ReviewCommentStatus::Open => "open",
    ReviewCommentStatus::Resolved => "resolved",
  }
  .to_string()
}

pub fn review_comment_id(session_id: &str, millis: u128) -> String {
  format!("rc-{}-{millis}", &session_id[..8.min(session_id.len())])
}
