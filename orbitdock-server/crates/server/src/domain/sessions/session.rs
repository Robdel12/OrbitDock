//! Session management

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, ConversationRowSummary, RowEntrySummary, TurnStatus,
};
use orbitdock_protocol::domain_events::ToolFamily;
use orbitdock_protocol::{
  ApprovalPreview, ApprovalQuestionOption, ApprovalQuestionPrompt, ApprovalRequest, ApprovalType,
  ClaudeIntegrationMode, CodexApprovalPolicy, CodexConfigMode, CodexConfigSource,
  CodexIntegrationMode, CodexSessionOverrides, Provider, SessionControlMode, SessionLifecycleState,
  SessionState, SessionStatus, SessionSummary, StateChanges, SubagentInfo, TokenUsage,
  TokenUsageSnapshotKind, TurnDiff, WorkStatus,
};

pub use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use serde::Serialize;
use tokio::sync::broadcast;
use tracing::info;

use orbitdock_protocol::ServerMessage;

#[cfg(test)]
use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::domain::sessions::transition::{
  approval_preview, ApprovalPreviewInput, TransitionState, WorkPhase,
};
use crate::support::snapshot_compaction::sanitize_server_message_for_transport;

/// Events that matter for list/dashboard subscribers.
/// Keep conversation row streaming off this channel; session-level deltas are
/// lightweight and drive dashboard badges/status in real time.
fn is_list_relevant(msg: &ServerMessage) -> bool {
  matches!(
    msg,
    ServerMessage::SessionDelta { .. }
      | ServerMessage::SessionEnded { .. }
      | ServerMessage::SessionForked { .. }
  )
}

fn should_emit_dashboard_invalidation(msg: &ServerMessage) -> bool {
  match msg {
    ServerMessage::SessionDelta { changes, .. } => {
      changes.status.is_some()
        || changes.work_status.is_some()
        || changes.control_mode.is_some()
        || changes.lifecycle_state.is_some()
        || changes.steerable.is_some()
        || changes.pending_approval.is_some()
        || changes.custom_name.is_some()
        || changes.summary.is_some()
        || changes.first_prompt.is_some()
        || changes.model.is_some()
        || changes.effort.is_some()
        || changes.approval_policy.is_some()
        || changes.approval_policy_details.is_some()
        || changes.sandbox_mode.is_some()
        || changes.permission_mode.is_some()
        || changes.collaboration_mode.is_some()
        || changes.multi_agent.is_some()
        || changes.personality.is_some()
        || changes.service_tier.is_some()
        || changes.developer_instructions.is_some()
        || changes.codex_config_mode.is_some()
        || changes.codex_config_profile.is_some()
        || changes.codex_model_provider.is_some()
        || changes.codex_config_source.is_some()
        || changes.codex_config_overrides.is_some()
        || changes.codex_integration_mode.is_some()
        || changes.claude_integration_mode.is_some()
        || changes.current_diff.is_some()
        || changes.subagents.is_some()
        || changes.last_activity_at.is_some()
        || changes.last_message.is_some()
        || changes.unread_count.is_some()
    }
    ServerMessage::SessionEnded { .. } | ServerMessage::SessionForked { .. } => true,
    _ => false,
  }
}

fn fallback_tool_name(approval: &ApprovalRequest) -> Option<String> {
  if let Some(name) = approval.tool_name.as_ref().filter(|name| !name.is_empty()) {
    return Some(name.clone());
  }

  match approval.approval_type {
    ApprovalType::Exec => Some("Bash".to_string()),
    ApprovalType::Patch => Some("Edit".to_string()),
    ApprovalType::Permissions => Some("Permissions".to_string()),
    ApprovalType::Question => None,
  }
}

fn fallback_tool_input(approval: &ApprovalRequest) -> Option<String> {
  if let Some(input) = approval
    .tool_input
    .as_ref()
    .filter(|input| !input.is_empty())
  {
    return Some(input.clone());
  }

  let mut payload = serde_json::Map::new();
  if let Some(command) = approval.command.as_ref().filter(|cmd| !cmd.is_empty()) {
    payload.insert(
      "command".to_string(),
      serde_json::Value::String(command.clone()),
    );
  }
  if let Some(path) = approval.file_path.as_ref().filter(|path| !path.is_empty()) {
    payload.insert(
      "file_path".to_string(),
      serde_json::Value::String(path.clone()),
    );
  }
  if payload.is_empty() {
    if let Some(preview) = approval.preview.as_ref() {
      let key = match preview.preview_type {
        orbitdock_protocol::ApprovalPreviewType::ShellCommand => "command",
        orbitdock_protocol::ApprovalPreviewType::Url => "url",
        orbitdock_protocol::ApprovalPreviewType::SearchQuery => "query",
        orbitdock_protocol::ApprovalPreviewType::Pattern => "pattern",
        orbitdock_protocol::ApprovalPreviewType::Prompt => "prompt",
        orbitdock_protocol::ApprovalPreviewType::Diff => "diff",
        orbitdock_protocol::ApprovalPreviewType::FilePath => "file_path",
        orbitdock_protocol::ApprovalPreviewType::Value
        | orbitdock_protocol::ApprovalPreviewType::Action => "value",
      };
      payload.insert(
        key.to_string(),
        serde_json::Value::String(preview.value.clone()),
      );
    }
  }

  if payload.is_empty() {
    None
  } else {
    Some(serde_json::Value::Object(payload).to_string())
  }
}

fn serialized_value_eq<T: Serialize>(left: &T, right: &T) -> bool {
  serde_json::to_value(left).ok() == serde_json::to_value(right).ok()
}

fn resolve_approval_policy_details(
  approval_policy: Option<&str>,
  codex_config_overrides: Option<&CodexSessionOverrides>,
) -> Option<CodexApprovalPolicy> {
  codex_config_overrides
    .and_then(|overrides| overrides.approval_policy_details.clone())
    .or_else(|| {
      approval_policy.and_then(orbitdock_protocol::CodexApprovalPolicy::from_storage_text)
    })
}

fn approval_requests_effectively_equal(left: &ApprovalRequest, right: &ApprovalRequest) -> bool {
  serialized_value_eq(left, right)
}

fn pending_approval_entries_effectively_equal(
  left: &PendingApprovalEntry,
  right: &PendingApprovalEntry,
) -> bool {
  left.approval_type == right.approval_type
    && left.proposed_amendment == right.proposed_amendment
    && approval_requests_effectively_equal(&left.request, &right.request)
}

fn parse_bool_value(value: Option<&serde_json::Value>) -> bool {
  let Some(value) = value else {
    return false;
  };
  if let Some(flag) = value.as_bool() {
    return flag;
  }
  if let Some(number) = value.as_u64() {
    return number > 0;
  }
  if let Some(text) = value.as_str() {
    let normalized = text.trim().to_ascii_lowercase();
    return normalized == "true" || normalized == "1" || normalized == "yes";
  }
  false
}

fn parse_question_options(
  payload: &serde_json::Map<String, serde_json::Value>,
) -> Vec<ApprovalQuestionOption> {
  let Some(options) = payload.get("options").and_then(serde_json::Value::as_array) else {
    return vec![];
  };

  options
    .iter()
    .filter_map(|raw_option| {
      let option = raw_option.as_object()?;
      let label = option
        .get("label")
        .or_else(|| option.get("value"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())?
        .to_string();
      let description = option
        .get("description")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToString::to_string);
      Some(ApprovalQuestionOption { label, description })
    })
    .collect()
}

fn parse_question_prompt(
  payload: &serde_json::Map<String, serde_json::Value>,
  fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
  let id = payload
    .get("id")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .unwrap_or(fallback_id)
    .to_string();
  let header = payload
    .get("header")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .map(ToString::to_string);
  let question = payload
    .get("question")
    .and_then(serde_json::Value::as_str)
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .unwrap_or("Question")
    .to_string();
  if question.is_empty() {
    return None;
  }

  Some(ApprovalQuestionPrompt {
    id,
    header,
    question,
    options: parse_question_options(payload),
    allows_multiple_selection: parse_bool_value(
      payload
        .get("multiSelect")
        .or_else(|| payload.get("multi_select")),
    ),
    allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
    is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
  })
}

fn extract_question_prompts(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  let from_tool_input: Vec<ApprovalQuestionPrompt> = tool_input
    .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
    .and_then(|value| value.as_object().cloned())
    .map(|payload| {
      if let Some(questions) = payload
        .get("questions")
        .and_then(serde_json::Value::as_array)
      {
        return questions
          .iter()
          .enumerate()
          .filter_map(|(index, raw_question)| {
            let prompt = raw_question.as_object()?;
            parse_question_prompt(prompt, index.to_string().as_str())
          })
          .collect();
      }
      if payload.contains_key("question") || payload.contains_key("options") {
        return parse_question_prompt(&payload, "0")
          .map(|prompt| vec![prompt])
          .unwrap_or_default();
      }
      vec![]
    })
    .unwrap_or_default();

  if !from_tool_input.is_empty() {
    return from_tool_input;
  }

  let fallback_question = fallback_question
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .map(ToString::to_string);
  match fallback_question {
    Some(question) => vec![ApprovalQuestionPrompt {
      id: "0".to_string(),
      header: None,
      question,
      options: vec![],
      allows_multiple_selection: false,
      allows_other: true,
      is_secret: false,
    }],
    None => vec![],
  }
}

fn preview_for_pending_approval(
  request_id: Option<&str>,
  approval_type: ApprovalType,
  tool_name: Option<&str>,
  tool_input: Option<&str>,
  question: Option<&str>,
) -> Option<ApprovalPreview> {
  let request_id = request_id
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .unwrap_or("pending-approval");
  approval_preview(ApprovalPreviewInput {
    request_id,
    approval_type,
    tool_name,
    tool_input,
    command: None,
    file_path: None,
    diff: None,
    question,
    permission_reason: None,
  })
}

fn pending_tool_family_from_state(
  pending_approval: Option<&ApprovalRequest>,
  pending_tool_name: Option<&str>,
  pending_question: Option<&str>,
) -> Option<ToolFamily> {
  if pending_question.is_some()
    || pending_approval.is_some_and(|request| request.approval_type == ApprovalType::Question)
  {
    return Some(ToolFamily::Question);
  }

  pending_tool_name.map(|name| match name {
    "Bash" | "bash" => ToolFamily::Shell,
    "Read" | "read" | "FileRead" => ToolFamily::FileRead,
    "Edit" | "edit" | "FileEdit" | "MultiEdit" | "Write" | "write" | "FileWrite"
    | "NotebookEdit" => ToolFamily::FileChange,
    "Glob" | "glob" | "Grep" | "grep" | "ToolSearch" => ToolFamily::Search,
    "WebSearch" | "websearch" | "WebFetch" | "webfetch" => ToolFamily::Web,
    "Agent" | "agent" | "task" => ToolFamily::Agent,
    "AskUserQuestion" => ToolFamily::Question,
    "EnterPlanMode" | "ExitPlanMode" => ToolFamily::Plan,
    "TodoWrite" => ToolFamily::Todo,
    "CompactContext" => ToolFamily::Context,
    value if value.starts_with("mcp__") => ToolFamily::Mcp,
    _ => ToolFamily::Generic,
  })
}

pub fn control_mode_from_parts(
  provider: Provider,
  codex_integration_mode: Option<CodexIntegrationMode>,
  claude_integration_mode: Option<ClaudeIntegrationMode>,
) -> SessionControlMode {
  match provider {
    Provider::Codex => match codex_integration_mode {
      Some(CodexIntegrationMode::Direct) => SessionControlMode::Direct,
      Some(CodexIntegrationMode::Passive) | None => SessionControlMode::Passive,
    },
    Provider::Claude => match claude_integration_mode {
      Some(ClaudeIntegrationMode::Direct) => SessionControlMode::Direct,
      Some(ClaudeIntegrationMode::Passive) | None => SessionControlMode::Passive,
    },
  }
}

