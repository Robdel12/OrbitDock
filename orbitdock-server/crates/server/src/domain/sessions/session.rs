//! Session management

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;
use orbitdock_protocol::conversation_contracts::{
  ConversationRowEntry, RowEntrySummary, TurnStatus,
};
use orbitdock_protocol::{
  ApprovalRequest, ApprovalType, ClaudeIntegrationMode, CodexApprovalPolicy, CodexConfigMode,
  CodexConfigSource, CodexIntegrationMode, CodexSandboxPolicy, CodexSessionOverrides, Provider,
  SessionControlMode, SessionLifecycleState, SessionState, SessionStatus, SessionSummary,
  SessionSurface, StateChanges, SubagentInfo, TokenUsage, TokenUsageSnapshotKind, TurnDiff,
  WorkStatus,
};

#[cfg(test)]
use super::approval_state::PendingApprovalMutation;
use super::conversation_state::{
  is_actively_streaming_message_row_summary, is_message_row_summary,
  streaming_message_row_summary_content_len, ConversationState,
};
pub use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use super::state::SessionCoreState;
#[cfg(test)]
use crate::domain::sessions::conversation::ConversationBootstrap;
use crate::domain::sessions::conversation::ConversationPage;
use crate::domain::sessions::transition::TransitionState;
use crate::runtime::session_broadcasts::invalidated_surfaces;
use crate::support::snapshot_compaction::sanitize_server_message_for_transport;
use orbitdock_protocol::ServerMessage;
use tokio::sync::broadcast;

