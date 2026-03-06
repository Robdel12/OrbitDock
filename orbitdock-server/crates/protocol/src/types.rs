//! Core types shared across the protocol

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// AI provider type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Claude,
    Codex,
}

/// Codex integration mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexIntegrationMode {
    Direct,
    Passive,
}

/// Claude integration mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeIntegrationMode {
    Direct,
    Passive,
}

/// Session status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Active,
    Ended,
}

/// Work status - what the agent is currently doing
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkStatus {
    Working,
    Waiting,
    Permission,
    Question,
    Reply,
    Ended,
}

/// Message role
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    User,
    Assistant,
    System,
}

/// Message type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageType {
    User,
    Assistant,
    Thinking,
    Tool,
    ToolResult,
    Steer,
    Shell,
}

/// Terminal outcome of a shell command execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellExecutionOutcome {
    Completed,
    Failed,
    TimedOut,
    Canceled,
}

/// A message in the conversation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub session_id: String,
    pub message_type: MessageType,
    pub content: String,
    pub tool_name: Option<String>,
    pub tool_input: Option<String>,
    pub tool_output: Option<String>,
    pub is_error: bool,
    #[serde(default, skip_serializing_if = "bool_is_false")]
    pub is_in_progress: bool,
    pub timestamp: String,
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<ImageInput>,
}

/// Rate limit information from the Claude SDK
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateLimitInfo {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_limit_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub utilization: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_using_overage: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overage_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub surpassed_threshold: Option<f64>,
}

/// Token usage information
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_tokens: u64,
    pub context_window: u64,
}

/// Semantics for a token usage snapshot.
///
/// OrbitDock receives token values with different meaning depending on provider/integration mode.
/// Persist this explicitly so analytics and rollups stay correct.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenUsageSnapshotKind {
    /// Snapshot semantics are unknown (legacy callers).
    #[default]
    Unknown,
    /// Snapshot represents current turn/context occupancy, not lifetime totals.
    ContextTurn,
    /// Snapshot represents lifetime cumulative totals.
    LifetimeTotals,
    /// Snapshot mixes semantics (e.g. context input + cumulative output).
    MixedLegacy,
    /// Snapshot was emitted after a compaction reset event.
    CompactionReset,
}

impl TokenUsage {
    /// Calculate context fill percentage
    pub fn context_fill_percent(&self) -> f64 {
        if self.context_window == 0 {
            return 0.0;
        }
        (self.input_tokens as f64 / self.context_window as f64) * 100.0
    }

    /// Calculate cache hit percentage
    pub fn cache_hit_percent(&self) -> f64 {
        if self.input_tokens == 0 {
            return 0.0;
        }
        (self.cached_tokens as f64 / self.input_tokens as f64) * 100.0
    }
}

/// Approval request for tool execution
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalRequest {
    pub id: String,
    pub session_id: String,
    #[serde(rename = "type")]
    pub approval_type: ApprovalType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_input: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
    pub diff: Option<String>,
    pub question: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub question_prompts: Vec<ApprovalQuestionPrompt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<ApprovalPreview>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposed_amendment: Option<Vec<String>>,
    /// Raw permission suggestions from Claude SDK (PermissionUpdate[]).
    /// Opaque JSON passed through for client display.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission_suggestions: Option<serde_json::Value>,
}

/// Structured question option metadata for question approvals.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalQuestionOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Structured question prompt metadata for question approvals.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalQuestionPrompt {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub question: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<ApprovalQuestionOption>,
    #[serde(default, skip_serializing_if = "bool_is_false")]
    pub allows_multiple_selection: bool,
    #[serde(default, skip_serializing_if = "bool_is_false")]
    pub allows_other: bool,
    #[serde(default, skip_serializing_if = "bool_is_false")]
    pub is_secret: bool,
}

/// Type of approval being requested
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalType {
    Exec,
    Patch,
    Question,
}

fn bool_is_false(value: &bool) -> bool {
    !*value
}

/// Client-facing preview metadata for pending approvals.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalPreview {
    #[serde(rename = "type")]
    pub preview_type: ApprovalPreviewType,
    pub value: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shell_segments: Vec<ApprovalPreviewSegment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compact: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision_scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub risk_level: Option<ApprovalRiskLevel>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub risk_findings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifest: Option<String>,
}

/// Display kind for approval preview value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalPreviewType {
    ShellCommand,
    Diff,
    Url,
    SearchQuery,
    Pattern,
    Prompt,
    Value,
    FilePath,
    Action,
}

/// Risk tier for an approval request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalRiskLevel {
    Low,
    Normal,
    High,
}

/// Segment in a shell command split by control operators.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalPreviewSegment {
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leading_operator: Option<String>,
}

/// Persisted approval history item
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalHistoryItem {
    pub id: i64,
    pub session_id: String,
    pub request_id: String,
    pub approval_type: ApprovalType,
    pub tool_name: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
    pub cwd: Option<String>,
    pub decision: Option<String>,
    pub proposed_amendment: Option<Vec<String>>,
    pub created_at: String,
    pub decided_at: Option<String>,
}