pub(crate) fn accepts_user_input_from_parts(
  status: SessionStatus,
  control_mode: SessionControlMode,
  lifecycle_state: SessionLifecycleState,
) -> bool {
  status == SessionStatus::Active
    && control_mode == SessionControlMode::Direct
    && lifecycle_state == SessionLifecycleState::Open
}

/// Lightweight, lock-free snapshot of session metadata.
/// Used by `ArcSwap` so list subscribers and snapshot readers never block
/// the actor.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct SessionSnapshot {
  pub id: String,
  pub provider: Provider,
  pub status: SessionStatus,
  pub work_status: WorkStatus,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub steerable: bool,
  pub project_path: String,
  pub project_name: Option<String>,
  pub transcript_path: Option<String>,
  pub custom_name: Option<String>,
  pub summary: Option<String>,
  pub first_prompt: Option<String>,
  pub last_message: Option<String>,
  pub model: Option<String>,
  pub codex_integration_mode: Option<CodexIntegrationMode>,
  pub claude_integration_mode: Option<ClaudeIntegrationMode>,
  pub approval_policy: Option<String>,
  pub approval_policy_details: Option<CodexApprovalPolicy>,
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
  pub has_pending_approval: bool,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub message_count: usize,
  /// Number of active sub-agents.
  pub active_worker_count: u32,
  pub token_usage: TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
  pub revision: u64,
  pub current_plan: Option<String>,
  pub current_diff: Option<String>,
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub effort: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub approval_version: u64,
  pub repository_root: Option<String>,
  pub is_worktree: bool,
  pub worktree_id: Option<String>,
  pub has_turn_diff: bool,
  /// Number of active WebSocket subscribers (for subscriber-gated background tasks).
  pub subscriber_count: usize,
  /// Cached count of unread messages.
  pub unread_count: u64,
  /// Mission ID if this session is orchestrated.
  pub mission_id: Option<String>,
  /// Issue identifier (e.g. "PROJ-123") if this session is orchestrated.
  pub issue_identifier: Option<String>,
  /// Whether the session was launched with `--allow-dangerously-skip-permissions`.
  pub allow_bypass_permissions: bool,
  /// ID of the newest row that has been synced from the transcript.
  /// Used for sequence-based sync comparison (immune to count inflation).
  pub newest_synced_row_id: Option<String>,
}

#[derive(Debug, Clone)]
struct PendingApprovalEntry {
  request: ApprovalRequest,
  approval_type: ApprovalType,
  proposed_amendment: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PendingApprovalMutation {
  Unchanged,
  Updated,
  Enqueued,
}

const EVENT_LOG_CAPACITY: usize = 1000;
const DEFAULT_BROADCAST_CAPACITY: usize = 512;
const RETAINED_FINALIZED_ROW_LIMIT: usize = 200;
const STREAMING_ROW_BROADCAST_THROTTLE: Duration = Duration::from_millis(250);
const STREAMING_ROW_FORCE_EMIT_CONTENT_STEP: usize = 24;
const STREAMING_ROW_MIN_INITIAL_EMIT_CHARS: usize = 8;

fn broadcast_capacity() -> usize {
  std::env::var("ORBITDOCK_BROADCAST_CAPACITY")
    .ok()
    .and_then(|v| v.parse().ok())
    .unwrap_or(DEFAULT_BROADCAST_CAPACITY)
}

/// Handle to a running session
pub struct SessionHandle {
  // ── Grouped facets ──────────────────────────────────────────────
  identity: SessionIdentity,
  config: SessionConfig,
  display: SessionDisplay,
  environment: SessionEnvironment,
  timestamps: SessionTimestamps,

  // ── Integration mode (set at creation/restore, not via config patch) ──
  codex_integration_mode: Option<CodexIntegrationMode>,
  claude_integration_mode: Option<ClaudeIntegrationMode>,
  control_mode: SessionControlMode,

  // ── Session lifecycle ───────────────────────────────────────────
  status: SessionStatus,
  work_status: WorkStatus,
  lifecycle_state: SessionLifecycleState,
  steerable: bool,
  last_tool: Option<String>,

  // ── Conversation data ───────────────────────────────────────────
  rows: Vec<ConversationRowEntry>,
  total_row_count: u64,

  // ── Token usage ─────────────────────────────────────────────────
  token_usage: TokenUsage,
  token_usage_snapshot_kind: TokenUsageSnapshotKind,

  // ── Diff & plan ─────────────────────────────────────────────────
  current_diff: Option<String>,
  current_plan: Option<String>,

  // ── Turn tracking ───────────────────────────────────────────────
  current_turn_id: Option<String>,
  turn_count: u64,
  turn_diffs: Vec<TurnDiff>,

  // ── Fork lineage ────────────────────────────────────────────────
  forked_from_session_id: Option<String>,

  // ── Terminal ─────────────────────────────────────────────────────
  terminal_session_id: Option<String>,
  terminal_app: Option<String>,

  // ── Sub-agents ──────────────────────────────────────────────────
  subagents: Vec<SubagentInfo>,

  // ── Approval management ─────────────────────────────────────────
  pending_approval: Option<ApprovalRequest>,
  permission_mode: Option<String>,
  pending_tool_name: Option<String>,
  pending_tool_input: Option<String>,
  pending_question: Option<String>,
  /// Persisted connector-path request_id for the current pending approval.
  /// Loaded from DB on restore so approval routing works after server restart.
  pending_approval_id: Option<String>,
  /// Server-authoritative queue of unresolved approvals for this session.
  pending_approvals: VecDeque<PendingApprovalEntry>,
  /// Monotonic counter incremented on every approval state change (enqueue, decide, clear).
  approval_version: u64,

  // ── Unread tracking ─────────────────────────────────────────────
  /// Cached count of unread rows (non-user with sequence > last_read).
  unread_count: u64,

  // ── Mission / orchestration ─────────────────────────────────────
  /// Mission ID if this session is orchestrated.
  mission_id: Option<String>,
  /// Issue identifier (e.g. "PROJ-123") if this session is orchestrated.
  issue_identifier: Option<String>,
  /// Whether the CLI was launched with `--allow-dangerously-skip-permissions`.
  allow_bypass_permissions: bool,

  // ── Transcript sync ─────────────────────────────────────────────
  /// ID of the newest row synced from transcript (for sequence-based sync).
  newest_synced_row_id: Option<String>,

  // ── Broadcasting ────────────────────────────────────────────────
  broadcast_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,
  /// Optional sender for list-level broadcasts (dashboard sidebar updates)
  list_tx: Option<broadcast::Sender<orbitdock_protocol::ServerMessage>>,
  /// Shared dashboard revision counter owned by the session registry.
  dashboard_revision: Option<Arc<AtomicU64>>,
  /// Monotonic revision counter, incremented on every broadcast
  revision: u64,
  /// Ring buffer of (revision, pre-serialized JSON with revision injected)
  event_log: VecDeque<(u64, String)>,
  /// Last emit state for actively streaming message rows.
  streaming_row_emit_at: HashMap<String, StreamingRowEmitState>,

  // ── Lock-free snapshot ──────────────────────────────────────────
  /// Lock-free snapshot for read-only access from outside the actor
  snapshot_handle: Arc<ArcSwap<SessionSnapshot>>,
}

/// A config patch is structurally identical to `SessionConfig` — `None` fields
/// mean "don't change" when applied via `set_config`.
pub type SessionConfigPatch = SessionConfig;

/// All fields needed to reconstruct a `SessionHandle` from persisted DB state.
pub struct SessionRestoreData {
  pub identity: SessionIdentity,
  pub config: SessionConfig,
  pub display: SessionDisplay,
  pub environment: SessionEnvironment,
  pub timestamps: SessionTimestamps,
  pub status: SessionStatus,
  pub work_status: WorkStatus,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub permission_mode: Option<String>,
  pub token_usage: TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub rows: Vec<ConversationRowEntry>,
  pub current_diff: Option<String>,
  pub current_plan: Option<String>,
  pub turn_diffs: Vec<TurnDiff>,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub approval_version: u64,
  pub unread_count: u64,
}

/// Returns true if the row is NOT a user message (used for unread counting).
fn is_non_user_row(entry: &ConversationRowEntry) -> bool {
  !entry.row.is_user_input()
}

fn is_non_user_row_summary(entry: &RowEntrySummary) -> bool {
  !matches!(
    entry.row,
    ConversationRowSummary::User(_) | ConversationRowSummary::Steer(_)
  )
}

#[allow(dead_code)]
fn is_message_row(entry: &ConversationRowEntry) -> bool {
  matches!(
    entry.row,
    ConversationRow::User(_)
      | ConversationRow::Steer(_)
      | ConversationRow::Assistant(_)
      | ConversationRow::Thinking(_)
      | ConversationRow::System(_)
  )
}

fn is_message_row_summary(entry: &RowEntrySummary) -> bool {
  matches!(
    entry.row,
    ConversationRowSummary::User(_)
      | ConversationRowSummary::Steer(_)
      | ConversationRowSummary::Assistant(_)
      | ConversationRowSummary::Thinking(_)
      | ConversationRowSummary::System(_)
  )
}

#[allow(dead_code)]
fn is_actively_streaming_message_row(entry: &ConversationRowEntry) -> bool {
  matches!(
      &entry.row,
      ConversationRow::Assistant(msg) | ConversationRow::Thinking(msg) | ConversationRow::System(msg)
          if msg.is_streaming
  )
}

fn is_actively_streaming_message_row_summary(entry: &RowEntrySummary) -> bool {
  matches!(
      &entry.row,
      ConversationRowSummary::Assistant(msg) | ConversationRowSummary::Thinking(msg) | ConversationRowSummary::System(msg)
          if msg.is_streaming
  )
}

fn streaming_message_row_summary_content_len(entry: &RowEntrySummary) -> Option<usize> {
  match &entry.row {
    ConversationRowSummary::Assistant(msg)
    | ConversationRowSummary::Thinking(msg)
    | ConversationRowSummary::System(msg) => Some(msg.content.chars().count()),
    _ => None,
  }
}

#[derive(Debug, Clone)]
struct StreamingRowEmitState {
  last_emit_at: Instant,
  last_emitted_content_len: usize,
}

impl SessionHandle {
  fn sync_control_mode_from_integrations(&mut self) {
    self.control_mode = control_mode_from_parts(
      self.identity.provider,
      self.codex_integration_mode,
      self.claude_integration_mode,
    );
  }

  pub fn has_active_viewers(&self) -> bool {
    self.broadcast_tx.receiver_count() > 0
  }

  fn next_row_sequence(&self) -> u64 {
    self
      .rows
      .last()
      .map(|entry| entry.sequence + 1)
      .unwrap_or(self.total_row_count)
  }

  fn normalize_row_sequences(rows: &mut [ConversationRowEntry]) {
    for (index, entry) in rows.iter_mut().enumerate() {
      entry.sequence = index as u64;
    }
  }

  #[allow(dead_code)]
  fn oldest_retained_sequence(&self) -> Option<u64> {
    self.rows.first().map(|entry| entry.sequence)
  }

  fn newest_retained_sequence(&self) -> Option<u64> {
    self.rows.last().map(|entry| entry.sequence)
  }

  pub fn latest_row_sequence(&self) -> u64 {
    self
      .newest_retained_sequence()
      .unwrap_or_else(|| self.total_row_count.saturating_sub(1))
  }

  #[allow(dead_code)]
  fn retained_has_more_before(&self) -> bool {
    self
      .oldest_retained_sequence()
      .is_some_and(|sequence| sequence > 0)
  }

