//! Core types shared across the protocol

use serde::{Deserialize, Serialize};

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

/// Summary of a session for list views
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
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