/// Summary of a session for list views
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    pub project_name: Option<String>,
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message: Option<String>,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    #[serde(default)]
    pub token_usage: TokenUsage,
    #[serde(default)]
    pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
    pub has_pending_approval: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_integration_mode: Option<ClaudeIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_tool_input: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_question: Option<String>,
    /// The connector-path request_id for the pending approval, persisted to DB so it
    /// survives server restarts. When set, clicking Allow/Deny will route correctly
    /// even after a server restart broke the in-memory channel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_approval_id: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Monotonic counter incremented on every approval state change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_version: Option<u64>,
    /// Canonical repo root (resolves worktrees to parent repo).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<String>,
    /// True if the session's cwd is inside a linked git worktree.
    #[serde(default)]
    pub is_worktree: bool,
    /// ID of the tracked worktree record (if any).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<String>,
    /// Number of unread messages in this session.
    #[serde(default)]
    pub unread_count: u64,
}

/// A diff snapshot from a completed turn
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnDiff {
    pub turn_id: String,
    pub diff: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_kind: Option<TokenUsageSnapshotKind>,
}

/// Subagent metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubagentInfo {
    pub id: String,
    pub agent_type: String,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
}

/// A tool call from a subagent transcript
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubagentTool {
    pub id: String,
    pub tool_name: String,
    pub summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    pub is_in_progress: bool,
}

/// Full session state
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<String>,
    pub project_name: Option<String>,
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message: Option<String>,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub messages: Vec<Message>,
    pub pending_approval: Option<ApprovalRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_tool_input: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_question: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_approval_id: Option<String>,
    pub token_usage: TokenUsage,
    #[serde(default)]
    pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
    pub current_diff: Option<String>,
    pub current_plan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_integration_mode: Option<ClaudeIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forked_from_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_turn_id: Option<String>,
    #[serde(default)]
    pub turn_count: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub turn_diffs: Vec<TurnDiff>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subagents: Vec<SubagentInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_app: Option<String>,
    /// Monotonic counter incremented on every approval state change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_version: Option<u64>,
    /// Canonical repo root (resolves worktrees to parent repo).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<String>,
    /// True if the session's cwd is inside a linked git worktree.
    #[serde(default)]
    pub is_worktree: bool,
    /// ID of the tracked worktree record (if any).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<String>,
    /// Number of unread messages in this session.
    #[serde(default)]
    pub unread_count: u64,
}

/// Changes to apply to a session state (delta updates)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StateChanges {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<SessionStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub work_status: Option<WorkStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_approval: Option<Option<ApprovalRequest>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage_snapshot_kind: Option<TokenUsageSnapshotKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_diff: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_plan: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_message: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<Option<CodexIntegrationMode>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_integration_mode: Option<Option<ClaudeIntegrationMode>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_turn_id: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_sha: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_cwd: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<Option<String>>,
    /// Monotonic counter incremented on every approval state change.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_version: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_worktree: Option<bool>,
    /// Updated unread message count.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unread_count: Option<u64>,
}

/// Changes to apply to a message (delta updates)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MessageChanges {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_in_progress: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

/// Codex model option exposed to clients.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexModelOption {
    pub id: String,
    pub model: String,
    pub display_name: String,
    pub description: String,
    pub is_default: bool,
    pub supported_reasoning_efforts: Vec<String>,
    #[serde(default)]
    pub supports_reasoning_summaries: bool,
}

/// Claude model option exposed to clients.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeModelOption {
    pub value: String,
    pub display_name: String,
    pub description: String,
}

/// Skill attached to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillInput {
    pub name: String,
    pub path: String,
}

/// Image attached to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageInput {
    /// "url" for data URI, "path" for local file
    pub input_type: String,
    /// Data URI string or local file path
    pub value: String,
}

/// File/resource mention attached to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MentionInput {
    pub name: String,
    pub path: String,
}

/// Scope of a skill
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillScope {
    User,
    Repo,
    System,
    Admin,
}

/// Metadata about a discovered skill
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillMetadata {
    pub name: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub short_description: Option<String>,
    pub path: String,
    pub scope: SkillScope,
    pub enabled: bool,
}

/// Error loading a skill
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillErrorInfo {
    pub path: String,
    pub message: String,
}

/// Skills grouped by cwd
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillsListEntry {
    pub cwd: String,
    pub skills: Vec<SkillMetadata>,
    pub errors: Vec<SkillErrorInfo>,
}

/// Remote skill summary
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteSkillSummary {
    pub id: String,
    pub name: String,
    pub description: String,
}

// MARK: - MCP Types

/// MCP tool definition (mirrors codex-core mcp::Tool)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpTool {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    pub input_schema: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_schema: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<Value>,
}

/// MCP resource (mirrors codex-core mcp::Resource)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpResource {
    pub name: String,
    pub uri: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<Value>,
}

/// MCP resource template (mirrors codex-core mcp::ResourceTemplate)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpResourceTemplate {
    pub name: String,
    pub uri_template: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<Value>,
}