  fn trim_retained_rows(&mut self) {
    let Some(newest_sequence) = self.newest_retained_sequence() else {
      return;
    };
    let Some(oldest_allowed_sequence) = newest_sequence
      .checked_add(1)
      .and_then(|count| count.checked_sub(RETAINED_FINALIZED_ROW_LIMIT as u64))
    else {
      return;
    };

    self
      .rows
      .retain(|entry| entry.sequence >= oldest_allowed_sequence);
  }

  #[cfg(test)]
  pub fn conversation_page(&self, before_sequence: Option<u64>, limit: usize) -> ConversationPage {
    if self.rows.is_empty() || limit == 0 {
      return ConversationPage {
        rows: vec![],
        total_row_count: self.total_row_count,
        has_more_before: false,
        oldest_sequence: None,
        newest_sequence: None,
      };
    }

    let upper_bound = before_sequence.unwrap_or(u64::MAX);
    let mut page: Vec<ConversationRowEntry> = self
      .rows
      .iter()
      .filter(|entry| entry.sequence < upper_bound)
      .rev()
      .take(limit)
      .cloned()
      .collect();
    page.reverse();

    let oldest_sequence = page.first().map(|entry| entry.sequence);
    let newest_sequence = page.last().map(|entry| entry.sequence);
    let has_more_before = oldest_sequence.is_some_and(|sequence| sequence > 0);

    ConversationPage {
      rows: page,
      total_row_count: self.total_row_count,
      has_more_before,
      oldest_sequence,
      newest_sequence,
    }
  }

  #[cfg(test)]
  pub fn conversation_bootstrap(&self, limit: usize) -> ConversationBootstrap {
    let page = self.conversation_page(None, limit);
    let session = self.retained_state();
    ConversationBootstrap {
      session,
      total_row_count: page.total_row_count,
      has_more_before: page.has_more_before,
      oldest_sequence: page.oldest_sequence,
      newest_sequence: page.newest_sequence,
    }
  }

  /// Create a new session handle
  pub fn new(id: String, provider: Provider, project_path: String) -> Self {
    let now = chrono_now();
    let (broadcast_tx, _) = broadcast::channel(broadcast_capacity());

    let identity = SessionIdentity {
      id,
      provider,
      project_path,
      transcript_path: None,
      project_name: None,
    };
    let timestamps = SessionTimestamps {
      started_at: Some(now.clone()),
      last_activity_at: Some(now.clone()),
      last_progress_at: Some(now),
    };

    let snapshot = SessionSnapshot {
      id: identity.id.clone(),
      provider,
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      control_mode: SessionControlMode::Passive,
      lifecycle_state: SessionLifecycleState::Open,
      steerable: false,
      project_path: identity.project_path.clone(),
      project_name: None,
      transcript_path: None,
      custom_name: None,
      summary: None,
      first_prompt: None,
      last_message: None,
      model: None,
      codex_integration_mode: None,
      claude_integration_mode: None,
      approval_policy: None,
      approval_policy_details: None,
      sandbox_mode: None,
      permission_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides: None,
      has_pending_approval: false,
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
      pending_approval_id: None,
      message_count: 0,
      active_worker_count: 0,
      token_usage: TokenUsage::default(),
      token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
      started_at: timestamps.started_at.clone(),
      last_activity_at: timestamps.last_activity_at.clone(),
      last_progress_at: timestamps.last_progress_at.clone(),
      revision: 0,
      current_plan: None,
      current_diff: None,
      git_branch: None,
      git_sha: None,
      current_cwd: None,
      effort: None,
      terminal_session_id: None,
      terminal_app: None,
      approval_version: 0,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      has_turn_diff: false,
      subscriber_count: 0,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      newest_synced_row_id: None,
    };
    Self {
      identity,
      config: SessionConfig::default(),
      display: SessionDisplay::default(),
      environment: SessionEnvironment::default(),
      timestamps,
      codex_integration_mode: None,
      claude_integration_mode: None,
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      lifecycle_state: SessionLifecycleState::Open,
      control_mode: SessionControlMode::Passive,
      steerable: false,
      last_tool: None,
      rows: Vec::new(),
      total_row_count: 0,
      token_usage: TokenUsage::default(),
      token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
      current_diff: None,
      current_plan: None,
      current_turn_id: None,
      turn_count: 0,
      turn_diffs: Vec::new(),
      forked_from_session_id: None,
      terminal_session_id: None,
      terminal_app: None,
      subagents: Vec::new(),
      pending_approval: None,
      permission_mode: None,
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
      pending_approval_id: None,
      pending_approvals: VecDeque::new(),
      approval_version: 0,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      newest_synced_row_id: None,
      broadcast_tx,
      list_tx: None,
      dashboard_revision: None,
      revision: 0,
      event_log: VecDeque::new(),
      streaming_row_emit_at: HashMap::new(),
      snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
    }
  }

  /// Restore a session from the database (for server restart recovery)
  pub fn restore(data: SessionRestoreData) -> Self {
    let SessionRestoreData {
      identity,
      config,
      display,
      environment,
      timestamps,
      status,
      work_status,
      control_mode,
      lifecycle_state,
      permission_mode,
      token_usage,
      token_usage_snapshot_kind,
      rows,
      current_diff,
      current_plan,
      turn_diffs,
      pending_tool_name,
      pending_tool_input,
      pending_question,
      pending_approval_id,
      terminal_session_id,
      terminal_app,
      approval_version,
      unread_count,
    } = data;
    let (broadcast_tx, _) = broadcast::channel(broadcast_capacity());
    let snapshot = SessionSnapshot {
      id: identity.id.clone(),
      provider: identity.provider,
      status,
      work_status,
      control_mode,
      lifecycle_state,
      steerable: work_status == WorkStatus::Working,
      project_path: identity.project_path.clone(),
      project_name: identity.project_name.clone(),
      transcript_path: identity.transcript_path.clone(),
      custom_name: display.custom_name.clone(),
      summary: display.summary.clone(),
      model: config.model.clone(),
      codex_integration_mode: None,
      claude_integration_mode: None,
      approval_policy: config.approval_policy.clone(),
      approval_policy_details: config.approval_policy_details.clone(),
      sandbox_mode: config.sandbox_mode.clone(),
      permission_mode: permission_mode.clone(),
      collaboration_mode: config.collaboration_mode.clone(),
      multi_agent: config.multi_agent,
      personality: config.personality.clone(),
      service_tier: config.service_tier.clone(),
      developer_instructions: config.developer_instructions.clone(),
      codex_config_mode: config.codex_config_mode,
      codex_config_profile: config.codex_config_profile.clone(),
      codex_model_provider: config.codex_model_provider.clone(),
      codex_config_source: config.codex_config_source,
      codex_config_overrides: config.codex_config_overrides.clone(),
      has_pending_approval: pending_tool_name.is_some()
        || pending_question.is_some()
        || pending_approval_id.is_some(),
      pending_tool_name: pending_tool_name.clone(),
      pending_tool_input: pending_tool_input.clone(),
      pending_question: pending_question.clone(),
      pending_approval_id: pending_approval_id.clone(),
      message_count: rows.len(),
      active_worker_count: 0,
      token_usage: token_usage.clone(),
      token_usage_snapshot_kind,
      started_at: timestamps.started_at.clone(),
      last_activity_at: timestamps.last_activity_at.clone(),
      last_progress_at: timestamps.last_progress_at.clone(),
      revision: 0,
      current_plan: current_plan.clone(),
      current_diff: current_diff.clone(),
      git_branch: environment.git_branch.clone(),
      git_sha: environment.git_sha.clone(),
      current_cwd: environment.current_cwd.clone(),
      effort: config.effort.clone(),
      first_prompt: display.first_prompt.clone(),
      last_message: display.last_message.clone(),
      terminal_session_id: terminal_session_id.clone(),
      terminal_app: terminal_app.clone(),
      approval_version,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      has_turn_diff: current_diff.is_some() || !turn_diffs.is_empty(),
      subscriber_count: 0,
      unread_count,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      newest_synced_row_id: None, // Will be derived from rows below
    };

    let mut handle = Self {
      identity,
      config,
      display,
      environment,
      timestamps,
      codex_integration_mode: None,
      claude_integration_mode: None,
      control_mode,
      status,
      work_status,
      lifecycle_state,
      steerable: work_status == WorkStatus::Working,
      last_tool: None,
      rows,
      total_row_count: 0,
      token_usage,
      token_usage_snapshot_kind,
      current_diff,
      current_plan,
      current_turn_id: None,
      turn_count: turn_diffs.len() as u64,
      turn_diffs,
      forked_from_session_id: None,
      terminal_session_id,
      terminal_app,
      subagents: Vec::new(),
      pending_approval: None,
      permission_mode,
      pending_tool_name,
      pending_tool_input,
      pending_question,
      pending_approval_id,
      pending_approvals: VecDeque::new(),
      approval_version,
      unread_count,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      newest_synced_row_id: None,
      broadcast_tx,
      list_tx: None,
      dashboard_revision: None,
      revision: 0,
      event_log: VecDeque::new(),
      streaming_row_emit_at: HashMap::new(),
      snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
    };
    handle.total_row_count = handle.rows.len() as u64;
    // Initialize newest_synced_row_id from the last loaded row
    handle.newest_synced_row_id = handle.rows.last().map(|r| r.id().to_string());
    handle.trim_retained_rows();
    handle.bootstrap_pending_approval_from_persisted_fields();
    handle.refresh_snapshot();
    handle
  }

  /// Set the list broadcast sender (for dashboard sidebar updates)
  pub fn set_list_tx(&mut self, tx: broadcast::Sender<orbitdock_protocol::ServerMessage>) {
    self.list_tx = Some(tx);
  }

  pub fn set_dashboard_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.dashboard_revision = Some(revision);
  }

  /// Get session ID
  pub fn id(&self) -> &str {
    &self.identity.id
  }

  /// Get provider
  pub fn provider(&self) -> Provider {
    self.identity.provider
  }

  /// Get a reference to the grouped config.
  #[allow(dead_code)]
  pub fn config(&self) -> &SessionConfig {
    &self.config
  }

