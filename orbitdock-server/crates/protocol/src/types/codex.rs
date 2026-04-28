use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use super::{CodexApprovalPolicy, CodexApprovalsReviewer, CodexSandboxPolicy};

/// Codex integration mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexIntegrationMode {
  Direct,
  Passive,
}

/// Which config baseline OrbitDock should use for Codex sessions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigSource {
  #[default]
  Orbitdock,
  User,
}

/// How OrbitDock should select Codex configuration for a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigMode {
  #[default]
  Inherit,
  Profile,
  Custom,
}

/// Claude integration mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeIntegrationMode {
  Direct,
  Passive,
}

/// MCP elicitation mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElicitationMode {
  Form,
  Url,
}

/// Explicit session-scoped Codex overrides layered on top of resolved Codex config.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct CodexSessionOverrides {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approvals_reviewer: Option<CodexApprovalsReviewer>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub collaboration_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub multi_agent: Option<bool>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub personality: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub service_tier: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub effort: Option<String>,
}

impl CodexSessionOverrides {
  pub fn approval_policy_summary(&self) -> Option<String> {
    self
      .approval_policy_details
      .as_ref()
      .map(CodexApprovalPolicy::summary_text)
  }

  pub fn sandbox_mode_summary(&self) -> Option<String> {
    self
      .sandbox_policy_details
      .as_ref()
      .map(CodexSandboxPolicy::summary_text)
  }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CodexSessionOverridesWire {
  #[serde(default)]
  model: Option<String>,
  #[serde(default)]
  model_provider: Option<String>,
  #[serde(default)]
  approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default)]
  sandbox_policy_details: Option<CodexSandboxPolicy>,
  #[serde(default)]
  approvals_reviewer: Option<CodexApprovalsReviewer>,
  #[serde(default)]
  collaboration_mode: Option<String>,
  #[serde(default)]
  multi_agent: Option<bool>,
  #[serde(default)]
  personality: Option<String>,
  #[serde(default)]
  service_tier: Option<String>,
  #[serde(default)]
  developer_instructions: Option<String>,
  #[serde(default)]
  effort: Option<String>,
}

impl<'de> Deserialize<'de> for CodexSessionOverrides {
  fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    let wire = CodexSessionOverridesWire::deserialize(deserializer)?;
    Ok(Self {
      model: wire.model,
      model_provider: wire.model_provider,
      approval_policy_details: wire.approval_policy_details,
      sandbox_policy_details: wire.sandbox_policy_details,
      approvals_reviewer: wire.approvals_reviewer,
      collaboration_mode: wire.collaboration_mode,
      multi_agent: wire.multi_agent,
      personality: wire.personality,
      service_tier: wire.service_tier,
      developer_instructions: wire.developer_instructions,
      effort: wire.effort,
    })
  }
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
  #[serde(default)]
  pub supported_collaboration_modes: Vec<String>,
  #[serde(default)]
  pub supports_multi_agent: bool,
  #[serde(default)]
  pub multi_agent_is_experimental: bool,
  #[serde(default)]
  pub supports_personality: bool,
  #[serde(default)]
  pub supported_service_tiers: Vec<String>,
  #[serde(default)]
  pub supports_developer_instructions: bool,
}

/// Claude model option exposed to clients.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClaudeModelOption {
  pub value: String,
  pub display_name: String,
  pub description: String,
}

impl ClaudeModelOption {
  /// Hardcoded default models — always available regardless of account.
  /// Using the generic model specifiers automatically routes to the
  /// latest version (including 1M context when the account has access).
  pub fn defaults() -> Vec<Self> {
    vec![
      Self {
        value: "claude-opus-4-6".into(),
        display_name: "Opus 4.6".into(),
        description: "Most capable model for complex reasoning".into(),
      },
      Self {
        value: "claude-sonnet-4-6".into(),
        display_name: "Sonnet 4.6".into(),
        description: "Balanced performance and speed".into(),
      },
      Self {
        value: "claude-haiku-4-5".into(),
        display_name: "Haiku 4.5".into(),
        description: "Fast and lightweight".into(),
      },
    ]
  }

  /// Default context window for a given model string.
  /// Opus and Sonnet now support 1M context; Haiku stays at 200k.
  pub fn default_context_window(model: &str) -> u64 {
    let lower = model.to_lowercase();
    if lower.contains("haiku") {
      200_000
    } else {
      1_000_000
    }
  }
}

/// Skill attached to a message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillInput {
  pub name: String,
  pub path: String,
}

/// Image attached to a message
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ImageInput {
  /// "url" for data URI, "path" for local file, "attachment" for server-managed image ids
  pub input_type: String,
  /// Data URI string, local file path, or attachment id
  pub value: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub mime_type: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub byte_count: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub display_name: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub pixel_width: Option<u32>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub pixel_height: Option<u32>,
  /// Optional model image-detail hint: "auto", "low", "high", or "original".
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub detail: Option<String>,
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
