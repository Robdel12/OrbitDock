use serde::Serialize;

/// Tag for a review comment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCommentTag {
  Clarity,
  Scope,
  Risk,
  Nit,
}

/// Status of a review comment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCommentStatus {
  Open,
  Resolved,
}

/// A review comment on a diff line or range
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct ReviewComment {
  pub id: String,
  pub session_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub turn_id: Option<String>,
  pub file_path: String,
  pub line_start: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub line_end: Option<u32>,
  pub body: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub tag: Option<ReviewCommentTag>,
  pub status: ReviewCommentStatus,
  pub created_at: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub updated_at: Option<String>,
}