  /// Get a summary of this session
  pub fn summary(&self) -> SessionSummary {
    let accepts_user_input =
      accepts_user_input_from_parts(self.status, self.control_mode, self.lifecycle_state);
    let display_title = SessionSummary::display_title_from_parts(
      self.display.custom_name.as_deref(),
      self.display.summary.as_deref(),
      self.display.first_prompt.as_deref(),
      self.identity.project_name.as_deref(),
      &self.identity.project_path,
    );
    let context_line = SessionSummary::context_line_from_parts(
      self.display.summary.as_deref(),
      self.display.first_prompt.as_deref(),
      self.display.last_message.as_deref(),
    );
    SessionSummary {
      id: self.identity.id.clone(),
      provider: self.identity.provider,
      project_path: self.identity.project_path.clone(),
      transcript_path: self.identity.transcript_path.clone(),
      project_name: self.identity.project_name.clone(),
      model: self.config.model.clone(),
      custom_name: self.display.custom_name.clone(),
      summary: self.display.summary.clone(),
      status: self.status,
      work_status: self.work_status,
      control_mode: self.control_mode,
      lifecycle_state: self.lifecycle_state,
      accepts_user_input,
      steerable: self.steerable,
      token_usage: self.token_usage.clone(),
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      has_pending_approval: self.pending_approval.is_some()
        || self.pending_tool_name.is_some()
        || self.pending_question.is_some()
        || self.pending_approval_id.is_some(),
      codex_integration_mode: self.codex_integration_mode,
      claude_integration_mode: self.claude_integration_mode,
      approval_policy: self.config.approval_policy.clone(),
      approval_policy_details: self.config.approval_policy_details.clone(),
      sandbox_mode: self.config.sandbox_mode.clone(),
      permission_mode: self.permission_mode.clone(),
      collaboration_mode: self.config.collaboration_mode.clone(),
      multi_agent: self.config.multi_agent,
      personality: self.config.personality.clone(),
      service_tier: self.config.service_tier.clone(),
      developer_instructions: self.config.developer_instructions.clone(),
      codex_config_mode: self.config.codex_config_mode,
      codex_config_profile: self.config.codex_config_profile.clone(),
      codex_model_provider: self.config.codex_model_provider.clone(),
      codex_config_source: self.config.codex_config_source,
      codex_config_overrides: self.config.codex_config_overrides.clone(),
      pending_tool_name: self.pending_tool_name.clone(),
      pending_tool_input: self.pending_tool_input.clone(),
      pending_question: self.pending_question.clone(),
      pending_approval_id: self
        .pending_approval_id
        .clone()
        .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
      started_at: self.timestamps.started_at.clone(),
      last_activity_at: self.timestamps.last_activity_at.clone(),
      last_progress_at: self.timestamps.last_progress_at.clone(),
      git_branch: self.environment.git_branch.clone(),
      git_sha: self.environment.git_sha.clone(),
      current_cwd: self.environment.current_cwd.clone(),
      effort: self.config.effort.clone(),
      first_prompt: self.display.first_prompt.clone(),
      last_message: self.display.last_message.clone(),
      approval_version: Some(self.approval_version),
      summary_revision: self.revision,
      repository_root: self.environment.repository_root.clone(),
      is_worktree: self.environment.is_worktree,
      worktree_id: self.environment.worktree_id.clone(),
      unread_count: self.unread_count,
      has_turn_diff: self.current_diff.is_some() || !self.turn_diffs.is_empty(),
      display_title,
      context_line,
      list_status: SessionSummary::list_status_from_parts(self.status, self.work_status),
      active_worker_count: self
        .subagents
        .iter()
        .filter(|s| s.ended_at.is_none())
        .count() as u32,
      pending_tool_family: pending_tool_family_from_state(
        self.pending_approval.as_ref(),
        self.pending_tool_name.as_deref(),
        self.pending_question.as_deref(),
      ),
      forked_from_session_id: self.forked_from_session_id.clone(),
      mission_id: self.mission_id.clone(),
      issue_identifier: self.issue_identifier.clone(),
      allow_bypass_permissions: self.allow_bypass_permissions,
    }
  }

  /// Get the retained in-memory session snapshot.
  pub fn retained_state(&self) -> SessionState {
    let accepts_user_input =
      accepts_user_input_from_parts(self.status, self.control_mode, self.lifecycle_state);
    SessionState {
      id: self.identity.id.clone(),
      provider: self.identity.provider,
      project_path: self.identity.project_path.clone(),
      transcript_path: self.identity.transcript_path.clone(),
      project_name: self.identity.project_name.clone(),
      model: self.config.model.clone(),
      custom_name: self.display.custom_name.clone(),
      summary: self.display.summary.clone(),
      status: self.status,
      work_status: self.work_status,
      control_mode: self.control_mode,
      lifecycle_state: self.lifecycle_state,
      accepts_user_input,
      pending_approval: self.pending_approval.clone(),
      permission_mode: self.permission_mode.clone(),
      collaboration_mode: self.config.collaboration_mode.clone(),
      multi_agent: self.config.multi_agent,
      personality: self.config.personality.clone(),
      service_tier: self.config.service_tier.clone(),
      developer_instructions: self.config.developer_instructions.clone(),
      codex_config_mode: self.config.codex_config_mode,
      codex_config_profile: self.config.codex_config_profile.clone(),
      codex_model_provider: self.config.codex_model_provider.clone(),
      codex_config_source: self.config.codex_config_source,
      codex_config_overrides: self.config.codex_config_overrides.clone(),
      pending_tool_name: self.pending_tool_name.clone(),
      pending_tool_input: self.pending_tool_input.clone(),
      pending_question: self.pending_question.clone(),
      pending_approval_id: self
        .pending_approval_id
        .clone()
        .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
      token_usage: self.token_usage.clone(),
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      current_diff: self.current_diff.clone(),
      cumulative_diff: None,
      current_plan: self.current_plan.clone(),
      codex_integration_mode: self.codex_integration_mode,
      claude_integration_mode: self.claude_integration_mode,
      approval_policy: self.config.approval_policy.clone(),
      approval_policy_details: self.config.approval_policy_details.clone(),
      sandbox_mode: self.config.sandbox_mode.clone(),
      started_at: self.timestamps.started_at.clone(),
      last_activity_at: self.timestamps.last_activity_at.clone(),
      last_progress_at: self.timestamps.last_progress_at.clone(),
      forked_from_session_id: self.forked_from_session_id.clone(),
      revision: Some(self.revision),
      current_turn_id: self.current_turn_id.clone(),
      turn_count: self.turn_count,
      turn_diffs: self.turn_diffs.clone(),
      git_branch: self.environment.git_branch.clone(),
      git_sha: self.environment.git_sha.clone(),
      current_cwd: self.environment.current_cwd.clone(),
      first_prompt: self.display.first_prompt.clone(),
      last_message: self.display.last_message.clone(),
      subagents: self.subagents.clone(),
      effort: self.config.effort.clone(),
      terminal_session_id: self.terminal_session_id.clone(),
      terminal_app: self.terminal_app.clone(),
      approval_version: Some(self.approval_version),
      repository_root: self.environment.repository_root.clone(),
      is_worktree: self.environment.is_worktree,
      worktree_id: self.environment.worktree_id.clone(),
      unread_count: self.unread_count,
      mission_id: self.mission_id.clone(),
      issue_identifier: self.issue_identifier.clone(),
      steerable: self.steerable,
      allow_bypass_permissions: self.allow_bypass_permissions,
      rows: vec![],
      total_row_count: 0,
      has_more_before: false,
      oldest_sequence: None,
      newest_sequence: None,
    }
  }

  /// Get subagents
  #[allow(dead_code)]
  pub fn subagents(&self) -> &[SubagentInfo] {
    &self.subagents
  }

  /// Set subagents list
  #[allow(dead_code)]
  pub fn set_subagents(&mut self, subagents: Vec<SubagentInfo>) {
    self.subagents = subagents;
    self.refresh_snapshot();
  }

  pub fn set_pending_attention(
    &mut self,
    pending_tool_name: Option<String>,
    pending_tool_input: Option<String>,
    pending_question: Option<String>,
  ) {
    self.pending_tool_name = pending_tool_name;
    self.pending_tool_input = pending_tool_input;
    self.pending_question = pending_question;
    self.pending_approval_id = None;
    self.refresh_snapshot();
  }

  /// Subscribe to session updates
  pub fn subscribe(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
    self.broadcast_tx.subscribe()
  }

  /// Set mission context (immutable — set once at session creation)
  pub fn set_mission_context(
    &mut self,
    mission_id: Option<String>,
    issue_identifier: Option<String>,
  ) {
    self.mission_id = mission_id;
    self.issue_identifier = issue_identifier;
    self.refresh_snapshot();
  }

  /// Mark that the CLI was launched with `--allow-dangerously-skip-permissions`.
  pub fn set_allow_bypass_permissions(&mut self, enabled: bool) {
    self.allow_bypass_permissions = enabled;
    self.refresh_snapshot();
  }

  /// Set the custom name for this session
  pub fn set_custom_name(&mut self, name: Option<String>) {
    self.display.custom_name = name;
  }

  /// Set first prompt
  #[allow(dead_code)]
  pub fn set_first_prompt(&mut self, prompt: Option<String>) {
    self.display.first_prompt = prompt;
  }

  /// Set last message (for dashboard context lines)
  pub fn set_last_message(&mut self, message: Option<String>) {
    self.display.last_message = message;
  }

  /// Get rows
  pub fn rows(&self) -> &[ConversationRowEntry] {
    &self.rows
  }

  /// Update a row's sequence to the DB-assigned value (single source of truth).
  pub fn set_row_sequence(&mut self, row_id: &str, sequence: u64) {
    if let Some(entry) = self.rows.iter_mut().find(|e| e.id() == row_id) {
      entry.sequence = sequence;
    }
  }

  /// Look up a row by ID.
  pub fn row_by_id(&self, row_id: &str) -> Option<&ConversationRowEntry> {
    self.rows.iter().find(|e| e.id() == row_id)
  }

  /// Get first prompt
  #[allow(dead_code)]
  pub fn first_prompt(&self) -> Option<&str> {
    self.display.first_prompt.as_deref()
  }

  /// Set codex integration mode
  pub fn set_codex_integration_mode(&mut self, mode: Option<CodexIntegrationMode>) {
    self.codex_integration_mode = mode;
    self.sync_control_mode_from_integrations();
    self.refresh_snapshot();
  }

  /// Set claude integration mode
  pub fn set_claude_integration_mode(&mut self, mode: Option<ClaudeIntegrationMode>) {
    self.claude_integration_mode = mode;
    self.sync_control_mode_from_integrations();
    self.refresh_snapshot();
  }

  /// Set the control mode directly.
  pub fn set_control_mode(&mut self, control_mode: SessionControlMode) {
    self.control_mode = control_mode;
    self.refresh_snapshot();
  }

  /// Set project name
  pub fn set_project_name(&mut self, project_name: Option<String>) {
    self.identity.project_name = project_name;
  }

  pub fn set_git_branch(&mut self, branch: Option<String>) {
    self.environment.git_branch = branch;
  }

  /// Set transcript path
  pub fn set_transcript_path(&mut self, transcript_path: Option<String>) {
    self.identity.transcript_path = transcript_path;
  }

  #[allow(dead_code)]
  pub fn transcript_path(&self) -> Option<&str> {
    self.identity.transcript_path.as_deref()
  }

  pub fn message_count(&self) -> usize {
    self.total_row_count as usize
  }

  /// Get the newest synced row ID (for transcript sync comparison).
  #[allow(dead_code)]
  pub fn newest_synced_row_id(&self) -> Option<&str> {
    self.newest_synced_row_id.as_deref()
  }

  /// Update the newest synced row ID after a successful transcript sync.
  #[allow(dead_code)]
  pub fn set_newest_synced_row_id(&mut self, id: Option<String>) {
    self.newest_synced_row_id = id;
  }

  /// Check if a user row with this content already exists (dedup for connector echo)
  #[allow(dead_code)]
  pub fn has_user_row_with_content(&self, content: &str) -> bool {
    self
      .rows
      .iter()
      .rev()
      .take(5)
      .any(|entry| match &entry.row {
        ConversationRow::User(row) => row.content == content,
        ConversationRow::Steer(_) => false,
        _ => false,
      })
  }

  /// Set model
  pub fn set_model(&mut self, model: Option<String>) {
    self.config.model = model;
    self.refresh_snapshot();
  }

  /// Set reasoning effort
  pub fn set_effort(&mut self, effort: Option<String>) {
    self.config.effort = effort;
    self.refresh_snapshot();
  }

  /// Set autonomy configuration
  pub fn set_config(&mut self, patch: SessionConfigPatch) {
    let has_approval_policy = patch.approval_policy.is_some();
    let has_codex_config_overrides = patch.codex_config_overrides.is_some();
    let had_explicit_details = patch.approval_policy_details.is_some();

    self.config.merge_from(patch);

    // Re-derive approval_policy_details when the patch touched policy or
    // overrides but did not supply an explicit details value.
    if !had_explicit_details && (has_approval_policy || has_codex_config_overrides) {
      self.config.approval_policy_details = resolve_approval_policy_details(
        self.config.approval_policy.as_deref(),
        self.config.codex_config_overrides.as_ref(),
      );
    }
    self.refresh_snapshot();
  }

  /// Set fork origin
  pub fn set_forked_from(&mut self, source_session_id: String) {
    self.forked_from_session_id = Some(source_session_id);
  }

