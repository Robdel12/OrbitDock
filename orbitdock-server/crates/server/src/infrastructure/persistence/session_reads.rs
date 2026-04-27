mod ownership_reads;
mod session_hydration;
mod startup_recovery;

use rusqlite::{params, Connection};

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
  CodexConfigMode, CodexConfigSource, CodexSessionOverrides, SessionControlMode,
  SessionLifecycleState, SessionStatus, TokenUsageSnapshotKind,
};

pub(crate) use ownership_reads::{
  load_direct_claude_owner_by_sdk_session_id, load_direct_codex_owner_by_thread_id,
  load_session_permission_mode,
};
pub(crate) use session_hydration::{load_session_by_id, load_session_metadata_by_id};
pub(crate) use startup_recovery::load_sessions_for_startup;

#[cfg(test)]
pub(crate) use startup_recovery::load_session_lifecycle_state;

#[cfg(test)]
pub(crate) use startup_recovery::load_sessions_for_startup_from_db_path;

type StoredCodexConfigRow = (
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<bool>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
);

pub(super) fn infer_codex_config_mode(raw_mode: Option<&str>) -> Option<CodexConfigMode> {
  match raw_mode {
    Some("inherit") => Some(CodexConfigMode::Inherit),
    Some("profile") => Some(CodexConfigMode::Profile),
    Some("custom") => Some(CodexConfigMode::Custom),
    _ => None,
  }
}

pub(super) struct ActiveSessionRow {
  pub id: String,
  pub provider: String,
  pub status: String,
  pub work_status: String,
  pub control_mode: Option<String>,
  pub lifecycle_state: SessionLifecycleState,
  pub project_path: String,
  pub transcript_path: Option<String>,
  pub project_name: Option<String>,
  pub model: Option<String>,
  pub custom_name: Option<String>,
  pub first_prompt: Option<String>,
  pub codex_thread_id: Option<String>,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub permission_mode: Option<String>,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub input_tokens: i64,
  pub output_tokens: i64,
  pub cached_tokens: i64,
  pub context_window: i64,
  pub token_usage_snapshot_kind_str: String,
}

#[derive(Debug)]
pub struct RestoredSession {
  pub id: String,
  pub provider: String,
  pub status: String,
  pub work_status: String,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub project_path: String,
  pub transcript_path: Option<String>,
  pub project_name: Option<String>,
  pub model: Option<String>,
  pub custom_name: Option<String>,
  pub summary: Option<String>,
  pub codex_integration_mode: Option<String>,
  pub claude_integration_mode: Option<String>,
  pub codex_thread_id: Option<String>,
  pub claude_sdk_session_id: Option<String>,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub permission_mode: Option<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub codex_config_mode: Option<CodexConfigMode>,
  pub codex_config_profile: Option<String>,
  pub codex_model_provider: Option<String>,
  pub codex_config_source: Option<CodexConfigSource>,
  pub codex_config_overrides: Option<CodexSessionOverrides>,
  pub input_tokens: i64,
  pub output_tokens: i64,
  pub cached_tokens: i64,
  pub context_window: i64,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub rows: Vec<ConversationRowEntry>,
  pub forked_from_session_id: Option<String>,
  pub current_diff: Option<String>,
  pub current_plan: Option<String>,
  pub turn_count: u64,
  pub turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)>,
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub first_prompt: Option<String>,
  pub last_message: Option<String>,
  pub end_reason: Option<String>,
  pub effort: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub approval_version: u64,
  pub unread_count: u64,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub allow_bypass_permissions: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectClaudeOwner {
  pub session_id: String,
  pub status: SessionStatus,
  pub lifecycle_state: SessionLifecycleState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectCodexOwner {
  pub session_id: String,
  pub status: SessionStatus,
  pub lifecycle_state: SessionLifecycleState,
}

pub(super) fn parse_lifecycle_state(value: Option<String>) -> SessionLifecycleState {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("resumable") => SessionLifecycleState::Resumable,
    Some("ended") => SessionLifecycleState::Ended,
    _ => SessionLifecycleState::Open,
  }
}

pub(super) fn parse_session_status(value: &str) -> SessionStatus {
  match value.to_ascii_lowercase().as_str() {
    "ended" => SessionStatus::Ended,
    _ => SessionStatus::Active,
  }
}

pub(super) fn parse_control_mode(value: Option<String>) -> Option<SessionControlMode> {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("direct") => Some(SessionControlMode::Direct),
    Some("passive") => Some(SessionControlMode::Passive),
    _ => None,
  }
}

pub(super) fn control_mode_to_integration_mode(
  provider: &str,
  control_mode: SessionControlMode,
) -> (Option<String>, Option<String>) {
  match provider.to_ascii_lowercase().as_str() {
    "claude" => (
      None,
      Some(match control_mode {
        SessionControlMode::Direct => "direct".to_string(),
        SessionControlMode::Passive => "passive".to_string(),
      }),
    ),
    _ => (
      Some(match control_mode {
        SessionControlMode::Direct => "direct".to_string(),
        SessionControlMode::Passive => "passive".to_string(),
      }),
      None,
    ),
  }
}

pub(super) fn load_latest_usage_turn_seq(conn: &Connection, session_id: &str) -> u64 {
  // `turn_count` seeds the next `turn-N` id, so restore from the latest
  // persisted sequence instead of counting rows and risking id reuse.
  conn
    .query_row(
      "SELECT COALESCE(MAX(turn_seq), 0)
       FROM usage_turns
       WHERE session_id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0),
    )
    .unwrap_or(0)
    .max(0) as u64
}

pub(super) use super::chrono_now;
pub(super) use super::messages::{
  load_latest_completed_conversation_message_from_db, load_messages_from_db,
};
pub(super) use super::transcripts::{
  extract_summary_from_transcript, load_messages_from_transcript,
};
pub(super) use super::usage::snapshot_kind_from_str;