/// MCP server auth status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum McpAuthStatus {
    Unsupported,
    NotLoggedIn,
    BearerToken,
    OAuth,
}

/// MCP server startup status
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum McpStartupStatus {
    Starting,
    Connecting,
    Ready,
    Failed { error: String },
    NeedsAuth,
    Cancelled,
}

/// MCP server startup failure detail
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpStartupFailure {
    pub server: String,
    pub error: String,
}

// MARK: - Codex Account Auth Types

/// High-level auth mode for Codex account access.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexAuthMode {
    ApiKey,
    Chatgpt,
}

/// Current Codex account details.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CodexAccount {
    ApiKey,
    Chatgpt {
        #[serde(skip_serializing_if = "Option::is_none")]
        email: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        plan_type: Option<String>,
    },
}

/// Result of attempting to cancel a pending ChatGPT login flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexLoginCancelStatus {
    Canceled,
    NotFound,
    InvalidId,
}

/// Snapshot of Codex auth/account state for UI consumption.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexAccountStatus {
    pub auth_mode: Option<CodexAuthMode>,
    pub requires_openai_auth: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account: Option<CodexAccount>,
    pub login_in_progress: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_login_id: Option<String>,
}

// MARK: - Provider Usage Types

/// Error payload for provider usage probe responses.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageErrorInfo {
    pub code: String,
    pub message: String,
}

/// A client device that currently claims this server as its primary control plane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientPrimaryClaim {
    pub client_id: String,
    pub device_name: String,
}

/// Codex rate-limit window.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRateLimitWindow {
    pub used_percent: f64,
    pub window_duration_mins: u32,
    pub resets_at_unix: f64,
}

/// Endpoint-scoped Codex usage snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexUsageSnapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary: Option<CodexRateLimitWindow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary: Option<CodexRateLimitWindow>,
    pub fetched_at_unix: f64,
}

/// Claude subscription usage window.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeUsageWindow {
    pub utilization: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
}

/// Endpoint-scoped Claude subscription usage snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeUsageSnapshot {
    pub five_hour: ClaudeUsageWindow,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seven_day: Option<ClaudeUsageWindow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seven_day_sonnet: Option<ClaudeUsageWindow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seven_day_opus: Option<ClaudeUsageWindow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_limit_tier: Option<String>,
    pub fetched_at_unix: f64,
}

// MARK: - Review Comment Types

/// Tag for a review comment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCommentTag {
    Clarity,
    Scope,
    Risk,
    Nit,
}

/// Status of a review comment
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewCommentStatus {
    Open,
    Resolved,
}

/// A review comment on a diff line or range
#[derive(Debug, Clone, Serialize, Deserialize)]
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

// Remote filesystem browsing

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectoryEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_git: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecentProject {
    pub path: String,
    pub session_count: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_active: Option<String>,
}

// ---------------------------------------------------------------------------
// Worktree types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeStatus {
    Active,
    Orphaned,
    Stale,
    Removing,
    Removed,
}

impl WorktreeStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Orphaned => "orphaned",
            Self::Stale => "stale",
            Self::Removing => "removing",
            Self::Removed => "removed",
        }
    }

    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s {
            "active" => Some(Self::Active),
            "orphaned" => Some(Self::Orphaned),
            "stale" => Some(Self::Stale),
            "removing" => Some(Self::Removing),
            "removed" => Some(Self::Removed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorktreeOrigin {
    User,
    Agent,
    Discovered,
}

impl WorktreeOrigin {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Agent => "agent",
            Self::Discovered => "discovered",
        }
    }

    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Self::User),
            "agent" => Some(Self::Agent),
            "discovered" => Some(Self::Discovered),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeSummary {
    pub id: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_branch: Option<String>,
    pub status: WorktreeStatus,
    pub active_session_count: u32,
    pub total_session_count: u32,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_ended_at: Option<String>,
    pub disk_present: bool,
    pub auto_prune: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<String>,
    pub created_by: WorktreeOrigin,
}

// ---------------------------------------------------------------------------
// Permission Rules (returned by GET /api/sessions/{id}/permissions)
// ---------------------------------------------------------------------------

/// A single permission rule from a provider's configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionRule {
    /// Rule pattern, e.g. "Bash(make:*)", "WebSearch", "mcp__xcode__XcodeRead"
    pub pattern: String,
    /// Behavior: "allow", "deny", or "ask"
    pub behavior: String,
}

/// Provider-specific permission configuration snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "provider", rename_all = "snake_case")]
pub enum SessionPermissionRules {
    Claude {
        #[serde(skip_serializing_if = "Option::is_none")]
        permission_mode: Option<String>,
        rules: Vec<PermissionRule>,
        #[serde(skip_serializing_if = "Option::is_none")]
        additional_directories: Option<Vec<String>>,
    },
    Codex {
        #[serde(skip_serializing_if = "Option::is_none")]
        approval_policy: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        sandbox_mode: Option<String>,
    },
}
