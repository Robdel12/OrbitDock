use std::collections::VecDeque;
use std::sync::Arc;

use super::approval_state::{
  pending_tool_family_from_state, resolve_approval_policy_details, resolve_sandbox_policy_details,
  ApprovalQueueState, PendingApprovalEntry, PendingApprovalMutation,
};
use super::conversation_state::{is_non_user_row, is_non_user_row_summary, ConversationState};
use super::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use super::restore::{build_restored_session_snapshot, SessionRestoreSnapshotInput};
use super::session::{
  accepts_user_input_from_parts, control_mode_from_parts, SessionConfigPatch, SessionRestoreData,
  SessionSnapshot,
};
use super::snapshot::{build_session_snapshot, SessionSnapshotInput};
use crate::domain::sessions::transition::{TransitionState, WorkPhase};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, RowEntrySummary, TurnStatus,
};
use orbitdock_protocol::{
  ApprovalRequest, ApprovalType, ClaudeIntegrationMode, CodexIntegrationMode, SessionControlMode,
  SessionLifecycleState, SessionState, SessionStatus, SessionSummary, StateChanges, SubagentInfo,
  TokenUsage, TokenUsageSnapshotKind, TurnDiff, WorkStatus,
};

const RETAINED_FINALIZED_ROW_LIMIT: usize = 200;

fn is_local_http_row_id(row_id: &str) -> bool {
  row_id.starts_with("user-http-") || row_id.starts_with("steer-http-")
}

fn latest_transcript_synced_row_id(rows: &[ConversationRowEntry]) -> Option<String> {
  rows
    .iter()
    .rev()
    .find(|row| !is_local_http_row_id(row.id()))
    .map(|row| row.id().to_string())
}

#[derive(Debug, Clone)]
pub(crate) struct SessionCoreState {
  pub identity: SessionIdentity,
  pub config: SessionConfig,
  pub display: SessionDisplay,
  pub environment: SessionEnvironment,
  pub timestamps: SessionTimestamps,
  pub codex_integration_mode: Option<CodexIntegrationMode>,
  pub claude_integration_mode: Option<ClaudeIntegrationMode>,
  pub control_mode: SessionControlMode,
  pub status: SessionStatus,
  pub work_status: WorkStatus,
  pub lifecycle_state: SessionLifecycleState,
  pub steerable: bool,
  pub last_tool: Option<String>,
  pub rows: Vec<ConversationRowEntry>,
  pub total_row_count: u64,
  pub token_usage: TokenUsage,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub tool_count: u64,
  pub current_diff: Option<Arc<str>>,
  pub current_plan: Option<Arc<str>>,
  pub current_turn_id: Option<String>,
  pub turn_count: u64,
  pub turn_diffs: Vec<TurnDiff>,
  pub forked_from_session_id: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub subagents: Vec<SubagentInfo>,
  pub pending_approval: Option<ApprovalRequest>,
  pub permission_mode: Option<String>,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub pending_approvals: VecDeque<PendingApprovalEntry>,
  pub approval_version: u64,
  pub unread_count: u64,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub allow_bypass_permissions: bool,
  pub newest_synced_row_id: Option<String>,
}

impl SessionCoreState {
  pub fn new(id: String, provider: orbitdock_protocol::Provider, project_path: String) -> Self {
    let now = crate::support::session_time::chrono_now();
    Self {
      identity: SessionIdentity {
        id,
        provider,
        project_path,
        transcript_path: None,
        project_name: None,
      },
      config: SessionConfig::default(),
      display: SessionDisplay::default(),
      environment: SessionEnvironment::default(),
      timestamps: SessionTimestamps {
        started_at: Some(now.clone()),
        last_activity_at: Some(now.clone()),
        last_progress_at: Some(now),
      },
      codex_integration_mode: None,
      claude_integration_mode: None,
      control_mode: SessionControlMode::Passive,
      status: SessionStatus::Active,
      work_status: WorkStatus::Waiting,
      lifecycle_state: SessionLifecycleState::Open,
      steerable: false,
      last_tool: None,
      rows: Vec::new(),
      total_row_count: 0,
      token_usage: TokenUsage::default(),
      token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
      tool_count: 0,
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
    }
  }

