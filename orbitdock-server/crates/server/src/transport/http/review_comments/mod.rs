use orbitdock_protocol::{ReviewComment, ReviewCommentStatus, ReviewCommentTag};
use serde::{Deserialize, Serialize};

mod handlers;
mod support;

pub use handlers::{
  create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
  update_review_comment,
};

#[derive(Debug, Serialize)]
pub struct ReviewCommentsResponse {
  pub session_id: String,
  pub review_revision: u64,
  pub comments: Vec<ReviewComment>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ReviewCommentsQuery {
  #[serde(default)]
  pub turn_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateReviewCommentRequest {
  pub turn_id: Option<String>,
  pub file_path: String,
  pub line_start: u32,
  pub line_end: Option<u32>,
  pub body: String,
  #[serde(default)]
  pub tag: Option<ReviewCommentTag>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateReviewCommentRequest {
  #[serde(default)]
  pub body: Option<String>,
  #[serde(default)]
  pub tag: Option<ReviewCommentTag>,
  #[serde(default)]
  pub status: Option<ReviewCommentStatus>,
}

#[derive(Debug, Serialize)]
pub struct ReviewCommentMutationResponse {
  pub session_id: String,
  pub review_revision: u64,
  pub comment_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub comment: Option<ReviewComment>,
  pub deleted: bool,
  pub ok: bool,
}

#[cfg(test)]
mod tests;
