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
    pub timestamp: String,
    pub duration_ms: Option<u64>,
}

/// Token usage information
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_tokens: u64,
    pub context_window: u64,
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
    pub command: Option<String>,
    pub file_path: Option<String>,
    pub diff: Option<String>,
    pub question: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposed_amendment: Option<Vec<String>>,
}

/// Type of approval being requested
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalType {
    Exec,
    Patch,
    Question,
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
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub has_pending_approval: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
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
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub messages: Vec<Message>,
    pub pending_approval: Option<ApprovalRequest>,
    pub token_usage: TokenUsage,
    pub current_diff: Option<String>,
    pub current_plan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forked_from_session_id: Option<String>,
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
    pub current_diff: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_plan: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_name: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<Option<CodexIntegrationMode>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
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
}

/// Skill attached to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillInput {
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
    Ready,
    Failed { error: String },
    Cancelled,
}

/// MCP server startup failure detail
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpStartupFailure {
    pub server: String,
    pub error: String,
}