  fn can_interrupt(&self) -> bool {
    self.status == SessionStatus::Active
      && self.control_mode == SessionControlMode::Direct
      && self.lifecycle_state == SessionLifecycleState::Open
      && self.work_status == WorkStatus::Working
      && self.current_turn_id.is_some()
  }

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

    let mut state = Self {
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
      tool_count: 0,
      current_diff: current_diff.map(Arc::from),
      current_plan: current_plan.map(Arc::from),
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
    };
    state.total_row_count = state.rows.len() as u64;
    state.newest_synced_row_id = latest_transcript_synced_row_id(&state.rows);
    state.trim_retained_rows();
    state.bootstrap_pending_approval_from_persisted_fields();
    state
  }

  pub fn conversation_state(&self) -> ConversationState {
    ConversationState::new(self.rows.clone(), self.total_row_count)
  }

  fn next_row_sequence(&self) -> u64 {
    self
      .rows
      .last()
      .map(|entry| entry.sequence + 1)
      .unwrap_or(self.total_row_count)
  }

  pub fn latest_row_sequence(&self) -> u64 {
    self
      .rows
      .last()
      .map(|entry| entry.sequence)
      .unwrap_or_else(|| self.total_row_count.saturating_sub(1))
  }

  fn trim_retained_rows(&mut self) {
    let state = ConversationState::new(std::mem::take(&mut self.rows), self.total_row_count)
      .trim_retained_rows(RETAINED_FINALIZED_ROW_LIMIT);
    self.rows = state.rows;
    self.total_row_count = state.total_row_count;
  }

  fn sync_control_mode_from_integrations(&mut self) {
    self.control_mode = control_mode_from_parts(
      self.identity.provider,
      self.codex_integration_mode,
      self.claude_integration_mode,
    );
  }

  pub fn summary(&self, revision: u64) -> SessionSummary {
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
      sandbox_policy_details: self.config.sandbox_policy_details.clone(),
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
      summary_revision: revision,
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

  pub fn retained_state(&self, revision: u64) -> SessionState {
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
      can_interrupt: self.can_interrupt(),
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
      current_diff: self.current_diff.as_deref().map(String::from),
      cumulative_diff: None,
      current_plan: self.current_plan.as_deref().map(String::from),
      codex_integration_mode: self.codex_integration_mode,
      claude_integration_mode: self.claude_integration_mode,
      approval_policy: self.config.approval_policy.clone(),
      approval_policy_details: self.config.approval_policy_details.clone(),
      sandbox_mode: self.config.sandbox_mode.clone(),
      sandbox_policy_details: self.config.sandbox_policy_details.clone(),
      started_at: self.timestamps.started_at.clone(),
      last_activity_at: self.timestamps.last_activity_at.clone(),
      last_progress_at: self.timestamps.last_progress_at.clone(),
      forked_from_session_id: self.forked_from_session_id.clone(),
      revision: Some(revision),
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

  pub fn to_snapshot(&self, revision: u64, subscriber_count: usize) -> SessionSnapshot {
    build_session_snapshot(SessionSnapshotInput {
      identity: &self.identity,
      config: &self.config,
      display: &self.display,
      environment: &self.environment,
      timestamps: &self.timestamps,
      status: self.status,
      work_status: self.work_status,
      control_mode: self.control_mode,
      lifecycle_state: self.lifecycle_state,
      steerable: self.steerable,
      codex_integration_mode: self.codex_integration_mode,
      claude_integration_mode: self.claude_integration_mode,
      pending_approval: self.pending_approval.as_ref(),
      pending_tool_name: self.pending_tool_name.as_deref(),
      pending_tool_input: self.pending_tool_input.as_deref(),
      pending_question: self.pending_question.as_deref(),
      pending_approval_id: self.pending_approval_id.as_deref(),
      permission_mode: self.permission_mode.as_deref(),
      message_count: self.total_row_count as usize,
      active_worker_count: self
        .subagents
        .iter()
        .filter(|subagent| subagent.ended_at.is_none())
        .count() as u32,
      tool_count: self.tool_count,
      token_usage: &self.token_usage,
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      revision,
      current_plan: self.current_plan.as_deref(),
      current_diff: self.current_diff.as_deref(),
      approval_version: self.approval_version,
      terminal_session_id: self.terminal_session_id.as_deref(),
      terminal_app: self.terminal_app.as_deref(),
      repository_root: self.environment.repository_root.as_deref(),
      is_worktree: self.environment.is_worktree,
      worktree_id: self.environment.worktree_id.as_deref(),
      has_turn_diff: self.current_diff.is_some() || !self.turn_diffs.is_empty(),
      subscriber_count,
      unread_count: self.unread_count,
      mission_id: self.mission_id.as_deref(),
      issue_identifier: self.issue_identifier.as_deref(),
      allow_bypass_permissions: self.allow_bypass_permissions,
      newest_synced_row_id: self.newest_synced_row_id.as_deref(),
    })
  }

  pub fn restored_snapshot(&self) -> SessionSnapshot {
    build_restored_session_snapshot(SessionRestoreSnapshotInput {
      identity: &self.identity,
      config: &self.config,
      display: &self.display,
      environment: &self.environment,
      timestamps: &self.timestamps,
      status: self.status,
      work_status: self.work_status,
      control_mode: self.control_mode,
      lifecycle_state: self.lifecycle_state,
      permission_mode: self.permission_mode.as_deref(),
      token_usage: &self.token_usage,
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      rows: &self.rows,
      current_diff: self.current_diff.as_deref(),
      current_plan: self.current_plan.as_deref(),
      turn_diffs: &self.turn_diffs,
      pending_tool_name: self.pending_tool_name.as_deref(),
      pending_tool_input: self.pending_tool_input.as_deref(),
      pending_question: self.pending_question.as_deref(),
      pending_approval_id: self.pending_approval_id.as_deref(),
      terminal_session_id: self.terminal_session_id.as_deref(),
      terminal_app: self.terminal_app.as_deref(),
      approval_version: self.approval_version,
      unread_count: self.unread_count,
    })
  }

  pub fn set_subagents(&mut self, subagents: Vec<SubagentInfo>) {
    self.subagents = subagents;
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
  }

  pub fn set_mission_context(
    &mut self,
    mission_id: Option<String>,
    issue_identifier: Option<String>,
  ) {
    self.mission_id = mission_id;
    self.issue_identifier = issue_identifier;
  }

  pub fn set_allow_bypass_permissions(&mut self, enabled: bool) {
    self.allow_bypass_permissions = enabled;
  }

  pub fn set_custom_name(&mut self, name: Option<String>) {
    self.display.custom_name = name;
  }

  pub fn set_first_prompt(&mut self, prompt: Option<String>) {
    self.display.first_prompt = prompt;
  }

  pub fn set_last_message(&mut self, message: Option<String>) {
    self.display.last_message = message;
  }

  pub fn set_row_sequence(&mut self, row_id: &str, sequence: u64) {
    if let Some(entry) = self.rows.iter_mut().find(|e| e.id() == row_id) {
      entry.sequence = sequence;
    }
  }

  pub fn row_by_id(&self, row_id: &str) -> Option<&ConversationRowEntry> {
    self.rows.iter().find(|e| e.id() == row_id)
  }

  pub fn set_codex_integration_mode(&mut self, mode: Option<CodexIntegrationMode>) {
    self.codex_integration_mode = mode;
    self.sync_control_mode_from_integrations();
  }

  pub fn set_claude_integration_mode(&mut self, mode: Option<ClaudeIntegrationMode>) {
    self.claude_integration_mode = mode;
    self.sync_control_mode_from_integrations();
  }

  pub fn set_control_mode(&mut self, control_mode: SessionControlMode) {
    self.control_mode = control_mode;
  }

  pub fn set_project_name(&mut self, project_name: Option<String>) {
    self.identity.project_name = project_name;
  }

  pub fn set_git_branch(&mut self, branch: Option<String>) {
    self.environment.git_branch = branch;
  }

  pub fn set_transcript_path(&mut self, transcript_path: Option<String>) {
    self.identity.transcript_path = transcript_path;
  }

  pub fn set_newest_synced_row_id(&mut self, id: Option<String>) {
    self.newest_synced_row_id = id;
  }

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

  pub fn set_model(&mut self, model: Option<String>) {
    self.config.model = model;
  }

  pub fn set_effort(&mut self, effort: Option<String>) {
    self.config.effort = effort;
  }

  pub fn set_config(&mut self, patch: SessionConfigPatch) {
    let has_approval_policy = patch.approval_policy.is_some();
    let has_sandbox_mode = patch.sandbox_mode.is_some();
    let has_codex_config_overrides = patch.codex_config_overrides.is_some();
    let had_explicit_details = patch.approval_policy_details.is_some();
    let had_explicit_sandbox_details = patch.sandbox_policy_details.is_some();

    self.config.merge_from(patch);

    if !had_explicit_details && (has_approval_policy || has_codex_config_overrides) {
      self.config.approval_policy_details = resolve_approval_policy_details(
        self.config.approval_policy.as_deref(),
        self.config.codex_config_overrides.as_ref(),
      );
    }
    if !had_explicit_sandbox_details && (has_sandbox_mode || has_codex_config_overrides) {
      self.config.sandbox_policy_details = resolve_sandbox_policy_details(
        self.config.sandbox_mode.as_deref(),
        self.config.codex_config_overrides.as_ref(),
      );
    }
    if had_explicit_details {
      self.config.approval_policy = self
        .config
        .approval_policy_details
        .as_ref()
        .map(orbitdock_protocol::CodexApprovalPolicy::storage_text);
    }
    if had_explicit_sandbox_details {
      self.config.sandbox_mode = self
        .config
        .sandbox_policy_details
        .as_ref()
        .map(orbitdock_protocol::CodexSandboxPolicy::legacy_summary);
    }
  }

  pub fn set_forked_from(&mut self, source_session_id: String) {
    self.forked_from_session_id = Some(source_session_id);
  }

  pub fn set_terminal_info(
    &mut self,
    terminal_session_id: Option<String>,
    terminal_app: Option<String>,
  ) {
    self.terminal_session_id = terminal_session_id;
    self.terminal_app = terminal_app;
  }

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

  pub fn set_status(&mut self, status: SessionStatus) {
    self.status = status;
    if status == SessionStatus::Ended {
      self.clear_pending_approvals();
    }
  }

  pub fn set_started_at(&mut self, started_at: Option<String>) {
    self.timestamps.started_at = started_at;
  }

  pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
    self.timestamps.last_activity_at = last_activity_at;
  }

  pub fn set_work_status(&mut self, status: WorkStatus) {
    self.work_status = status;
    if status == WorkStatus::Ended {
      self.clear_pending_approvals();
    }
  }

  pub fn set_last_tool(&mut self, tool: Option<String>) {
    self.last_tool = tool;
  }

  pub fn update_tokens(&mut self, usage: TokenUsage) {
    self.token_usage = usage;
  }

  pub fn add_row(
    &mut self,
    mut entry: ConversationRowEntry,
    has_active_viewers: bool,
  ) -> ConversationRowEntry {
    let counts_as_progress = is_non_user_row(&entry);
    if entry.sequence == 0
      && self
        .rows
        .last()
        .is_none_or(|last| last.sequence >= entry.sequence)
    {
      entry.sequence = self.next_row_sequence();
    }
    if is_non_user_row(&entry) && !has_active_viewers {
      self.unread_count += 1;
    }
    if !is_local_http_row_id(entry.id()) {
      self.newest_synced_row_id = Some(entry.id().to_string());
    }
    self.rows.push(entry.clone());
    self.total_row_count = self.total_row_count.saturating_add(1);
    self.trim_retained_rows();
    let now = crate::support::session_time::chrono_now();
    self.timestamps.last_activity_at = Some(now.clone());
    if counts_as_progress {
      self.timestamps.last_progress_at = Some(now);
    }
    entry
  }

  pub fn unread_count_after_row_append(
    &self,
    entry: &ConversationRowEntry,
    has_active_viewers: bool,
  ) -> Option<u64> {
    (is_non_user_row(entry) && !has_active_viewers).then_some(self.unread_count)
  }

  pub fn upsert_row(&mut self, mut entry: ConversationRowEntry) -> ConversationRowEntry {
    let entry_id = entry.id().to_string();
    let counts_as_progress = is_non_user_row(&entry);
    if let Some(pos) = self.rows.iter().position(|r| r.id() == entry_id) {
      if entry.sequence == 0 {
        entry.sequence = self.rows[pos].sequence;
      }
      self.rows[pos] = entry.clone();
      if pos == self.rows.len() - 1 && !is_local_http_row_id(&entry_id) {
        self.newest_synced_row_id = Some(entry_id);
      }
      let now = crate::support::session_time::chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      entry
    } else {
      if entry.sequence == 0
        && self
          .rows
          .last()
          .is_none_or(|last| last.sequence >= entry.sequence)
      {
        entry.sequence = self.next_row_sequence();
      }
      if !is_local_http_row_id(entry.id()) {
        self.newest_synced_row_id = Some(entry.id().to_string());
      }
      self.rows.push(entry.clone());
      if self.rows.len() as u64 > self.total_row_count {
        self.total_row_count = self.rows.len() as u64;
      }
      self.trim_retained_rows();
      let now = crate::support::session_time::chrono_now();
      self.timestamps.last_activity_at = Some(now.clone());
      if counts_as_progress {
        self.timestamps.last_progress_at = Some(now);
      }
      entry
    }
  }

  pub fn note_transition_row_append(
    &mut self,
    entry: &RowEntrySummary,
    has_active_viewers: bool,
  ) -> Option<u64> {
    if !is_non_user_row_summary(entry) || has_active_viewers {
      return None;
    }
    self.unread_count += 1;
    Some(self.unread_count)
  }

  pub fn mark_read(&mut self) -> u64 {
    let prev = self.unread_count;
    self.unread_count = 0;
    prev
  }

  pub fn mark_last_turns_status(&mut self, num_turns: u32, status: TurnStatus) -> Vec<String> {
    if self.rows.is_empty() || num_turns == 0 {
      return vec![];
    }

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

  pub fn replace_rows(&mut self, rows: Vec<ConversationRowEntry>) {
    let rows = ConversationState::normalize_row_sequences(rows);
    self.newest_synced_row_id = latest_transcript_synced_row_id(&rows);
    self.total_row_count = rows.len() as u64;
    self.rows = rows;
    self.trim_retained_rows();
    self.timestamps.last_progress_at = Some(crate::support::session_time::chrono_now());
  }

  pub fn update_diff(&mut self, diff: String) {
    self.current_diff = Some(Arc::from(diff));
  }

  pub fn update_plan(&mut self, plan: String) {
    self.current_plan = Some(Arc::from(plan));
  }

  pub(crate) fn approval_queue_state(&self) -> ApprovalQueueState {
    let mut state = ApprovalQueueState::new(self.work_status);
    state.pending_approval = self.pending_approval.clone();
    state.pending_tool_name = self.pending_tool_name.clone();
    state.pending_tool_input = self.pending_tool_input.clone();
    state.pending_question = self.pending_question.clone();
    state.pending_approval_id = self.pending_approval_id.clone();
    state.pending_approvals = self.pending_approvals.clone();
    state.approval_version = self.approval_version;
    state
  }

  pub(crate) fn apply_approval_queue_state(&mut self, state: ApprovalQueueState) {
    self.pending_approval = state.pending_approval;
    self.pending_tool_name = state.pending_tool_name;
    self.pending_tool_input = state.pending_tool_input;
    self.pending_question = state.pending_question;
    self.pending_approval_id = state.pending_approval_id;
    self.pending_approvals = state.pending_approvals;
    self.approval_version = state.approval_version;
    self.work_status = state.work_status;
  }

  pub(crate) fn queue_pending_approval(
    &mut self,
    approval: ApprovalRequest,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
  ) -> PendingApprovalMutation {
    let (state, mutation) = self.approval_queue_state().queue_pending_approval(
      approval,
      approval_type,
      proposed_amendment,
    );
    self.apply_approval_queue_state(state);
    mutation
  }

  pub(crate) fn promote_queue_front(&mut self) {
    let state = self.approval_queue_state().promote_queue_front();
    self.apply_approval_queue_state(state);
  }

  pub(crate) fn clear_pending_approvals(&mut self) {
    let had_approvals = !self.pending_approvals.is_empty() || self.pending_approval.is_some();
    if had_approvals {
      let state = self.approval_queue_state().clear_pending_approvals();
      self.apply_approval_queue_state(state);
    }
  }

  pub(crate) fn bootstrap_pending_approval_from_persisted_fields(&mut self) {
    if self.pending_approvals.is_empty() {
      let state = self
        .approval_queue_state()
        .bootstrap_from_persisted_fields(&self.identity.id);
      self.apply_approval_queue_state(state);
    }
  }

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
    let (state, resolution) = self
      .approval_queue_state()
      .resolve_pending_approval(request_id, fallback_work_status);
    self.apply_approval_queue_state(state);

    (
      resolution.approval_type,
      resolution.proposed_amendment,
      resolution.active_approval,
      resolution.work_status,
    )
  }

  pub fn apply_changes(&mut self, changes: &StateChanges) {
    let prev_work_status = self.work_status;
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
    if let Some(ref custom_name) = changes.custom_name {
      self.display.custom_name = custom_name.clone();
    }
    if let Some(ref summary) = changes.summary {
      self.display.summary = summary.clone();
    }
    if let Some(ref model) = changes.model {
      self.config.model = model.clone();
    }
    if let Some(ref approval_policy) = changes.approval_policy {
      self.config.approval_policy = approval_policy.clone();
    }
    if let Some(ref approval_policy_details) = changes.approval_policy_details {
      self.config.approval_policy_details = approval_policy_details.clone();
      self.config.approval_policy = approval_policy_details
        .as_ref()
        .map(orbitdock_protocol::CodexApprovalPolicy::storage_text);
    }
    if let Some(ref sandbox_mode) = changes.sandbox_mode {
      self.config.sandbox_mode = sandbox_mode.clone();
    }
    if let Some(ref sandbox_policy_details) = changes.sandbox_policy_details {
      self.config.sandbox_policy_details = sandbox_policy_details.clone();
      self.config.sandbox_mode = sandbox_policy_details
        .as_ref()
        .map(orbitdock_protocol::CodexSandboxPolicy::legacy_summary);
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
    if changes.sandbox_policy_details.is_none()
      && (changes.sandbox_mode.is_some() || changes.codex_config_overrides.is_some())
    {
      self.config.sandbox_policy_details = resolve_sandbox_policy_details(
        self.config.sandbox_mode.as_deref(),
        self.config.codex_config_overrides.as_ref(),
      );
    }
    if let Some(ref codex_integration_mode) = changes.codex_integration_mode {
      self.codex_integration_mode = *codex_integration_mode;
    }
    if let Some(ref claude_integration_mode) = changes.claude_integration_mode {
      self.claude_integration_mode = *claude_integration_mode;
    }
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
      self.current_diff = current_diff.as_deref().map(Arc::from);
    }
    if let Some(ref current_plan) = changes.current_plan {
      self.current_plan = current_plan.as_deref().map(Arc::from);
    }
    if let Some(ref current_turn_id) = changes.current_turn_id {
      self.current_turn_id = current_turn_id.clone();
    }
    if let Some(turn_count) = changes.turn_count {
      self.turn_count = turn_count;
    }
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
    if let Some(ref first_prompt) = changes.first_prompt {
      self.display.first_prompt = first_prompt.clone();
    }
    if let Some(ref last_message) = changes.last_message {
      self.display.last_message = last_message.clone();
    }
    if let Some(ref effort) = changes.effort {
      self.config.effort = effort.clone();
    }

    let exiting_approval = matches!(
      prev_work_status,
      WorkStatus::Permission | WorkStatus::Question
    ) && !matches!(
      self.work_status,
      WorkStatus::Permission | WorkStatus::Question
    );
    if self.status == SessionStatus::Ended || self.work_status == WorkStatus::Ended {
      self.clear_pending_approvals();
    } else if !self.pending_approvals.is_empty() {
      self.promote_queue_front();
    } else if exiting_approval {
      self.pending_approval = None;
      self.pending_tool_name = None;
      self.pending_tool_input = None;
      self.pending_question = None;
      self.pending_approval_id = None;
    }
  }

  pub fn extract_state(&self, revision: u64) -> TransitionState {
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
      revision,
      phase,
      rows: self.rows.clone(),
      total_row_count: self.rows.last().map(|r| r.sequence + 1).unwrap_or(0),
      token_usage: self.token_usage.clone(),
      token_usage_snapshot_kind: self.token_usage_snapshot_kind,
      current_diff: self.current_diff.as_deref().map(String::from),
      current_plan: self.current_plan.as_deref().map(String::from),
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
      model: self.config.model.clone(),
      transcript_path: self.identity.transcript_path.clone(),
      last_tool: self.last_tool.clone(),
      pending_tool_name: self.pending_tool_name.clone(),
      pending_tool_input: self.pending_tool_input.clone(),
      pending_question: self.pending_question.clone(),
      subagents: self.subagents.clone(),
      summary: self.display.summary.clone(),
      effort: self.config.effort.clone(),
      first_prompt: self.display.first_prompt.clone(),
      turn_input_tokens: 0,
      turn_output_tokens: 0,
      turn_cached_tokens: 0,
    }
  }

  pub fn apply_state(&mut self, state: TransitionState) {
    let phase = state.phase.clone();
    let prev_work_status = self.work_status;
    self.work_status = phase.to_work_status();
    self.rows = state.rows;
    self.total_row_count = state.total_row_count;
    self.newest_synced_row_id = latest_transcript_synced_row_id(&self.rows);
    self.token_usage = state.token_usage;
    self.token_usage_snapshot_kind = state.token_usage_snapshot_kind;
    self.current_diff = state.current_diff.map(Arc::from);
    self.current_plan = state.current_plan.map(Arc::from);
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
    self.config.model = state.model;
    self.identity.transcript_path = state.transcript_path;
    self.last_tool = state.last_tool;
    self.pending_tool_name = state.pending_tool_name;
    self.pending_tool_input = state.pending_tool_input;
    self.pending_question = state.pending_question;
    self.subagents = state.subagents;
    self.display.summary = state.summary;
    self.config.effort = state.effort;
    self.display.first_prompt = state.first_prompt;

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

    let exiting_approval = matches!(
      prev_work_status,
      WorkStatus::Permission | WorkStatus::Question
    ) && !matches!(
      self.work_status,
      WorkStatus::Permission | WorkStatus::Question
    );
    if matches!(phase, WorkPhase::Ended { .. }) {
      self.clear_pending_approvals();
    } else if !self.pending_approvals.is_empty() {
      self.promote_queue_front();
    } else if exiting_approval {
      self.pending_approval = None;
      self.pending_tool_name = None;
      self.pending_tool_input = None;
      self.pending_question = None;
      self.pending_approval_id = None;
    }

    self.trim_retained_rows();
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::conversation_contracts::MessageRowContent;
  use orbitdock_protocol::Provider;

  fn user_row(id: &str, sequence: u64) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence,
      turn_id: None,
      turn_status: TurnStatus::Active,
      row: ConversationRow::User(MessageRowContent {
        id: id.to_string(),
        content: "hello".to_string(),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    }
  }

  #[test]
  fn add_row_does_not_advance_sync_anchor_for_local_http_rows() {
    let mut state = SessionCoreState::new(
      "session-1".to_string(),
      Provider::Codex,
      "/repo".to_string(),
    );
    state.add_row(user_row("row-transcript-1", 1), false);

    state.add_row(user_row("user-http-1", 2), false);

    assert_eq!(
      state.newest_synced_row_id.as_deref(),
      Some("row-transcript-1")
    );
  }

  #[test]
  fn apply_state_keeps_latest_transcript_anchor_when_http_row_is_newest() {
    let mut state = SessionCoreState::new(
      "session-1".to_string(),
      Provider::Codex,
      "/repo".to_string(),
    );
    state.add_row(user_row("row-transcript-1", 1), false);

    let mut transition = state.extract_state(0);
    transition.rows.push(user_row("user-http-1", 2));
    transition.total_row_count = transition.rows.len() as u64;

    state.apply_state(transition);

    assert_eq!(
      state.newest_synced_row_id.as_deref(),
      Some("row-transcript-1")
    );
  }
}