fn is_session_ended(msg: &ServerMessage) -> bool {
  matches!(msg, ServerMessage::SessionEnded { .. })
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
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
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
  pub tool_count: u64,
  pub token_usage: TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
  pub revision: u64,
  pub current_plan: Option<Arc<str>>,
  pub current_diff: Option<Arc<str>>,
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

const EVENT_LOG_CAPACITY: usize = 1000;
const DEFAULT_BROADCAST_CAPACITY: usize = 512;
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
  state: SessionCoreState,

  // ── Broadcasting ────────────────────────────────────────────────
  broadcast_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,
  /// Optional sender for list-level broadcasts (dashboard sidebar updates)
  list_tx: Option<broadcast::Sender<orbitdock_protocol::ServerMessage>>,
  /// Shared control-plane revision counter owned by the session registry.
  control_plane_revision: Option<Arc<AtomicU64>>,
  /// Shared dashboard revision counter owned by the session registry.
  dashboard_revision: Option<Arc<AtomicU64>>,
  /// Shared library revision counter owned by the session registry.
  library_revision: Option<Arc<AtomicU64>>,
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

#[derive(Debug, Clone)]
struct StreamingRowEmitState {
  last_emit_at: Instant,
  last_emitted_content_len: usize,
}

impl SessionHandle {
  fn conversation_state(&self) -> ConversationState {
    self.state.conversation_state()
  }

  pub fn has_active_viewers(&self) -> bool {
    self.broadcast_tx.receiver_count() > 0
  }

  pub fn latest_row_sequence(&self) -> u64 {
    self.state.latest_row_sequence()
  }

  pub fn conversation_page(&self, before_sequence: Option<u64>, limit: usize) -> ConversationPage {
    self.conversation_state().page(before_sequence, limit)
  }

  #[cfg(test)]
  pub fn conversation_bootstrap(&self, limit: usize) -> ConversationBootstrap {
    self
      .conversation_state()
      .bootstrap(self.retained_state(), limit)
  }

  /// Create a new session handle
  pub fn new(id: String, provider: Provider, project_path: String) -> Self {
    let (broadcast_tx, _) = broadcast::channel(broadcast_capacity());
    let state = SessionCoreState::new(id, provider, project_path);
    let snapshot = state.to_snapshot(0, 0);
    Self {
      state,
      broadcast_tx,
      list_tx: None,
      control_plane_revision: None,
      dashboard_revision: None,
      library_revision: None,
      revision: 0,
      event_log: VecDeque::new(),
      streaming_row_emit_at: HashMap::new(),
      snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
    }
  }

  /// Restore a session from the database (for server restart recovery)
  pub fn restore(data: SessionRestoreData) -> Self {
    let (broadcast_tx, _) = broadcast::channel(broadcast_capacity());
    let state = SessionCoreState::restore(data);
    let snapshot = state.restored_snapshot();
    Self {
      state,
      broadcast_tx,
      list_tx: None,
      control_plane_revision: None,
      dashboard_revision: None,
      library_revision: None,
      revision: 0,
      event_log: VecDeque::new(),
      streaming_row_emit_at: HashMap::new(),
      snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
    }
  }

  /// Set the list broadcast sender (for dashboard sidebar updates)
  pub fn set_list_tx(&mut self, tx: broadcast::Sender<orbitdock_protocol::ServerMessage>) {
    self.list_tx = Some(tx);
  }

  pub fn set_control_plane_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.control_plane_revision = Some(revision);
  }

  pub fn set_dashboard_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.dashboard_revision = Some(revision);
  }

  pub fn set_library_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.library_revision = Some(revision);
  }

  /// Get session ID
  pub fn id(&self) -> &str {
    &self.state.identity.id
  }

  /// Get provider
  pub fn provider(&self) -> Provider {
    self.state.identity.provider
  }

  /// Increment the in-memory tool count (called alongside persist command).
  pub fn increment_tool_count(&mut self) {
    self.state.tool_count += 1;
  }

  /// Get a reference to the grouped config.
  #[allow(dead_code)]
  pub fn config(&self) -> &SessionConfig {
    &self.state.config
  }

  /// Get a summary of this session
  pub fn summary(&self) -> SessionSummary {
    self.state.summary(self.revision)
  }

  /// Get the retained in-memory session snapshot.
  pub fn retained_state(&self) -> SessionState {
    self.state.retained_state(self.revision)
  }

  /// Get subagents
  #[allow(dead_code)]
  pub fn subagents(&self) -> &[SubagentInfo] {
    &self.state.subagents
  }

  /// Set subagents list
  #[allow(dead_code)]
  pub fn set_subagents(&mut self, subagents: Vec<SubagentInfo>) {
    self.state.set_subagents(subagents);
    self.refresh_snapshot();
  }

  #[allow(dead_code)]
  pub fn set_pending_attention(
    &mut self,
    pending_tool_name: Option<String>,
    pending_tool_input: Option<String>,
    pending_question: Option<String>,
  ) {
    self
      .state
      .set_pending_attention(pending_tool_name, pending_tool_input, pending_question);
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
    self.state.set_mission_context(mission_id, issue_identifier);
    self.refresh_snapshot();
  }

  /// Mark that the CLI was launched with `--allow-dangerously-skip-permissions`.
  pub fn set_allow_bypass_permissions(&mut self, enabled: bool) {
    self.state.set_allow_bypass_permissions(enabled);
    self.refresh_snapshot();
  }

  /// Set the custom name for this session
  pub fn set_custom_name(&mut self, name: Option<String>) {
    self.state.set_custom_name(name);
  }

  /// Set first prompt
  #[allow(dead_code)]
  pub fn set_first_prompt(&mut self, prompt: Option<String>) {
    self.state.set_first_prompt(prompt);
  }

  /// Set last message (for dashboard context lines)
  pub fn set_last_message(&mut self, message: Option<String>) {
    self.state.set_last_message(message);
  }

  /// Get rows
  pub fn rows(&self) -> &[ConversationRowEntry] {
    &self.state.rows
  }

  /// Update a row's sequence to the DB-assigned value (single source of truth).
  pub fn set_row_sequence(&mut self, row_id: &str, sequence: u64) {
    self.state.set_row_sequence(row_id, sequence);
  }

  /// Look up a row by ID.
  pub fn row_by_id(&self, row_id: &str) -> Option<&ConversationRowEntry> {
    self.state.row_by_id(row_id)
  }

  /// Get first prompt
  #[allow(dead_code)]
  pub fn first_prompt(&self) -> Option<&str> {
    self.state.display.first_prompt.as_deref()
  }

  /// Set codex integration mode
  pub fn set_codex_integration_mode(&mut self, mode: Option<CodexIntegrationMode>) {
    self.state.set_codex_integration_mode(mode);
    self.refresh_snapshot();
  }

  /// Set claude integration mode
  pub fn set_claude_integration_mode(&mut self, mode: Option<ClaudeIntegrationMode>) {
    self.state.set_claude_integration_mode(mode);
    self.refresh_snapshot();
  }

  /// Set the control mode directly.
  pub fn set_control_mode(&mut self, control_mode: SessionControlMode) {
    self.state.set_control_mode(control_mode);
    self.refresh_snapshot();
  }

  /// Set project name
  pub fn set_project_name(&mut self, project_name: Option<String>) {
    self.state.set_project_name(project_name);
  }

  pub fn set_git_branch(&mut self, branch: Option<String>) {
    self.state.set_git_branch(branch);
  }

  /// Set transcript path
  pub fn set_transcript_path(&mut self, transcript_path: Option<String>) {
    self.state.set_transcript_path(transcript_path);
  }

  #[allow(dead_code)]
  pub fn transcript_path(&self) -> Option<&str> {
    self.state.identity.transcript_path.as_deref()
  }

  pub fn message_count(&self) -> usize {
    self.state.total_row_count as usize
  }

  /// Get the newest synced row ID (for transcript sync comparison).
  #[allow(dead_code)]
  pub fn newest_synced_row_id(&self) -> Option<&str> {
    self.state.newest_synced_row_id.as_deref()
  }

  /// Update the newest synced row ID after a successful transcript sync.
  #[allow(dead_code)]
  pub fn set_newest_synced_row_id(&mut self, id: Option<String>) {
    self.state.set_newest_synced_row_id(id);
  }

  /// Check if a user row with this content already exists (dedup for connector echo)
  #[allow(dead_code)]
  pub fn has_user_row_with_content(&self, content: &str) -> bool {
    self.state.has_user_row_with_content(content)
  }

  /// Set model
  pub fn set_model(&mut self, model: Option<String>) {
    self.state.set_model(model);
    self.refresh_snapshot();
  }

  /// Set reasoning effort
  pub fn set_effort(&mut self, effort: Option<String>) {
    self.state.set_effort(effort);
    self.refresh_snapshot();
  }

  /// Set autonomy configuration
  pub fn set_config(&mut self, patch: SessionConfigPatch) {
    self.state.set_config(patch);
    self.refresh_snapshot();
  }

  /// Set fork origin
  pub fn set_forked_from(&mut self, source_session_id: String) {
    self.state.set_forked_from(source_session_id);
  }

  /// Set terminal session ID and app
  pub fn set_terminal_info(
    &mut self,
    terminal_session_id: Option<String>,
    terminal_app: Option<String>,
  ) {
    self
      .state
      .set_terminal_info(terminal_session_id, terminal_app);
  }

  /// Set worktree-related fields
  #[allow(dead_code)] // Used in Phase 6 (hook_handler enrichment)
  pub fn set_worktree_info(
    &mut self,
    repository_root: Option<String>,
    is_worktree: bool,
    worktree_id: Option<String>,
  ) {
    self
      .state
      .set_worktree_info(repository_root, is_worktree, worktree_id);
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn repository_root(&self) -> Option<&str> {
    self.state.environment.repository_root.as_deref()
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn is_worktree(&self) -> bool {
    self.state.environment.is_worktree
  }

  #[allow(dead_code)] // Used in Phase 6+
  pub fn worktree_id(&self) -> Option<&str> {
    self.state.environment.worktree_id.as_deref()
  }

  /// Set status
  #[allow(dead_code)] // Used by apply_changes; kept for direct mutation paths (e.g. connector detach).
  pub fn set_status(&mut self, status: SessionStatus) {
    self.state.set_status(status);
  }

  /// Set started_at timestamp
  #[allow(dead_code)] // Reserved for follow-up session timing plumbing.
  pub fn set_started_at(&mut self, started_at: Option<String>) {
    self.state.set_started_at(started_at);
  }

  /// Set last_activity_at timestamp
  #[allow(dead_code)] // Used by apply_changes; kept for direct mutation paths (e.g. connector detach).
  pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
    self.state.set_last_activity_at(last_activity_at);
  }

  /// Set work status
  pub fn set_work_status(&mut self, status: WorkStatus) {
    self.state.set_work_status(status);
  }

  /// Get work status
  pub fn work_status(&self) -> WorkStatus {
    self.state.work_status
  }

  /// Set last tool name
  #[allow(dead_code)]
  pub fn set_last_tool(&mut self, tool: Option<String>) {
    self.state.set_last_tool(tool);
  }

  /// Get last tool name
  pub fn last_tool(&self) -> Option<&str> {
    self.state.last_tool.as_deref()
  }

  /// Update token usage
  #[allow(dead_code)]
  pub fn update_tokens(&mut self, usage: TokenUsage) {
    self.state.update_tokens(usage);
  }

  /// Add a conversation row
  pub fn add_row(&mut self, entry: ConversationRowEntry) -> ConversationRowEntry {
    let entry = self.state.add_row(entry, self.has_active_viewers());
    self.refresh_snapshot();
    entry
  }

  pub fn unread_count_after_row_append(&self, entry: &ConversationRowEntry) -> Option<u64> {
    self
      .state
      .unread_count_after_row_append(entry, self.has_active_viewers())
  }

  /// Replace an existing row by ID, or append if not found.
  /// Does NOT increment total_row_count when replacing or when the row
  /// was evicted from the retained window (already counted).
  pub fn upsert_row(&mut self, entry: ConversationRowEntry) -> ConversationRowEntry {
    let entry = self.state.upsert_row(entry);
    self.refresh_snapshot();
    entry
  }

  /// Increment unread for an already-applied row append in the transition path.
  ///
  /// `dispatch_transition_input` applies the connector state machine result directly,
  /// so it cannot call `add_row` without duplicating the row in memory.
  /// This keeps the in-memory unread count aligned with the persisted count.
  pub fn note_transition_row_append(&mut self, entry: &RowEntrySummary) -> Option<u64> {
    self
      .state
      .note_transition_row_append(entry, self.has_active_viewers())
  }

  /// Mark the session as fully read. Returns the previous unread count.
  pub fn mark_read(&mut self) -> u64 {
    self.state.mark_read()
  }

  /// Get current unread count
  pub fn unread_count(&self) -> u64 {
    self.state.unread_count
  }

  /// Total row count across all retained + evicted rows.
  pub fn total_row_count(&self) -> u64 {
    self.state.total_row_count
  }

  /// Mark the last `num_turns` worth of rows with the given status.
  ///
  /// A "turn" starts at each user row. Walking from the end we count user
  /// rows to find the boundary; all rows from that boundary to the end get
  /// marked. Returns the IDs of affected rows (for persistence + broadcast).
  pub fn mark_last_turns_status(&mut self, num_turns: u32, status: TurnStatus) -> Vec<String> {
    self.state.mark_last_turns_status(num_turns, status)
  }

  /// Replace all rows (used for snapshot hydration from transcript fallback)
  pub fn replace_rows(&mut self, rows: Vec<ConversationRowEntry>) {
    self.state.replace_rows(rows);
    self.streaming_row_emit_at.clear();
    self.refresh_snapshot();
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
    self.state.update_diff(diff);
  }

  /// Update plan
  #[allow(dead_code)]
  pub fn update_plan(&mut self, plan: String) {
    self.state.update_plan(plan);
  }

  /// Get the current approval version.
  pub fn approval_version(&self) -> u64 {
    self.state.approval_version
  }

  #[cfg(test)]
  fn queue_pending_approval(
    &mut self,
    approval: ApprovalRequest,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
  ) -> PendingApprovalMutation {
    self
      .state
      .queue_pending_approval(approval, approval_type, proposed_amendment)
  }

  #[cfg(test)]
  fn promote_queue_front(&mut self) {
    self.state.promote_queue_front();
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
    let (approval_type, proposed_amendment, active_approval, work_status) = self
      .state
      .resolve_pending_approval(request_id, fallback_work_status);

    (
      approval_type,
      proposed_amendment,
      active_approval,
      work_status,
    )
  }

  /// Apply a `StateChanges` delta to the handle fields.
  /// Each `Some` field overwrites the corresponding handle field.
  pub fn apply_changes(&mut self, changes: &StateChanges) {
    self.state.apply_changes(changes);
  }

  /// Create a snapshot of current session metadata
  pub fn to_snapshot(&self) -> SessionSnapshot {
    self
      .state
      .to_snapshot(self.revision, self.broadcast_tx.receiver_count())
  }

  /// Update the ArcSwap snapshot (call after mutations)
  pub fn refresh_snapshot(&self) {
    self.snapshot_handle.store(Arc::new(self.to_snapshot()));
  }

  /// Emit active-session and archive invalidations from the current snapshot.
  /// Use after `refresh_snapshot()` in code paths that change session state
  /// without going through `broadcast()` (e.g. transition effects that only
  /// produce Persist ops with no Emit).
  pub fn emit_dashboard_update(&self) {
    if let (
      Some(ref list_tx),
      Some(ref control_plane_revision),
      Some(ref dashboard_revision),
      Some(ref library_revision),
    ) = (
      &self.list_tx,
      &self.control_plane_revision,
      &self.dashboard_revision,
      &self.library_revision,
    ) {
      let control_plane_revision = control_plane_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::SessionsSummaryInvalidated {
        revision: control_plane_revision,
      });
      let library_revision = library_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ArchivedSessionsInvalidated {
        revision: library_revision,
      });
      let revision = dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ActiveSessionsInvalidated { revision });
    }
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

    self.push_event_log_message(&msg, rev);
    let _ = self.broadcast_tx.send(msg.clone());
    let session_id = self.state.identity.id.clone();
    for surface in invalidated_surfaces(&msg) {
      let invalidation = ServerMessage::SessionSurfaceInvalidated {
        session_id: session_id.clone(),
        surface: *surface,
        revision: rev,
      };
      self.push_event_log_message(&invalidation, rev);
      let _ = self.broadcast_tx.send(invalidation);
    }
    self.refresh_snapshot();

    if is_session_ended(&msg) {
      self.emit_dashboard_removed();
    } else {
      self.emit_dashboard_update();
    }
  }

  pub fn broadcast_surface_invalidations(&mut self, surfaces: &[SessionSurface]) {
    if surfaces.is_empty() {
      return;
    }

    self.revision += 1;
    let rev = self.revision;
    let session_id = self.state.identity.id.clone();

    for surface in surfaces {
      let invalidation = ServerMessage::SessionSurfaceInvalidated {
        session_id: session_id.clone(),
        surface: *surface,
        revision: rev,
      };
      self.push_event_log_message(&invalidation, rev);
      let _ = self.broadcast_tx.send(invalidation);
    }

    self.refresh_snapshot();
    self.emit_dashboard_update();
  }

  fn push_event_log_message(&mut self, msg: &ServerMessage, revision: u64) {
    if let Ok(json) = serialize_with_revision(msg, revision) {
      self.event_log.push_back((revision, json));
      if self.event_log.len() > EVENT_LOG_CAPACITY {
        self.event_log.pop_front();
      }
    }
  }

  fn emit_dashboard_removed(&self) {
    if let (
      Some(ref list_tx),
      Some(ref control_plane_revision),
      Some(ref dashboard_revision),
      Some(ref library_revision),
    ) = (
      &self.list_tx,
      &self.control_plane_revision,
      &self.dashboard_revision,
      &self.library_revision,
    ) {
      let control_plane_revision = control_plane_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::SessionsSummaryInvalidated {
        revision: control_plane_revision,
      });
      let library_revision = library_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ArchivedSessionsInvalidated {
        revision: library_revision,
      });
      let revision = dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ActiveSessionsInvalidated { revision });
    }
  }

  /// Replay events since a given revision.
  /// Returns `None` if the gap is too large (caller should send a retained snapshot fallback).
  pub fn replay_since(&self, since_revision: u64) -> Option<Vec<String>> {
    let Some(oldest) = self.event_log.front().map(|(rev, _)| *rev) else {
      return (since_revision == self.revision).then(Vec::new);
    };
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
    self.state.extract_state(self.revision)
  }

  /// Apply the transition result back to this handle
  pub fn apply_state(&mut self, state: TransitionState) {
    self.state.apply_state(state);
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

#[cfg(test)]
mod tests {
  use super::*;
  use crate::support::session_time::parse_unix_z;
  use orbitdock_protocol::conversation_contracts::ConversationRow;
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
  fn broadcast_always_emits_active_sessions_invalidation() {
    let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
    let control_plane_revision = Arc::new(AtomicU64::new(0));
    let dashboard_revision = Arc::new(AtomicU64::new(0));
    let library_revision = Arc::new(AtomicU64::new(0));
    let mut session = session_handle(Provider::Codex);
    session.set_list_tx(list_tx);
    session.set_control_plane_revision_counter(control_plane_revision);
    session.set_dashboard_revision_counter(dashboard_revision);
    session.set_library_revision_counter(library_revision);

    // Any message type should emit a dashboard update — no filters.
    session.broadcast(ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Working),
        ..Default::default()
      }),
    });

    let msg = list_rx
      .try_recv()
      .expect("control-plane invalidation should be emitted");
    assert!(matches!(
      msg,
      ServerMessage::SessionsSummaryInvalidated { revision: 1 }
    ));

    let msg = list_rx
      .try_recv()
      .expect("library invalidation should be emitted");
    assert!(matches!(
      msg,
      ServerMessage::ArchivedSessionsInvalidated { revision: 1 }
    ));

    let msg = list_rx
      .try_recv()
      .expect("dashboard update should be emitted");
    assert!(matches!(
      msg,
      ServerMessage::ActiveSessionsInvalidated { revision: 1 }
    ));
  }

  #[test]
  fn broadcast_emits_dashboard_update_for_non_delta_messages() {
    let (list_tx, mut list_rx) = tokio::sync::broadcast::channel(8);
    let control_plane_revision = Arc::new(AtomicU64::new(0));
    let dashboard_revision = Arc::new(AtomicU64::new(0));
    let library_revision = Arc::new(AtomicU64::new(0));
    let mut session = session_handle(Provider::Codex);
    session.set_list_tx(list_tx);
    session.set_control_plane_revision_counter(control_plane_revision);
    session.set_dashboard_revision_counter(dashboard_revision);
    session.set_library_revision_counter(library_revision);

    // ConversationRowsChanged was previously filtered out — now it emits a dashboard update.
    session.broadcast(ServerMessage::ConversationRowsChanged {
      session_id: "session-1".to_string(),
      upserted: vec![],
      removed_row_ids: vec![],
      total_row_count: 0,
    });

    let msg = list_rx
      .try_recv()
      .expect("control-plane invalidation should be emitted for any message type");
    assert!(matches!(
      msg,
      ServerMessage::SessionsSummaryInvalidated { revision: 1 }
    ));

    let msg = list_rx
      .try_recv()
      .expect("library invalidation should be emitted for any message type");
    assert!(matches!(
      msg,
      ServerMessage::ArchivedSessionsInvalidated { revision: 1 }
    ));

    let msg = list_rx
      .try_recv()
      .expect("dashboard update should be emitted for any message type");
    assert!(matches!(
      msg,
      ServerMessage::ActiveSessionsInvalidated { revision: 1 }
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
  fn replay_since_current_revision_without_event_log_returns_empty_replay() {
    let session = session_handle(Provider::Codex);

    let replay = session
      .replay_since(0)
      .expect("empty replay at current revision");

    assert!(replay.is_empty());
  }

  #[test]
  fn set_config_syncs_legacy_sandbox_mode_from_explicit_details() {
    let mut session = session_handle(Provider::Codex);

    session.set_config(SessionConfigPatch {
      sandbox_policy_details: CodexSandboxPolicy::from_storage_text("workspace-write-network"),
      ..Default::default()
    });

    assert_eq!(
      session.config().sandbox_mode.as_deref(),
      Some("workspace-write-network")
    );
  }

  #[test]
  fn set_config_syncs_legacy_approval_policy_from_explicit_details() {
    let mut session = session_handle(Provider::Codex);

    session.set_config(SessionConfigPatch {
      approval_policy_details: orbitdock_protocol::CodexApprovalPolicy::from_storage_text("never"),
      ..Default::default()
    });

    assert_eq!(session.config().approval_policy.as_deref(), Some("never"));
  }

  #[test]
  fn apply_changes_syncs_legacy_sandbox_mode_from_explicit_details() {
    let mut session = session_handle(Provider::Codex);

    session.apply_changes(&StateChanges {
      sandbox_policy_details: Some(CodexSandboxPolicy::from_storage_text("read-only-network")),
      ..Default::default()
    });

    assert_eq!(
      session.config().sandbox_mode.as_deref(),
      Some("read-only-network")
    );

    session.apply_changes(&StateChanges {
      sandbox_policy_details: Some(None),
      ..Default::default()
    });

    assert!(session.config().sandbox_mode.is_none());
  }

  #[test]
  fn apply_changes_syncs_legacy_approval_policy_from_explicit_details() {
    let mut session = session_handle(Provider::Codex);

    session.apply_changes(&StateChanges {
      approval_policy_details: Some(orbitdock_protocol::CodexApprovalPolicy::from_storage_text(
        "never",
      )),
      ..Default::default()
    });

    assert_eq!(session.config().approval_policy.as_deref(), Some("never"));

    session.apply_changes(&StateChanges {
      approval_policy_details: Some(None),
      ..Default::default()
    });

    assert!(session.config().approval_policy.is_none());
  }

  #[test]
  fn duplicate_pending_approval_is_a_no_op() {
    let mut session = pending_approval_session();
    let request = ApprovalRequest {
      id: "approval-1".to_string(),
      session_id: session.state.identity.id.clone(),
      approval_type: ApprovalType::Exec,
      tool_name: Some("Bash".to_string()),
      tool_input: Some("{\"command\":\"ls\"}".to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: None,
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

    session.queue_pending_approval(request.clone(), ApprovalType::Exec, None);
    session.promote_queue_front();
    let version_after_first = session.approval_version();

    session.queue_pending_approval(request, ApprovalType::Exec, None);
    session.promote_queue_front();

    assert_eq!(session.approval_version(), version_after_first);
    assert_eq!(session.state.pending_approvals.len(), 1);
    assert_eq!(
      session.state.pending_approval_id.as_deref(),
      Some("approval-1")
    );
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
  fn retained_state_only_marks_active_turns_interruptible() {
    let mut session = session_handle(Provider::Codex);
    session.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Working);

    let without_turn = session.retained_state();
    assert!(!without_turn.can_interrupt);

    session.state.current_turn_id = Some("turn-1".to_string());
    let with_turn = session.retained_state();
    assert!(with_turn.can_interrupt);

    session.set_work_status(WorkStatus::Waiting);
    let settled = session.retained_state();
    assert!(!settled.can_interrupt);
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
    let sid = session.state.identity.id.clone();
    let make_request = |input: &str| ApprovalRequest {
      id: "approval-1".to_string(),
      session_id: sid.clone(),
      approval_type: ApprovalType::Exec,
      tool_name: Some("Bash".to_string()),
      tool_input: Some(input.to_string()),
      command: None,
      file_path: None,
      diff: None,
      question: None,
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

    session.queue_pending_approval(
      make_request("{\"command\":\"ls\"}"),
      ApprovalType::Exec,
      None,
    );
    session.promote_queue_front();

    session.queue_pending_approval(
      make_request("{\"command\":\"pwd\"}"),
      ApprovalType::Exec,
      None,
    );
    session.promote_queue_front();

    assert_eq!(session.approval_version(), 2);
    assert_eq!(session.state.pending_approvals.len(), 1);
    assert_eq!(
      session.state.pending_tool_input.as_deref(),
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
    assert_eq!(session.state.pending_approvals.len(), 1);
  }

  #[test]
  fn metadata_setters_do_not_mutate_activity_timestamps() {
    let mut session = pending_approval_session();
    let original_last_activity_at = session.state.timestamps.last_activity_at.clone();
    let original_last_progress_at = session.state.timestamps.last_progress_at.clone();

    session.set_custom_name(Some("Renamed".to_string()));
    session.set_status(SessionStatus::Active);
    session.set_work_status(WorkStatus::Working);
    session.set_last_tool(Some("Read".to_string()));

    assert_eq!(
      session.state.timestamps.last_activity_at,
      original_last_activity_at
    );
    assert_eq!(
      session.state.timestamps.last_progress_at,
      original_last_progress_at
    );
  }

  #[test]
  fn imperative_row_mutations_use_unix_z_progress_timestamps() {
    let mut session = pending_approval_session();
    let row = user_entry("session-1", "user-1", "hello");

    session.add_row(row);

    assert!(parse_unix_z(session.state.timestamps.last_activity_at.as_deref()).is_some());
    assert!(parse_unix_z(session.state.timestamps.last_progress_at.as_deref()).is_some());
  }

  #[test]
  fn user_rows_update_activity_without_advancing_progress() {
    let mut session = pending_approval_session();
    let original_last_progress_at = session.state.timestamps.last_progress_at.clone();

    session.add_row(user_entry("session-1", "user-1", "hello"));

    assert!(parse_unix_z(session.state.timestamps.last_activity_at.as_deref()).is_some());
    assert_eq!(
      session.state.timestamps.last_progress_at,
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
