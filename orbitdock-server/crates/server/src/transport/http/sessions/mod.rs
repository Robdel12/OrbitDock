use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

mod common;
mod conversation;
mod detail;
mod review;
mod row_content;
mod summary;
mod usage;

pub use conversation::{
  get_conversation_history, get_conversation_snapshot, get_session_stats, mark_session_read,
  search_conversation_rows,
};
pub use detail::get_session_detail;
pub use review::get_session_review;
pub use row_content::get_row_content;
pub use summary::{
  get_active_sessions_snapshot, get_archived_sessions_snapshot, get_sessions_summary,
};
pub use usage::get_session_usage_turns;

const DEFAULT_CONVERSATION_PAGE_SIZE: usize = 50;
const MAX_CONVERSATION_PAGE_SIZE: usize = 200;
const DEFAULT_LIBRARY_PAGE_SIZE: usize = 200;
const MAX_LIBRARY_PAGE_SIZE: usize = 500;
const MAX_RECENT_INACTIVE_WORKERS: usize = 4;

#[derive(Debug, Deserialize, Default)]
pub struct ConversationPageQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub before_sequence: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SessionSnapshotQuery {
  #[serde(default)]
  pub include_messages: bool,
  #[serde(default)]
  pub include_diffs: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct LibrarySnapshotQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub offset: Option<usize>,
  #[serde(default)]
  pub q: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct MarkReadResponse {
  pub session_id: String,
  pub unread_count: u64,
}

#[derive(Debug, Deserialize, Default)]
pub struct ConversationSearchQuery {
  #[serde(default)]
  pub q: Option<String>,
  #[serde(default)]
  pub family: Option<String>,
  #[serde(default)]
  pub status: Option<String>,
  #[serde(default)]
  pub kind: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SessionUsageTurnsQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub before_turn_seq: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct SessionStatsResponse {
  pub session_id: String,
  pub total_rows: u64,
  pub tool_count: u64,
  pub tool_count_by_family: BTreeMap<String, u64>,
  pub failed_tool_count: u64,
  pub average_tool_duration_ms: u64,
  pub turn_count: u64,
  pub total_tokens: orbitdock_protocol::TokenUsage,
  pub worker_count: u32,
  pub duration_ms: u64,
}

#[derive(Debug, Serialize)]
pub struct RowContentResponse {
  pub row_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub input_display: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub output_display: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub images: Vec<orbitdock_protocol::ImageInput>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub diff_display: Option<Vec<orbitdock_protocol::conversation_contracts::DiffLine>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub language: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_line: Option<u32>,
}

#[cfg(test)]
mod tests;