  /// Set terminal session ID and app
  pub fn set_terminal_info(
    &mut self,
    terminal_session_id: Option<String>,
    terminal_app: Option<String>,
  ) {
    self.terminal_session_id = terminal_session_id;
    self.terminal_app = terminal_app;
  }

  /// Set worktree-related fields
  #[allow(dead_code)] // Used in Phase 6 (hook_handler enrichment)
  pub fn set_worktree_info(
    &mut self,
    repository_root: Option<String>,
    is_worktree: bool,
    worktree_id: Option<String>,
  ) {
    self.environment.repository_root = repository_root;
    self.environment.is_worktree = is_worktree;
    self.environment.worktree_id = worktree_id;
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn repository_root(&self) -> Option<&str> {
    self.environment.repository_root.as_deref()
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn is_worktree(&self) -> bool {
    self.environment.is_worktree
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn worktree_id(&self) -> Option<&str> {
    self.environment.worktree_id.as_deref()
  }

  /// Set status
  pub fn set_status(&mut self, status: SessionStatus) {
    self.status = status;
    if status == SessionStatus::Ended {
      self.clear_pending_approvals();
    }
  }

  /// Set started_at timestamp
  #[allow(dead_code)] // Reserved for follow-up session timing plumbing.
  pub fn set_started_at(&mut self, started_at: Option<String>) {
    self.timestamps.started_at = started_at;
  }

  /// Set last_activity_at timestamp
  pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
    self.timestamps.last_activity_at = last_activity_at;
  }

  /// Set work status
  pub fn set_work_status(&mut self, status: WorkStatus) {
    self.work_status = status;
    if status == WorkStatus::Ended {
      self.clear_pending_approvals();
    }
  }

  /// Get work status
  /// Set last tool name
  pub fn set_last_tool(&mut self, tool: Option<String>) {
    self.last_tool = tool;
  }

  /// Get last tool name
  pub fn last_tool(&self) -> Option<&str> {
    self.last_tool.as_deref()
  }

  /// Update token usage
  #[allow(dead_code)]
  pub fn update_tokens(&mut self, usage: TokenUsage) {
    self.token_usage = usage;
  }

  /// Add a conversation row
  pub fn add_row(&mut self, mut entry: ConversationRowEntry) -> ConversationRowEntry {
    let counts_as_progress = is_non_user_row(&entry);
    if entry.sequence == 0
      && self
        .rows
        .last()
        .is_none_or(|last| last.sequence >= entry.sequence)
    {
      entry.sequence = self.next_row_sequence();
    }
    if is_non_user_row(&entry) && !self.has_active_viewers() {
      self.unread_count += 1;
    }
    self.newest_synced_row_id = Some(entry.id().to_string());
    self.rows.push(entry.clone());
    self.total_row_count = self.total_row_count.saturating_add(1);
    self.trim_retained_rows();
    let now = chrono_now();
    self.timestamps.last_activity_at = Some(now.clone());
    if counts_as_progress {
      self.timestamps.last_progress_at = Some(now);
    }
    self.refresh_snapshot();
    entry
  }

  pub fn unread_count_after_row_append(&self, entry: &ConversationRowEntry) -> Option<u64> {
    (is_non_user_row(entry) && !self.has_active_viewers()).then_some(self.unread_count)
  }

  /// Replace an existing row by ID, or append if not found.
  /// Does NOT increment total_row_count when replacing or when the row
  /// was evicted from the retained window (already counted).
  pub fn upsert_row(&mut self, mut entry: ConversationRowEntry) -> ConversationRowEntry {
    let entry_id = entry.id().to_string();
    let counts_as_progress = is_non_user_row(&entry);
    if let Some(pos) = self.rows.iter().position(|r| r.id() == entry_id) {
      // Preserve the existing sequence
      if entry.sequence == 0 {
        entry.sequence = self.rows[pos].sequence;
      }
      self.rows[pos] = entry.clone();
      // Update newest_synced_row_id if this is the last row
      if pos == self.rows.len() - 1 {
        self.newest_synced_row_id = Some(entry_id);
      }
      let now = chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      self.refresh_snapshot();
      entry
    } else {
      // Row not in retained window — may be evicted rather than new.
      // Append directly without going through add_row() to avoid
      // false count inflation for evicted rows.
      if entry.sequence == 0
        && self
          .rows
          .last()
          .is_none_or(|last| last.sequence >= entry.sequence)
      {
        entry.sequence = self.next_row_sequence();
      }
      self.newest_synced_row_id = Some(entry.id().to_string());
      self.rows.push(entry.clone());
      // Only increment count if this is genuinely new (not evicted).
      // Evicted rows have total_row_count >> rows.len().
      if self.rows.len() as u64 > self.total_row_count {
        self.total_row_count = self.rows.len() as u64;
      }
      self.trim_retained_rows();
      let now = chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      self.refresh_snapshot();
      entry
    }
  }

  /// Increment unread for an already-applied row append in the transition path.
  ///
  /// `dispatch_transition_input` applies the connector state machine result directly,
  /// so it cannot call `add_row` without duplicating the row in memory.
  /// This keeps the in-memory unread count aligned with the persisted count.
  pub fn note_transition_row_append(&mut self, entry: &RowEntrySummary) -> Option<u64> {
    if !is_non_user_row_summary(entry) || self.has_active_viewers() {
      return None;
    }

    self.unread_count += 1;
    Some(self.unread_count)
  }

  /// Mark the session as fully read. Returns the previous unread count.
  pub fn mark_read(&mut self) -> u64 {
    let prev = self.unread_count;
    self.unread_count = 0;
    prev
  }

  /// Get current unread count
  pub fn unread_count(&self) -> u64 {
    self.unread_count
  }

  /// Total row count across all retained + evicted rows.
  pub fn total_row_count(&self) -> u64 {
    self.total_row_count
  }

  /// Mark the last `num_turns` worth of rows with the given status.
  ///
  /// A "turn" starts at each user row. Walking from the end we count user
  /// rows to find the boundary; all rows from that boundary to the end get
  /// marked. Returns the IDs of affected rows (for persistence + broadcast).
  pub fn mark_last_turns_status(&mut self, num_turns: u32, status: TurnStatus) -> Vec<String> {
    if self.rows.is_empty() || num_turns == 0 {
      return vec![];
    }

    // Walk backwards, count user rows to find the cut-off index.
    let mut user_rows_seen: u32 = 0;
    let mut cut_index = self.rows.len();
    for (i, entry) in self.rows.iter().enumerate().rev() {
      if matches!(entry.row, ConversationRow::User(_)) {
        user_rows_seen += 1;
        if user_rows_seen >= num_turns {
          cut_index = i;
          break;
        }
      }
    }

    let mut affected_ids = Vec::new();
    for entry in &mut self.rows[cut_index..] {
      if entry.turn_status != status {
        entry.turn_status = status;
        affected_ids.push(entry.id().to_string());
      }
    }
    affected_ids
  }

  /// Replace all rows (used for snapshot hydration from transcript fallback)
  pub fn replace_rows(&mut self, mut rows: Vec<ConversationRowEntry>) {
    Self::normalize_row_sequences(&mut rows);
    self.newest_synced_row_id = rows.last().map(|r| r.id().to_string());
    self.total_row_count = rows.len() as u64;
    self.rows = rows;
    self.streaming_row_emit_at.clear();
    self.trim_retained_rows();
    self.timestamps.last_progress_at = Some(chrono_now());
  }

  pub fn should_emit_streaming_row_update(&mut self, upserted: &[RowEntrySummary]) -> bool {
    if upserted.len() != 1 {
      for entry in upserted {
        if !is_actively_streaming_message_row_summary(entry) {
          self.streaming_row_emit_at.remove(entry.id());
        }
      }
      return true;
    }

    let entry = &upserted[0];
    if !is_message_row_summary(entry) {
      self.streaming_row_emit_at.remove(entry.id());
      return true;
    }
    if !is_actively_streaming_message_row_summary(entry) {
      self.streaming_row_emit_at.remove(entry.id());
      return true;
    }

    let content_len = streaming_message_row_summary_content_len(entry).unwrap_or(0);
    let now = Instant::now();
    match self.streaming_row_emit_at.get_mut(entry.id()) {
      Some(state) => {
        let force_emit_for_growth =
          content_len >= state.last_emitted_content_len + STREAMING_ROW_FORCE_EMIT_CONTENT_STEP;
        if !force_emit_for_growth
          && now.duration_since(state.last_emit_at) < STREAMING_ROW_BROADCAST_THROTTLE
        {
          false
        } else {
          state.last_emit_at = now;
          state.last_emitted_content_len = content_len;
          true
        }
      }
      None => {
        self.streaming_row_emit_at.insert(
          entry.id().to_string(),
          StreamingRowEmitState {
            last_emit_at: now,
            last_emitted_content_len: 0,
          },
        );
        content_len >= STREAMING_ROW_MIN_INITIAL_EMIT_CHARS
      }
    }
  }

  /// Update aggregated diff
  #[allow(dead_code)]
  pub fn update_diff(&mut self, diff: String) {
    self.current_diff = Some(diff);
  }

  /// Update plan
  #[allow(dead_code)]
  pub fn update_plan(&mut self, plan: String) {
    self.current_plan = Some(plan);
  }

  fn inferred_approval_type_from_pending_fields(&self) -> ApprovalType {
    if self.pending_question.is_some() {
      return ApprovalType::Question;
    }
    if let Some(tool_name) = self.pending_tool_name.as_ref() {
      let normalized = tool_name.to_ascii_lowercase();
      if normalized.contains("edit") || normalized.contains("patch") || normalized.contains("write")
      {
        return ApprovalType::Patch;
      }
    }
    ApprovalType::Exec
  }

  fn work_status_for_approval_type(approval_type: ApprovalType) -> WorkStatus {
    match approval_type {
      ApprovalType::Question => WorkStatus::Question,
      ApprovalType::Exec | ApprovalType::Patch | ApprovalType::Permissions => {
        WorkStatus::Permission
      }
    }
  }

  /// Get the current approval version.
  pub fn approval_version(&self) -> u64 {
    self.approval_version
  }

  fn is_active_pending_approval(&self, entry: &PendingApprovalEntry) -> bool {
    self
      .pending_approval
      .as_ref()
      .is_some_and(|current| approval_requests_effectively_equal(current, &entry.request))
      && self.pending_tool_name == fallback_tool_name(&entry.request)
      && self.pending_tool_input == fallback_tool_input(&entry.request)
      && self.pending_question.as_deref() == entry.request.question.as_deref()
      && self.pending_approval_id.as_deref() == Some(entry.request.id.as_str())
      && self.work_status == Self::work_status_for_approval_type(entry.approval_type)
  }

  fn queue_pending_approval(
    &mut self,
    approval: ApprovalRequest,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
  ) -> PendingApprovalMutation {
    let normalized_request_id = normalize_request_id(&approval.id).to_string();
    let next_entry = PendingApprovalEntry {
      request: approval,
      approval_type,
      proposed_amendment,
    };
    if let Some(index) = self
      .pending_approvals
      .iter()
      .position(|entry| normalize_request_id(&entry.request.id) == normalized_request_id)
    {
      if let Some(existing) = self.pending_approvals.get_mut(index) {
        if pending_approval_entries_effectively_equal(existing, &next_entry) {
          return PendingApprovalMutation::Unchanged;
        }
        *existing = next_entry;
      }
      self.approval_version += 1;
      info!(
          component = "approval",
          event = "approval.updated",
          session_id = %self.identity.id,
          request_id = %normalized_request_id,
          approval_version = self.approval_version,
          approval_type = ?self.pending_approvals[index].approval_type,
          queue_depth = self.pending_approvals.len(),
          "Approval request updated in place"
      );
      return PendingApprovalMutation::Updated;
    }

    self.pending_approvals.push_back(next_entry);
    self.approval_version += 1;
    info!(
        component = "approval",
        event = "approval.enqueued",
        session_id = %self.identity.id,
        request_id = %normalized_request_id,
        approval_version = self.approval_version,
        approval_type = ?self.pending_approvals.back().map(|entry| entry.approval_type).unwrap_or(approval_type),
        queue_depth = self.pending_approvals.len(),
        "Approval request enqueued"
    );
    PendingApprovalMutation::Enqueued
  }

  fn promote_queue_front(&mut self) {
    if let Some(entry) = self.pending_approvals.front() {
      if self.is_active_pending_approval(entry) {
        return;
      }
      self.pending_approval = Some(entry.request.clone());
      self.pending_tool_name = fallback_tool_name(&entry.request);
      self.pending_tool_input = fallback_tool_input(&entry.request);
      self.pending_question = entry.request.question.clone();
      self.pending_approval_id = Some(entry.request.id.clone());
      self.work_status = Self::work_status_for_approval_type(entry.approval_type);
      info!(
          component = "approval",
          event = "approval.promoted",
          session_id = %self.identity.id,
          request_id = %entry.request.id,
          approval_version = self.approval_version,
          approval_type = ?entry.approval_type,
          queue_depth = self.pending_approvals.len(),
          "Promoted next approval to active"
      );
      return;
    }

    let had_active_pending = self.pending_approval.is_some()
      || self.pending_tool_name.is_some()
      || self.pending_tool_input.is_some()
      || self.pending_question.is_some()
      || self.pending_approval_id.is_some();
    if !had_active_pending {
      return;
    }
    self.pending_approval = None;
    self.pending_tool_name = None;
    self.pending_tool_input = None;
    self.pending_question = None;
    self.pending_approval_id = None;
  }

  fn clear_pending_approvals(&mut self) {
    let had_approvals = !self.pending_approvals.is_empty() || self.pending_approval.is_some();
    let cleared_count = self.pending_approvals.len();
    self.pending_approvals.clear();
    self.pending_approval = None;
    self.pending_tool_name = None;
    self.pending_tool_input = None;
    self.pending_question = None;
    self.pending_approval_id = None;
    if had_approvals {
      self.approval_version += 1;
      info!(
          component = "approval",
          event = "approval.cleared",
          session_id = %self.identity.id,
          approval_version = self.approval_version,
          cleared_count,
          "Cleared all pending approvals"
      );
    }
  }

  fn bootstrap_pending_approval_from_persisted_fields(&mut self) {
    if self.pending_approvals.is_empty() {
      if let Some(request_id) = self.pending_approval_id.clone() {
        let approval_type = self.inferred_approval_type_from_pending_fields();
        let approval = ApprovalRequest {
          id: request_id,
          session_id: self.identity.id.clone(),
          approval_type,
          tool_name: self.pending_tool_name.clone(),
          tool_input: self.pending_tool_input.clone(),
          command: None,
          file_path: None,
          diff: None,
          question: self.pending_question.clone(),
          question_prompts: extract_question_prompts(
            self.pending_tool_input.as_deref(),
            self.pending_question.as_deref(),
          ),
          preview: preview_for_pending_approval(
            self.pending_approval_id.as_deref(),
            approval_type,
            self.pending_tool_name.as_deref(),
            self.pending_tool_input.as_deref(),
            self.pending_question.as_deref(),
          ),
          permission_reason: None,
          requested_permissions: None,
          granted_permissions: None,
          proposed_amendment: None,
          permission_suggestions: None,
          elicitation_mode: None,
          elicitation_schema: None,
          elicitation_url: None,
          elicitation_message: None,
          mcp_server_name: None,
          network_host: None,
          network_protocol: None,
        };
        self.queue_pending_approval(approval, approval_type, None);
        self.promote_queue_front();
      }
    }
  }

  /// Register a pending approval with optional proposed amendment and tool metadata.
  pub fn set_pending_approval(
    &mut self,
    request_id: String,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
    tool_name: Option<String>,
    tool_input: Option<String>,
    question: Option<String>,
  ) {
    let question_prompts = extract_question_prompts(tool_input.as_deref(), question.as_deref());
    let resolved_question = question.or_else(|| {
      question_prompts
        .first()
        .map(|p| p.question.clone())
        .filter(|t| !t.is_empty())
    });
    let preview = preview_for_pending_approval(
      Some(request_id.as_str()),
      approval_type,
      tool_name.as_deref(),
      tool_input.as_deref(),
      resolved_question.as_deref(),
    );
    let request = ApprovalRequest {
      id: request_id,
      session_id: self.identity.id.clone(),
      approval_type,
      tool_name,
      tool_input,
      command: None,
      file_path: None,
      diff: None,
      question: resolved_question,
      question_prompts,
      preview,
      permission_reason: None,
      requested_permissions: None,
      granted_permissions: None,
      proposed_amendment: proposed_amendment.clone(),
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    };
    self.queue_pending_approval(request, approval_type, proposed_amendment);
    self.promote_queue_front();
  }

  /// Resolve a pending approval request and promote the next queued request.
  pub fn resolve_pending_approval(
    &mut self,
    request_id: &str,
    fallback_work_status: WorkStatus,
  ) -> (
    Option<ApprovalType>,
    Option<Vec<String>>,
    Option<ApprovalRequest>,
    WorkStatus,
  ) {
    let Some(head) = self.pending_approvals.front() else {
      return (None, None, self.pending_approval.clone(), self.work_status);
    };
    if normalize_request_id(&head.request.id) != normalize_request_id(request_id) {
      return (None, None, self.pending_approval.clone(), self.work_status);
    }

    let removed = self
      .pending_approvals
      .pop_front()
      .expect("pending approval queue should have head entry");
    let removed_request_id = normalize_request_id(&removed.request.id);
    while matches!(
        self.pending_approvals.front(),
        Some(entry) if normalize_request_id(&entry.request.id) == removed_request_id
    ) {
      let _ = self.pending_approvals.pop_front();
    }
    self.approval_version += 1;
    info!(
        component = "approval",
        event = "approval.decided",
        session_id = %self.identity.id,
        request_id = %removed.request.id,
        approval_version = self.approval_version,
        approval_type = ?removed.approval_type,
        queue_depth = self.pending_approvals.len(),
        "Approval decided and removed from queue"
    );
    self.promote_queue_front();
    if self.pending_approvals.is_empty() {
      self.work_status = fallback_work_status;
    }

    (
      Some(removed.approval_type),
      removed.proposed_amendment,
      self.pending_approval.clone(),
      self.work_status,
    )
  }

  /// Apply a `StateChanges` delta to the handle fields.
  /// Each `Some` field overwrites the corresponding handle field.
  pub fn apply_changes(&mut self, changes: &StateChanges) {
    if let Some(status) = changes.status {
      self.status = status;
    }
    if let Some(work_status) = changes.work_status {
      self.work_status = work_status;
    }
    if let Some(lifecycle_state) = changes.lifecycle_state {
      self.lifecycle_state = lifecycle_state;
    }
    if let Some(steerable) = changes.steerable {
      self.steerable = steerable;
    }
    if let Some(ref pending_approval) = changes.pending_approval {
      if let Some(approval) = pending_approval.as_ref() {
        self.queue_pending_approval(
          approval.clone(),
          approval.approval_type,
          approval.proposed_amendment.clone(),
        );
      } else {
        self.clear_pending_approvals();
      }
    }
    // Display facet
    if let Some(ref custom_name) = changes.custom_name {
      self.display.custom_name = custom_name.clone();
    }
    if let Some(ref summary) = changes.summary {
      self.display.summary = summary.clone();
    }
    // Config facet
    if let Some(ref model) = changes.model {
      self.config.model = model.clone();
    }
    if let Some(ref approval_policy) = changes.approval_policy {
      self.config.approval_policy = approval_policy.clone();
    }
    if let Some(ref approval_policy_details) = changes.approval_policy_details {
      self.config.approval_policy_details = approval_policy_details.clone();
    }
    if let Some(ref sandbox_mode) = changes.sandbox_mode {
      self.config.sandbox_mode = sandbox_mode.clone();
    }
    if let Some(ref permission_mode) = changes.permission_mode {
      self.permission_mode = permission_mode.clone();
    }
    if let Some(ref collaboration_mode) = changes.collaboration_mode {
      self.config.collaboration_mode = collaboration_mode.clone();
    }
    if let Some(multi_agent) = changes.multi_agent {
      self.config.multi_agent = multi_agent;
    }
    if let Some(ref personality) = changes.personality {
      self.config.personality = personality.clone();
    }
    if let Some(ref service_tier) = changes.service_tier {
      self.config.service_tier = service_tier.clone();
    }
    if let Some(ref developer_instructions) = changes.developer_instructions {
      self.config.developer_instructions = developer_instructions.clone();
    }
    if let Some(codex_config_mode) = changes.codex_config_mode {
      self.config.codex_config_mode = codex_config_mode;
    }
    if let Some(ref codex_config_profile) = changes.codex_config_profile {
      self.config.codex_config_profile = codex_config_profile.clone();
    }
    if let Some(ref codex_model_provider) = changes.codex_model_provider {
      self.config.codex_model_provider = codex_model_provider.clone();
    }
    if let Some(codex_config_source) = changes.codex_config_source {
      self.config.codex_config_source = codex_config_source;
    }
    if let Some(ref codex_config_overrides) = changes.codex_config_overrides {
      self.config.codex_config_overrides = codex_config_overrides.clone();
    }
    if changes.approval_policy_details.is_none()
      && (changes.approval_policy.is_some() || changes.codex_config_overrides.is_some())
    {
      self.config.approval_policy_details = resolve_approval_policy_details(
        self.config.approval_policy.as_deref(),
        self.config.codex_config_overrides.as_ref(),
      );
    }
    if let Some(ref codex_integration_mode) = changes.codex_integration_mode {
      self.codex_integration_mode = *codex_integration_mode;
    }
    if let Some(ref claude_integration_mode) = changes.claude_integration_mode {
      self.claude_integration_mode = *claude_integration_mode;
    }
    // Timestamps facet
    if let Some(ref last_activity_at) = changes.last_activity_at {
      self.timestamps.last_activity_at = Some(last_activity_at.clone());
    }
    if let Some(ref last_progress_at) = changes.last_progress_at {
      self.timestamps.last_progress_at = Some(last_progress_at.clone());
    }
    if let Some(ref token_usage) = changes.token_usage {
      self.token_usage = token_usage.clone();
    }
    if let Some(snapshot_kind) = changes.token_usage_snapshot_kind {
      self.token_usage_snapshot_kind = snapshot_kind;
    }
    if let Some(ref current_diff) = changes.current_diff {
      self.current_diff = current_diff.clone();
    }
    if let Some(ref current_plan) = changes.current_plan {
      self.current_plan = current_plan.clone();
    }
    if let Some(ref current_turn_id) = changes.current_turn_id {
      self.current_turn_id = current_turn_id.clone();
    }
    if let Some(turn_count) = changes.turn_count {
      self.turn_count = turn_count;
    }
    // Environment facet
    if let Some(ref git_branch) = changes.git_branch {
      self.environment.git_branch = git_branch.clone();
    }
    if let Some(ref git_sha) = changes.git_sha {
      self.environment.git_sha = git_sha.clone();
    }
    if let Some(ref current_cwd) = changes.current_cwd {
      self.environment.current_cwd = current_cwd.clone();
    }
    if let Some(ref subagents) = changes.subagents {
      self.subagents = subagents.clone();
    }
    // Display facet
    if let Some(ref first_prompt) = changes.first_prompt {
      self.display.first_prompt = first_prompt.clone();
    }
    if let Some(ref last_message) = changes.last_message {
      self.display.last_message = last_message.clone();
    }
    if let Some(ref effort) = changes.effort {
      self.config.effort = effort.clone();
    }

    if self.status == SessionStatus::Ended || self.work_status == WorkStatus::Ended {
      self.clear_pending_approvals();
    } else if !self.pending_approvals.is_empty() {
      self.promote_queue_front();
    } else if !matches!(
      self.work_status,
      WorkStatus::Permission | WorkStatus::Question
    ) {
      self.pending_approval = None;
      self.pending_tool_name = None;
      self.pending_tool_input = None;
      self.pending_question = None;
      self.pending_approval_id = None;
    }
  }

  /// Create a snapshot of current session metadata
  pub fn to_snapshot(&self) -> SessionSnapshot {
    SessionSnapshot {
      id: self.identity.id.clone(),
      provider: self.identity.provider,
      status: self.status,
      work_status: self.work_status,
      control_mode: self.control_mode,
      lifecycle_state: self.lifecycle_state,
      steerable: self.steerable,
      project_path: self.identity.project_path.clone(),
      project_name: self.identity.project_name.clone(),
      transcript_path: self.identity.transcript_path.clone(),
      custom_name: self.display.custom_name.clone(),
      summary: self.display.summary.clone(),
      model: self.config.model.clone(),
      codex_integration_mode: self.codex_integration_mode,
      claude_integration_mode: self.claude_integration_mode,
      approval_policy: self.config.approval_policy.clone(),
      approval_policy_details: self.config.approval_policy_details.clone(),
      sandbox_mode: self.config.sandbox_mode.clone(),
      permission_mode: self.permission_mode.clone(),
      collaboration_mode: self.config.collaboration_mode.clone(),
      multi_agent: self.config.multi_agent,
      personality: self.config.personality.clone(),
      service_tier: self.config.service_tier.clone(),
      developer_instructions: self.config.developer_instructions.clone(),
      codex_config_mode: self.config.codex_config_mode,
      codex_config_profile: self.config.codex_config_profile.clone(),
      codex_model_provider: self.config.codex_model_provider.clone(),
      codex_config_source: self.config.codex_config_source,
      codex_config_overrides: self.config.codex_config_overrides.clone(),
      has_pending_approval: self.pending_approval.is_some()
        || self.pending_tool_name.is_some()
        || self.pending_question.is_some()
        || self.pending_approval_id.is_some(),
      pending_tool_name: self.pending_tool_name.clone(),
      pending_tool_input: self.pending_tool_input.clone(),
      pending_question: self.pending_question.clone(),
      pending_approval_id: self
        .pending_approval_id
        .clone()
        .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
      message_count: self.total_row_count as usize,
      active_worker_count: self
        .subagents
        .iter()
        .filter(|subagent| subagent.ended_at.is_none())
        .count() as u32,
      token_usage: self.token_usage.clone(),
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      started_at: self.timestamps.started_at.clone(),
      last_activity_at: self.timestamps.last_activity_at.clone(),
      last_progress_at: self.timestamps.last_progress_at.clone(),
      revision: self.revision,
      current_plan: self.current_plan.clone(),
      current_diff: self.current_diff.clone(),
      git_branch: self.environment.git_branch.clone(),
      git_sha: self.environment.git_sha.clone(),
      current_cwd: self.environment.current_cwd.clone(),
      effort: self.config.effort.clone(),
      first_prompt: self.display.first_prompt.clone(),
      last_message: self.display.last_message.clone(),
      terminal_session_id: self.terminal_session_id.clone(),
      terminal_app: self.terminal_app.clone(),
      approval_version: self.approval_version,
      repository_root: self.environment.repository_root.clone(),
      is_worktree: self.environment.is_worktree,
      worktree_id: self.environment.worktree_id.clone(),
      has_turn_diff: self.current_diff.is_some() || !self.turn_diffs.is_empty(),
      subscriber_count: self.broadcast_tx.receiver_count(),
      unread_count: self.unread_count,
      mission_id: self.mission_id.clone(),
      issue_identifier: self.issue_identifier.clone(),
      allow_bypass_permissions: self.allow_bypass_permissions,
      newest_synced_row_id: self.newest_synced_row_id.clone(),
    }
  }

  /// Update the ArcSwap snapshot (call after mutations)
  pub fn refresh_snapshot(&self) {
    self.snapshot_handle.store(Arc::new(self.to_snapshot()));
  }

  /// Get the ArcSwap handle for lock-free reads
  pub fn snapshot_arc(&self) -> Arc<ArcSwap<SessionSnapshot>> {
    self.snapshot_handle.clone()
  }

  /// Broadcast a message to all subscribers
  pub fn broadcast(&mut self, msg: orbitdock_protocol::ServerMessage) {
    self.revision += 1;
    let rev = self.revision;
    let msg = sanitize_server_message_for_transport(msg);

    // Pre-serialize with revision for event log
    if let Ok(json) = serialize_with_revision(&msg, rev) {
      self.event_log.push_back((rev, json));
      if self.event_log.len() > EVENT_LOG_CAPACITY {
        self.event_log.pop_front();
      }
    }

    // Non-blocking fan-out to all receivers
    let _ = self.broadcast_tx.send(msg.clone());

    // Forward session-level events to list subscribers (dashboard sidebar).
    // Per-message events (streaming deltas, message appends, etc.) are too
    // frequent and overflow the list channel during active turns.
    if let Some(ref list_tx) = self.list_tx {
      if is_list_relevant(&msg) {
        let should_emit_dashboard = should_emit_dashboard_invalidation(&msg);
        let _ = list_tx.send(msg);
        if should_emit_dashboard {
          if let Some(ref dashboard_revision) = self.dashboard_revision {
            let revision = dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
            let _ = list_tx.send(ServerMessage::DashboardInvalidated { revision });
          }
        }
      }
    }

    // Update lock-free snapshot
    self.refresh_snapshot();
  }

  /// Replay events since a given revision.
  /// Returns `None` if the gap is too large (caller should send a retained snapshot fallback).
  pub fn replay_since(&self, since_revision: u64) -> Option<Vec<String>> {
    let oldest = self.event_log.front().map(|(rev, _)| *rev)?;
    if oldest > since_revision + 1 {
      return None; // Gap too large, need a retained snapshot fallback.
    }
    let events: Vec<String> = self
      .event_log
      .iter()
      .filter(|(rev, _)| *rev > since_revision)
      .map(|(_, json)| json.clone())
      .collect();
    Some(events)
  }

  // -- Transition bridge (temporary until Phase 4 actor model) ---------------

  /// Extract a pure data snapshot for the transition function
  pub fn extract_state(&self) -> TransitionState {
    let phase = if let Some(entry) = self.pending_approvals.front() {
      WorkPhase::AwaitingApproval {
        request_id: entry.request.id.clone(),
        approval_type: entry.approval_type,
        proposed_amendment: entry.proposed_amendment.clone(),
      }
    } else {
      match self.work_status {
        WorkStatus::Working => WorkPhase::Working,
        WorkStatus::Permission => WorkPhase::AwaitingApproval {
          request_id: String::new(),
          approval_type: ApprovalType::Exec,
          proposed_amendment: None,
        },
        WorkStatus::Question => WorkPhase::AwaitingApproval {
          request_id: String::new(),
          approval_type: ApprovalType::Question,
          proposed_amendment: None,
        },
        WorkStatus::Ended => WorkPhase::Ended {
          reason: String::new(),
        },
        _ => WorkPhase::Idle,
      }
    };

    TransitionState {
      id: self.identity.id.clone(),
      provider: self.identity.provider,
      revision: self.revision,
      phase,
      rows: self.rows.clone(),
      // Derive from sequences, not the inflatable counter
      total_row_count: self.rows.last().map(|r| r.sequence + 1).unwrap_or(0),
      token_usage: self.token_usage.clone(),
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      current_diff: self.current_diff.clone(),
      current_plan: self.current_plan.clone(),
      custom_name: self.display.custom_name.clone(),
      project_path: self.identity.project_path.clone(),
      last_activity_at: self.timestamps.last_activity_at.clone(),
      last_progress_at: self.timestamps.last_progress_at.clone(),
      current_turn_id: self.current_turn_id.clone(),
      turn_count: self.turn_count,
      turn_diffs: self.turn_diffs.clone(),
      git_branch: self.environment.git_branch.clone(),
      git_sha: self.environment.git_sha.clone(),
      current_cwd: self.environment.current_cwd.clone(),
      pending_approval: self.pending_approval.clone(),
      repository_root: self.environment.repository_root.clone(),
      is_worktree: self.environment.is_worktree,
    }
  }

  /// Apply the transition result back to this handle
  pub fn apply_state(&mut self, state: TransitionState) {
    let phase = state.phase.clone();
    self.work_status = phase.to_work_status();
    self.rows = state.rows;
    self.total_row_count = state.total_row_count;
    self.newest_synced_row_id = self.rows.last().map(|row| row.id().to_string());
    self.token_usage = state.token_usage;
    self.token_usage_snapshot_kind = state.token_usage_snapshot_kind;
    self.current_diff = state.current_diff;
    self.current_plan = state.current_plan;
    self.display.custom_name = state.custom_name;
    self.timestamps.last_activity_at = state.last_activity_at;
    self.timestamps.last_progress_at = state.last_progress_at;
    self.current_turn_id = state.current_turn_id;
    self.turn_count = state.turn_count;
    self.turn_diffs = state.turn_diffs;
    self.environment.git_branch = state.git_branch;
    self.environment.git_sha = state.git_sha;
    self.environment.current_cwd = state.current_cwd;
    self.environment.repository_root = state.repository_root;
    self.environment.is_worktree = state.is_worktree;

    if let Some(approval) = state.pending_approval {
      let (approval_type, proposed_amendment) = match &phase {
        WorkPhase::AwaitingApproval {
          approval_type,
          proposed_amendment,
          ..
        } => (*approval_type, proposed_amendment.clone()),
        _ => (approval.approval_type, approval.proposed_amendment.clone()),
      };
      self.queue_pending_approval(approval, approval_type, proposed_amendment);
    }

    if matches!(phase, WorkPhase::Ended { .. }) {
      self.clear_pending_approvals();
    } else if !self.pending_approvals.is_empty() {
      self.promote_queue_front();
    } else if !matches!(
      self.work_status,
      WorkStatus::Permission | WorkStatus::Question
    ) {
      self.pending_approval = None;
      self.pending_tool_name = None;
      self.pending_tool_input = None;
      self.pending_question = None;
      self.pending_approval_id = None;
    }

    self.trim_retained_rows();
    self.refresh_snapshot();
  }
}

/// Serialize a ServerMessage with a revision field injected at the top level
fn serialize_with_revision(
  msg: &orbitdock_protocol::ServerMessage,
  revision: u64,
) -> Result<String, serde_json::Error> {
  let mut val = serde_json::to_value(msg)?;
  if let Some(obj) = val.as_object_mut() {
    obj.insert("revision".to_string(), serde_json::json!(revision));
  }
  serde_json::to_string(&val)
}

fn chrono_now() -> String {
  crate::support::session_time::chrono_now()
}

fn normalize_request_id(value: &str) -> &str {
  value.trim()
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::support::session_time::parse_unix_z;
  use orbitdock_protocol::conversation_contracts::{
    rows::MessageDeliveryStatus, CommandExecutionRow, CommandExecutionStatus,
    CommandExecutionTerminalSnapshot, MessageRowContent,
  };
  use std::sync::atomic::AtomicU64;
  use std::sync::Arc;

  fn session_handle(provider: Provider) -> SessionHandle {
    SessionHandle::new("session-1".to_string(), provider, "/repo".to_string())
  }

  fn pending_approval_session() -> SessionHandle {
    session_handle(Provider::Claude)
  }

  fn user_entry(session_id: &str, row_id: &str, content: &str) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: session_id.to_string(),
      sequence: 0,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::User(MessageRowContent {
        id: row_id.to_string(),
        content: content.to_string(),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    }
  }

  fn command_entry_with_large_payload(
    session_id: &str,
    row_id: &str,
    aggregated_output: String,
  ) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: session_id.to_string(),
      sequence: 0,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::CommandExecution(CommandExecutionRow {
        id: row_id.to_string(),
        status: CommandExecutionStatus::Completed,
        command: "cat big.log".to_string(),
        cwd: "/tmp".to_string(),
        process_id: None,
        command_actions: vec![],
        live_output_preview: None,
        aggregated_output: Some(aggregated_output),
        terminal_snapshot: Some(CommandExecutionTerminalSnapshot {
          command: "cat big.log".to_string(),
          cwd: "/tmp".to_string(),
          output: Some("payload".to_string()),
          transcript: "payload".to_string(),
          title: "/tmp".to_string(),
        }),
        preview: None,
        exit_code: Some(0),
        duration_ms: Some(1),
        render_hints:
          orbitdock_protocol::conversation_contracts::render_hints::RenderHints::default(),
      }),
    }
  }

