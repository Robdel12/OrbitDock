//! Server → Client messages

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::conversation_contracts::RowEntrySummary;
use crate::types::*;

/// Messages sent from server to client
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
  Hello {
    hello: ServerHello,
  },
  SessionsSummaryInvalidated {
    revision: u64,
  },
  ActiveSessionsInvalidated {
    revision: u64,
  },
  ArchivedSessionsInvalidated {
    revision: u64,
  },
  MissionsInvalidated {
    revision: u64,
  },
  SessionSurfaceInvalidated {
    session_id: String,
    surface: SessionSurface,
    revision: u64,
  },

  // Incremental updates
  SessionDelta {
    session_id: String,
    changes: Box<StateChanges>,
  },
  ConversationRowsChanged {
    session_id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    upserted: Vec<RowEntrySummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    removed_row_ids: Vec<String>,
    total_row_count: u64,
  },
  ApprovalRequested {
    session_id: String,
    request: Box<ApprovalRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_version: Option<u64>,
  },
  TokensUpdated {
    session_id: String,
    usage: TokenUsage,
    snapshot_kind: TokenUsageSnapshotKind,
  },

  // Lifecycle
  SessionEnded {
    session_id: String,
    reason: String,
  },
  SessionForked {
    source_session_id: String,
    new_session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    forked_from_thread_id: Option<String>,
  },

  // Steer outcome — tells clients whether a steer attached to the active
  // turn or fell back to starting a new one.
  SteerOutcome {
    session_id: String,
    message_id: String,
    outcome: crate::types::SteerOutcome,
  },

  // Approval history
  ApprovalsList {
    session_id: Option<String>,
    approvals: Vec<ApprovalHistoryItem>,
  },
  ApprovalDeleted {
    approval_id: i64,
  },

  // Codex models
  ModelsList {
    models: Vec<CodexModelOption>,
  },
  // Codex account/auth status
  CodexAccountStatus {
    status: CodexAccountStatus,
  },
  CodexLoginChatgptStarted {
    login_id: String,
    auth_url: String,
  },
  CodexLoginChatgptCompleted {
    login_id: String,
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
  },
  CodexLoginChatgptCanceled {
    login_id: String,
    status: CodexLoginCancelStatus,
  },
  CodexAccountUpdated {
    status: CodexAccountStatus,
  },

  // Skills
  SkillsList {
    session_id: String,
    skills: Vec<SkillsListEntry>,
    errors: Vec<SkillErrorInfo>,
  },
  SkillsUpdateAvailable {
    session_id: String,
  },

  // MCP
  McpToolsList {
    session_id: String,
    tools: HashMap<String, McpTool>,
    resources: HashMap<String, Vec<McpResource>>,
    resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
    auth_statuses: HashMap<String, McpAuthStatus>,
  },
  McpStartupUpdate {
    session_id: String,
    server: String,
    status: McpStartupStatus,
  },
  McpStartupComplete {
    session_id: String,
    ready: Vec<String>,
    failed: Vec<McpStartupFailure>,
    cancelled: Vec<String>,
  },

  // Claude capabilities (from init system message)
  ClaudeCapabilities {
    session_id: String,
    slash_commands: Vec<String>,
    skills: Vec<String>,
    tools: Vec<String>,
    models: Vec<crate::ClaudeModelOption>,
  },

  // Context management
  ContextCompacted {
    session_id: String,
  },
  UndoStarted {
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
  },
  UndoCompleted {
    session_id: String,
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
  },
  ThreadRolledBack {
    session_id: String,
    num_turns: u32,
  },

  // Turn diffs
  TurnDiffSnapshot {
    session_id: String,
    turn_id: String,
    diff: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    input_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    output_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cached_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context_window: Option<u64>,
    snapshot_kind: TokenUsageSnapshotKind,
  },

  // Review comments
  ReviewCommentCreated {
    session_id: String,
    review_revision: u64,
    comment: ReviewComment,
  },
  ReviewCommentUpdated {
    session_id: String,
    review_revision: u64,
    comment: ReviewComment,
  },
  ReviewCommentDeleted {
    session_id: String,
    review_revision: u64,
    comment_id: String,
  },
  ReviewCommentsList {
    session_id: String,
    review_revision: u64,
    comments: Vec<ReviewComment>,
  },

  // Subagent tools
  SubagentToolsList {
    session_id: String,
    subagent_id: String,
    tools: Vec<SubagentTool>,
  },

  // Interactive terminal sessions
  TerminalCreated {
    terminal_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
  },
  TerminalExited {
    terminal_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit_code: Option<i32>,
  },

  // Tool PTY streaming (live bash tool output)
  ToolPtyAttached {
    tool_id: String,
    /// Base64-encoded replay buffer for late-joining clients.
    #[serde(skip_serializing_if = "Option::is_none")]
    buffered_output: Option<String>,
  },
  ToolPtyDetached {
    tool_id: String,
  },
  ToolPtyExited {
    tool_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit_code: Option<i32>,
  },

  // Shell execution results
  ShellStarted {
    session_id: String,
    request_id: String,
    command: String,
  },
  ShellOutput {
    session_id: String,
    request_id: String,
    stdout: String,
    stderr: String,
    exit_code: Option<i32>,
    duration_ms: u64,
    outcome: ShellExecutionOutcome,
  },

  // Remote filesystem browsing
  DirectoryListing {
    request_id: String,
    path: String,
    entries: Vec<DirectoryEntry>,
  },
  RecentProjectsList {
    request_id: String,
    projects: Vec<RecentProject>,
  },
  CodexUsageResult {
    request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<CodexUsageSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_info: Option<UsageErrorInfo>,
  },
  ClaudeUsageResult {
    request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<ClaudeUsageSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_info: Option<UsageErrorInfo>,
  },

  // Server config
  OpenAiKeyStatus {
    request_id: String,
    configured: bool,
  },
  ServerInfo {
    is_primary: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    client_primary_claims: Vec<ClientPrimaryClaim>,
  },

  /// Notifies connected clients that a newer server version is available.
  UpdateAvailable {
    current_version: String,
    latest_version: String,
    release_url: String,
    channel: String,
  },

  // Approval decision result
  ApprovalDecisionResult {
    session_id: String,
    request_id: String,
    outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    active_request_id: Option<String>,
    approval_version: u64,
  },

  // Worktree management
  WorktreesList {
    request_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    repo_root: Option<String>,
    worktree_revision: u64,
    worktrees: Vec<crate::WorktreeSummary>,
  },
  WorktreeCreated {
    request_id: String,
    repo_root: String,
    worktree_revision: u64,
    worktree: crate::WorktreeSummary,
  },
  WorktreeRemoved {
    request_id: String,
    repo_root: String,
    worktree_revision: u64,
    worktree_id: String,
  },
  WorktreeStatusChanged {
    worktree_id: String,
    status: crate::WorktreeStatus,
    repo_root: String,
  },
  WorktreeError {
    request_id: String,
    code: String,
    message: String,
  },

  // Rate limit
  RateLimitEvent {
    session_id: String,
    info: RateLimitInfo,
  },

  // Prompt suggestion
  PromptSuggestion {
    session_id: String,
    suggestion: String,
  },

  // Files persisted (checkpoint saved)
  FilesPersisted {
    session_id: String,
    files: Vec<String>,
  },

  // Permission rules snapshot
  PermissionRules {
    session_id: String,
    rules: crate::SessionPermissionRules,
  },

  // Mission Control
  MissionHeartbeat {
    mission_id: String,
    tick_started_at: String,
    next_tick_at: String,
  },
  MissionInvalidated {
    mission_id: String,
    revision: u64,
  },

  // Errors
  Error {
    code: String,
    message: String,
    session_id: Option<String>,
  },
}

#[cfg(test)]
#[path = "server_tests.rs"]
mod tests;
