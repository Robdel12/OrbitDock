//! Session management

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use arc_swap::ArcSwap;
use orbitdock_protocol::conversation_contracts::{
  ConversationRowEntry, RowEntrySummary, TurnStatus,
};
use orbitdock_protocol::{
  ApprovalRequest, ApprovalType, ClaudeIntegrationMode, CodexApprovalPolicy, CodexConfigMode,
  CodexConfigSource, CodexIntegrationMode, CodexSandboxPolicy, CodexSessionOverrides,
  DashboardDiffPreview, Provider, SessionControlMode, SessionLifecycleState, SessionState,
  SessionStatus, SessionSummary, StateChanges, TokenUsage, TokenUsageSnapshotKind, TurnDiff,
  WorkStatus,
};

#[cfg(test)]
use super::approval_state::PendingApprovalMutation;
use super::conversation_state::ConversationState;
use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use super::state::SessionCoreState;
#[cfg(test)]
use crate::domain::sessions::conversation::ConversationBootstrap;
use crate::domain::sessions::conversation::ConversationPage;
use crate::domain::sessions::transition::TransitionState;
#[cfg(test)]
use orbitdock_protocol::{ServerMessage, SubagentInfo};
use tokio::sync::broadcast;

use self::session_broadcast::broadcast_capacity;
use self::session_streaming::StreamingRowEmitState;
#[cfg(test)]
pub use super::support::control_mode_from_parts;
pub(crate) use super::support::{accepts_user_input_from_parts, steerable_from_parts};

/// Lightweight, lock-free snapshot of session metadata.
/// Used by `ArcSwap` so list subscribers and snapshot readers never block
/// the actor.
#[derive(Debug, Clone)]
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
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub effort: Option<String>,
  pub approval_version: u64,
  pub repository_root: Option<String>,
  pub is_worktree: bool,
  pub worktree_id: Option<String>,
  pub has_turn_diff: bool,
  pub diff_preview: Option<DashboardDiffPreview>,
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

/// Handle to a running session
pub struct SessionHandle {
  state: SessionCoreState,

  // ── Broadcasting ────────────────────────────────────────────────
  broadcast_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,
  /// Optional sender for list-level broadcasts (dashboard sidebar updates)
  list_tx: Option<broadcast::Sender<orbitdock_protocol::ServerMessage>>,
  /// Shared sessions-summary revision counter owned by the session registry.
  sessions_summary_revision: Option<Arc<AtomicU64>>,
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
  pub turn_count: u64,
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
      sessions_summary_revision: None,
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
      sessions_summary_revision: None,
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

  pub fn set_sessions_summary_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.sessions_summary_revision = Some(revision);
  }

  pub fn set_dashboard_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.dashboard_revision = Some(revision);
  }

  pub fn set_library_revision_counter(&mut self, revision: Arc<AtomicU64>) {
    self.library_revision = Some(revision);
  }

  /// Get session ID
  pub fn id(&self) -> &str {
    self.state.id()
  }

  /// Get provider
  pub fn provider(&self) -> Provider {
    self.state.provider()
  }

  /// Increment the in-memory tool count (called alongside persist command).
  pub fn increment_tool_count(&mut self) {
    self.state.increment_tool_count();
  }

  /// Get a reference to the grouped config.
  #[cfg(test)]
  pub fn config(&self) -> &SessionConfig {
    self.state.config()
  }

  /// Get a summary of this session
  pub fn summary(&self) -> SessionSummary {
    self.state.summary(self.revision)
  }

  /// Get the retained in-memory session snapshot.
  pub fn retained_state(&self) -> SessionState {
    self.state.retained_state(self.revision)
  }

  /// Set subagents list
  #[cfg(test)]
  pub fn set_subagents(&mut self, subagents: Vec<SubagentInfo>) {
    self.state.set_subagents(subagents);
    self.refresh_snapshot();
  }

  #[cfg(test)]
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
  #[cfg(test)]
  pub fn set_first_prompt(&mut self, prompt: Option<String>) {
    self.state.set_first_prompt(prompt);
  }

  /// Set last message (for dashboard context lines)
  pub fn set_last_message(&mut self, message: Option<String>) {
    self.state.set_last_message(message);
  }

  /// Get rows
  pub fn rows(&self) -> &[ConversationRowEntry] {
    self.state.rows()
  }

  /// Update a row's sequence to the DB-assigned value (single source of truth).
  pub fn set_row_sequence(&mut self, row_id: &str, sequence: u64) {
    self.state.set_row_sequence(row_id, sequence);
  }

  /// Look up a row by ID.
  pub fn row_by_id(&self, row_id: &str) -> Option<&ConversationRowEntry> {
    self.state.row_by_id(row_id)
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

  pub fn message_count(&self) -> usize {
    self.state.message_count()
  }

  /// Get the newest synced row ID (for transcript sync comparison).
  #[cfg(test)]
  pub fn newest_synced_row_id(&self) -> Option<&str> {
    self.state.newest_synced_row_id()
  }

  /// Update the newest synced row ID after a successful transcript sync.
  #[cfg(test)]
  pub fn set_newest_synced_row_id(&mut self, id: Option<String>) {
    self.state.set_newest_synced_row_id(id);
  }

  /// Check if a user row with this content already exists (dedup for connector echo)
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
  pub fn set_config(&mut self, patch: SessionConfig) {
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

  /// Set status
  #[cfg(test)]
  pub fn set_status(&mut self, status: SessionStatus) {
    self.state.set_status(status);
  }

  /// Set last_activity_at timestamp
  #[cfg(test)]
  pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
    self.state.set_last_activity_at(last_activity_at);
  }

  /// Set work status
  pub fn set_work_status(&mut self, status: WorkStatus) {
    self.state.set_work_status(status);
  }

  /// Get work status
  pub fn work_status(&self) -> WorkStatus {
    self.state.work_status()
  }

  /// Set last tool name
  #[cfg(test)]
  pub fn set_last_tool(&mut self, tool: Option<String>) {
    self.state.set_last_tool(tool);
  }

  /// Get last tool name
  pub fn last_tool(&self) -> Option<&str> {
    self.state.last_tool()
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
    self.state.unread_count()
  }

  /// Total row count across all retained + evicted rows.
  pub fn total_row_count(&self) -> u64 {
    self.state.total_row_count()
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

  /// Get the current approval version.
  pub fn approval_version(&self) -> u64 {
    self.state.approval_version()
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

  /// Get the ArcSwap handle for lock-free reads
  pub fn snapshot_arc(&self) -> Arc<ArcSwap<SessionSnapshot>> {
    self.snapshot_handle.clone()
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

#[path = "session_broadcast.rs"]
mod session_broadcast;
#[path = "session_streaming.rs"]
mod session_streaming;

#[cfg(test)]
#[path = "session_tests.rs"]
mod session_tests;