  #[test]
  fn list_relevant_includes_session_delta() {
    let message = ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::default(),
    };
    assert!(is_list_relevant(&message));
  }

  #[test]
  fn list_relevant_excludes_conversation_row_stream_updates() {
    let message = ServerMessage::ConversationRowsChanged {
      session_id: "session-1".to_string(),
      upserted: vec![],
      removed_row_ids: vec![],
      total_row_count: 0,
    };
    assert!(!is_list_relevant(&message));
  }

  #[test]
  fn list_relevant_session_delta_emits_dashboard_invalidation() {
    let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
    let dashboard_revision = Arc::new(AtomicU64::new(0));
    let mut session = session_handle(Provider::Codex);
    session.set_list_tx(list_tx);
    session.set_dashboard_revision_counter(dashboard_revision);

    session.broadcast(ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Working),
        ..Default::default()
      }),
    });

    let first = list_rx
      .try_recv()
      .expect("session delta should be forwarded");
    assert!(matches!(first, ServerMessage::SessionDelta { .. }));

    let second = list_rx
      .try_recv()
      .expect("dashboard invalidation should be emitted");
    assert!(matches!(
      second,
      ServerMessage::DashboardInvalidated { revision: 1 }
    ));
  }

  #[test]
  fn summary_delta_emits_dashboard_invalidation() {
    let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
    let dashboard_revision = Arc::new(AtomicU64::new(0));
    let mut session = session_handle(Provider::Codex);
    session.set_list_tx(list_tx);
    session.set_dashboard_revision_counter(dashboard_revision);

    session.broadcast(ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        summary: Some(Some("New summary".to_string())),
        ..Default::default()
      }),
    });

    let first = list_rx
      .try_recv()
      .expect("session delta should be forwarded");
    assert!(matches!(first, ServerMessage::SessionDelta { .. }));

    let second = list_rx
      .try_recv()
      .expect("dashboard invalidation should be emitted");
    assert!(matches!(
      second,
      ServerMessage::DashboardInvalidated { revision: 1 }
    ));
  }

  #[test]
  fn conversation_event_log_omits_heavy_command_payloads() {
    let mut session = session_handle(Provider::Codex);
    let row = command_entry_with_large_payload("session-1", "cmd-1", "x".repeat(25_000));
    let summary = row.to_summary();

    session.broadcast(ServerMessage::ConversationRowsChanged {
      session_id: "session-1".to_string(),
      upserted: vec![summary],
      removed_row_ids: vec![],
      total_row_count: 1,
    });

    let replay = session.replay_since(0).expect("replay");
    let payload = replay.first().expect("event payload");
    assert!(!payload.contains("\"aggregated_output\""));
    assert!(!payload.contains("\"terminal_snapshot\""));
    assert!(payload.contains("\"live_output_preview\""));
  }

  #[test]
  fn duplicate_pending_approval_is_a_no_op() {
    let mut session = pending_approval_session();

    session.set_pending_approval(
      "approval-1".to_string(),
      ApprovalType::Exec,
      None,
      Some("Bash".to_string()),
      Some("{\"command\":\"ls\"}".to_string()),
      None,
    );
    let version_after_first = session.approval_version();

    session.set_pending_approval(
      "approval-1".to_string(),
      ApprovalType::Exec,
      None,
      Some("Bash".to_string()),
      Some("{\"command\":\"ls\"}".to_string()),
      None,
    );

    assert_eq!(session.approval_version(), version_after_first);
    assert_eq!(session.pending_approvals.len(), 1);
    assert_eq!(session.pending_approval_id.as_deref(), Some("approval-1"));
  }

  #[test]
  fn control_mode_from_parts_uses_provider_specific_integration_mode() {
    assert_eq!(
      control_mode_from_parts(Provider::Codex, Some(CodexIntegrationMode::Direct), None),
      SessionControlMode::Direct
    );
    assert_eq!(
      control_mode_from_parts(Provider::Codex, Some(CodexIntegrationMode::Passive), None),
      SessionControlMode::Passive
    );
    assert_eq!(
      control_mode_from_parts(Provider::Claude, None, Some(ClaudeIntegrationMode::Direct)),
      SessionControlMode::Direct
    );
    assert_eq!(
      control_mode_from_parts(Provider::Claude, None, Some(ClaudeIntegrationMode::Passive)),
      SessionControlMode::Passive
    );
  }

  #[test]
  fn accepts_user_input_from_parts_requires_direct_open_active_sessions() {
    assert!(accepts_user_input_from_parts(
      SessionStatus::Active,
      SessionControlMode::Direct,
      SessionLifecycleState::Open,
    ));
    assert!(!accepts_user_input_from_parts(
      SessionStatus::Active,
      SessionControlMode::Direct,
      SessionLifecycleState::Resumable,
    ));
    assert!(!accepts_user_input_from_parts(
      SessionStatus::Active,
      SessionControlMode::Passive,
      SessionLifecycleState::Open,
    ));
    assert!(!accepts_user_input_from_parts(
      SessionStatus::Ended,
      SessionControlMode::Direct,
      SessionLifecycleState::Open,
    ));
  }

  #[test]
  fn conversation_bootstrap_projects_direct_active_sessions_as_open_and_sendable() {
    let mut session = session_handle(Provider::Codex);
    session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Waiting);

    let bootstrap = session.conversation_bootstrap(10);

    assert_eq!(bootstrap.session.control_mode, SessionControlMode::Direct);
    assert_eq!(
      bootstrap.session.lifecycle_state,
      SessionLifecycleState::Open
    );
    assert!(bootstrap.session.accepts_user_input);
  }

  #[test]
  fn conversation_bootstrap_projects_passive_sessions_as_open_but_not_sendable() {
    let mut session = session_handle(Provider::Codex);
    session.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Waiting);

    let bootstrap = session.conversation_bootstrap(10);

    assert_eq!(bootstrap.session.control_mode, SessionControlMode::Passive);
    assert_eq!(
      bootstrap.session.lifecycle_state,
      SessionLifecycleState::Open
    );
    assert!(!bootstrap.session.accepts_user_input);
  }

  #[test]
  fn changed_pending_approval_updates_version_in_place() {
    let mut session = pending_approval_session();

    session.set_pending_approval(
      "approval-1".to_string(),
      ApprovalType::Exec,
      None,
      Some("Bash".to_string()),
      Some("{\"command\":\"ls\"}".to_string()),
      None,
    );

    session.set_pending_approval(
      "approval-1".to_string(),
      ApprovalType::Exec,
      None,
      Some("Bash".to_string()),
      Some("{\"command\":\"pwd\"}".to_string()),
      None,
    );

    assert_eq!(session.approval_version(), 2);
    assert_eq!(session.pending_approvals.len(), 1);
    assert_eq!(
      session.pending_tool_input.as_deref(),
      Some("{\"command\":\"pwd\"}")
    );
  }

  #[test]
  fn apply_changes_with_same_pending_approval_does_not_bump_version() {
    let mut session = pending_approval_session();
    let request = ApprovalRequest {
      id: "approval-1".to_string(),
      session_id: "session-1".to_string(),
      approval_type: ApprovalType::Question,
      tool_name: Some("AskUserQuestion".to_string()),
      tool_input: Some("{\"question\":\"Ship it?\"}".to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: Some("Ship it?".to_string()),
      question_prompts: vec![],
      preview: None,
      permission_reason: None,
      requested_permissions: None,
      granted_permissions: None,
      proposed_amendment: None,
      permission_suggestions: None,
      elicitation_mode: None,
      elicitation_schema: None,
      elicitation_url: None,
      elicitation_message: None,
      mcp_server_name: None,
      network_host: None,
      network_protocol: None,
    };

    session.apply_changes(&StateChanges {
      pending_approval: Some(Some(request.clone())),
      work_status: Some(WorkStatus::Question),
      ..Default::default()
    });
    let version_after_first = session.approval_version();

    session.apply_changes(&StateChanges {
      pending_approval: Some(Some(request)),
      work_status: Some(WorkStatus::Question),
      ..Default::default()
    });

    assert_eq!(session.approval_version(), version_after_first);
    assert_eq!(session.pending_approvals.len(), 1);
  }

  #[test]
  fn metadata_setters_do_not_mutate_activity_timestamps() {
    let mut session = pending_approval_session();
    let original_last_activity_at = session.timestamps.last_activity_at.clone();
    let original_last_progress_at = session.timestamps.last_progress_at.clone();

    session.set_custom_name(Some("Renamed".to_string()));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Working);
    session.set_last_tool(Some("Read".to_string()));

    assert_eq!(
      session.timestamps.last_activity_at,
      original_last_activity_at
    );
    assert_eq!(
      session.timestamps.last_progress_at,
      original_last_progress_at
    );
  }

  #[test]
  fn imperative_row_mutations_use_unix_z_progress_timestamps() {
    let mut session = pending_approval_session();
    let row = user_entry("session-1", "user-1", "hello");

    session.add_row(row);

    assert!(parse_unix_z(session.timestamps.last_activity_at.as_deref()).is_some());
    assert!(parse_unix_z(session.timestamps.last_progress_at.as_deref()).is_some());
  }

  #[test]
  fn user_rows_update_activity_without_advancing_progress() {
    let mut session = pending_approval_session();
    let original_last_progress_at = session.timestamps.last_progress_at.clone();

    session.add_row(user_entry("session-1", "user-1", "hello"));

    assert!(parse_unix_z(session.timestamps.last_activity_at.as_deref()).is_some());
    assert_eq!(
      session.timestamps.last_progress_at,
      original_last_progress_at
    );
  }

  #[test]
  fn steer_rows_do_not_count_for_user_echo_dedup() {
    let mut session = pending_approval_session();
    let steer = ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence: 0,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::Steer(MessageRowContent {
        id: "steer-1".to_string(),
        content: "same content".to_string(),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: Some(MessageDeliveryStatus::Pending),
      }),
    };

    session.add_row(steer);

    assert!(!session.has_user_row_with_content("same content"));
  }

  #[test]
  fn apply_state_recomputes_newest_synced_row_id_from_rows() {
    let mut session = pending_approval_session();
    session.add_row(user_entry("session-1", "user-1", "hello"));
    session.set_newest_synced_row_id(Some("stale-row".to_string()));

    let mut state = session.extract_state();
    state.rows.push(ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence: 1,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::Assistant(MessageRowContent {
        id: "assistant-2".to_string(),
        content: "done".to_string(),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    });
    state.total_row_count = state.rows.len() as u64;

    session.apply_state(state);

    assert_eq!(session.newest_synced_row_id(), Some("assistant-2"));
  }
}
