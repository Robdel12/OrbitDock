use serde::{Deserialize, Serialize};
use serde_json::Value;

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
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_reason: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub requested_permissions: Option<Value>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub granted_permissions: Option<Value>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub proposed_amendment: Option<Vec<String>>,
  /// Raw permission suggestions from Claude SDK (PermissionUpdate[]).
  /// Opaque JSON passed through for client display.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_suggestions: Option<serde_json::Value>,
  /// MCP elicitation mode: "form" or "url"
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_mode: Option<String>,
  /// JSON Schema for form-mode MCP elicitation
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_schema: Option<serde_json::Value>,
  /// URL for browser-auth-mode MCP elicitation
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_url: Option<String>,
  /// Human-readable message from the MCP server
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_message: Option<String>,
  /// Which MCP server initiated the elicitation
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub mcp_server_name: Option<String>,
  /// Network approval context: target host
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub network_host: Option<String>,
  /// Network approval context: protocol (e.g. "https")
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub network_protocol: Option<String>,
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
  Permissions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionGrantScope {
  Turn,
  Session,
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
  pub risk_level: ApprovalRiskLevel,
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
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub tool_input: Option<String>,
  pub command: Option<String>,
  pub file_path: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub diff: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub question: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub question_prompts: Vec<ApprovalQuestionPrompt>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview: Option<ApprovalPreview>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_reason: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub requested_permissions: Option<Value>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub granted_permissions: Option<Value>,
  pub cwd: Option<String>,
  pub decision: Option<String>,
  pub proposed_amendment: Option<Vec<String>>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub permission_suggestions: Option<Value>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_schema: Option<Value>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_url: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub elicitation_message: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub mcp_server_name: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub network_host: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub network_protocol: Option<String>,
  pub created_at: String,
  pub decided_at: Option<String>,
}
