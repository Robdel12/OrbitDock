//! Core types shared across the protocol

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

mod session;

pub use session::*;

/// AI provider type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
  Claude,
  Codex,
}

impl std::str::FromStr for Provider {
  type Err = std::convert::Infallible;
  fn from_str(s: &str) -> Result<Self, Self::Err> {
    Ok(match s {
      "codex" => Provider::Codex,
      _ => Provider::Claude,
    })
  }
}

/// Where mission workspaces should be provisioned and run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceProviderKind {
  #[default]
  Local,
  Daytona,
}

impl WorkspaceProviderKind {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Local => "local",
      Self::Daytona => "daytona",
    }
  }
}

impl std::str::FromStr for WorkspaceProviderKind {
  type Err = String;

  fn from_str(s: &str) -> Result<Self, Self::Err> {
    match s.trim().to_ascii_lowercase().as_str() {
      "local" => Ok(Self::Local),
      "daytona" => Ok(Self::Daytona),
      other => Err(format!("unsupported workspace provider '{other}'")),
    }
  }
}

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CodexApprovalMode {
  #[serde(rename = "untrusted")]
  Untrusted,
  #[serde(rename = "on-failure")]
  OnFailure,
  #[serde(rename = "on-request")]
  OnRequest,
  #[serde(rename = "never")]
  Never,
}

impl CodexApprovalMode {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Untrusted => "untrusted",
      Self::OnFailure => "on-failure",
      Self::OnRequest => "on-request",
      Self::Never => "never",
    }
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalsReviewer {
  User,
  GuardianSubagent,
}

impl CodexApprovalsReviewer {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::User => "user",
      Self::GuardianSubagent => "guardian_subagent",
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexGranularApprovalPolicy {
  pub sandbox_approval: bool,
  pub rules: bool,
  pub skill_approval: bool,
  pub request_permissions: bool,
  pub mcp_elicitations: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CodexApprovalPolicy {
  Mode(CodexApprovalMode),
  Granular {
    granular: CodexGranularApprovalPolicy,
  },
}

impl CodexApprovalPolicy {
  pub fn summary_text(&self) -> String {
    match self {
      Self::Mode(mode) => mode.as_str().to_string(),
      Self::Granular { .. } => "reject".to_string(),
    }
  }

  pub fn from_storage_text(value: &str) -> Option<Self> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      return None;
    }

    if trimmed.starts_with('{') || trimmed.starts_with('"') {
      if let Ok(policy) = serde_json::from_str::<Self>(trimmed) {
        return Some(policy);
      }
    }

    match trimmed {
      "untrusted" | "unless-allow-listed" => Some(Self::Mode(CodexApprovalMode::Untrusted)),
      "on-failure" => Some(Self::Mode(CodexApprovalMode::OnFailure)),
      "on-request" => Some(Self::Mode(CodexApprovalMode::OnRequest)),
      "never" => Some(Self::Mode(CodexApprovalMode::Never)),
      "reject" => Some(Self::Granular {
        granular: CodexGranularApprovalPolicy {
          sandbox_approval: false,
          rules: false,
          skill_approval: false,
          request_permissions: false,
          mcp_elicitations: false,
        },
      }),
      _ => None,
    }
  }

  pub fn storage_text(&self) -> String {
    match self {
      Self::Mode(mode) => mode.as_str().to_string(),
      Self::Granular { .. } => serde_json::to_string(self).unwrap_or_else(|_| self.summary_text()),
    }
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CodexSandboxMode {
  DangerFullAccess,
  ReadOnly,
  WorkspaceWrite,
  ExternalSandbox,
}

impl CodexSandboxMode {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::DangerFullAccess => "danger-full-access",
      Self::ReadOnly => "read-only",
      Self::WorkspaceWrite => "workspace-write",
      Self::ExternalSandbox => "external-sandbox",
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexSandboxPolicy {
  pub mode: CodexSandboxMode,
  #[serde(default)]
  pub network_access: bool,
}

impl CodexSandboxPolicy {
  pub fn summary_text(&self) -> String {
    if self.network_access {
      match self.mode {
        CodexSandboxMode::DangerFullAccess => "danger-full-access".to_string(),
        CodexSandboxMode::ReadOnly => "read-only-network".to_string(),
        CodexSandboxMode::WorkspaceWrite => "workspace-write-network".to_string(),
        CodexSandboxMode::ExternalSandbox => "external-sandbox-network".to_string(),
      }
    } else {
      self.mode.as_str().to_string()
    }
  }

  pub fn from_storage_text(value: &str) -> Option<Self> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      return None;
    }

    if trimmed.starts_with('{') {
      if let Ok(policy) = serde_json::from_str::<Self>(trimmed) {
        return Some(policy);
      }
    }

    let parsed = match trimmed {
      "danger-full-access" => Self {
        mode: CodexSandboxMode::DangerFullAccess,
        network_access: true,
      },
      "read-only" => Self {
        mode: CodexSandboxMode::ReadOnly,
        network_access: false,
      },
      "read-only-network" => Self {
        mode: CodexSandboxMode::ReadOnly,
        network_access: true,
      },
      "workspace-write" => Self {
        mode: CodexSandboxMode::WorkspaceWrite,
        network_access: false,
      },
      "workspace-write-network" => Self {
        mode: CodexSandboxMode::WorkspaceWrite,
        network_access: true,
      },
      "external-sandbox" => Self {
        mode: CodexSandboxMode::ExternalSandbox,
        network_access: false,
      },
      "external-sandbox-network" => Self {
        mode: CodexSandboxMode::ExternalSandbox,
        network_access: true,
      },
      _ => return None,
    };

    Some(parsed)
  }

  pub fn storage_text(&self) -> String {
    self.summary_text()
  }
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

/// Session status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
  Active,
  Ended,
}

/// Outcome of a steer-turn attempt, surfaced to clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SteerOutcome {
  /// The steer was accepted by the active turn.
  Accepted,
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

/// Terminal outcome of a shell command execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellExecutionOutcome {
  Completed,
  Failed,
  TimedOut,
  Canceled,
}

/// Normalized approval decision used by OrbitDock's client-facing API.
///
/// This stays stable for UI and transport code, then gets translated into
/// provider-native approval commands before reaching a connector.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolApprovalDecision {
  Approved,
  ApprovedForSession,
  ApprovedAlways,
  Denied,
  Abort,
}

impl ToolApprovalDecision {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Approved => "approved",
      Self::ApprovedForSession => "approved_for_session",
      Self::ApprovedAlways => "approved_always",
      Self::Denied => "denied",
      Self::Abort => "abort",
    }
  }
}

impl std::fmt::Display for ToolApprovalDecision {
  fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
    f.write_str(self.as_str())
  }
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
  /// Snapshot semantics are unknown.
  #[default]
  Unknown,
  /// Snapshot represents current turn/context occupancy, not lifetime totals.
  ContextTurn,
  /// Snapshot represents lifetime cumulative totals.
  LifetimeTotals,
  /// Snapshot mixes semantics (e.g. context input + cumulative output).
  Mixed,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerHello {
  pub server_version: String,
  pub minimum_client_version: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerMeta {
  pub server_version: String,
  pub minimum_client_version: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub capabilities: Vec<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub server_instance_id: Option<String>,
  pub is_primary: bool,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub client_primary_claims: Vec<ClientPrimaryClaim>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub update_status: Option<UpdateStatus>,
}

/// Cached result of the latest update check, included in ServerMeta.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateStatus {
  pub update_available: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub latest_version: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub release_url: Option<String>,
  pub channel: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub checked_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardCounts {
  pub attention: u32,
  pub running: u32,
  pub ready: u32,
  pub direct: u32,
}

/// Pre-computed project group for dashboard display.
/// Server computes grouping once; clients render directly without re-grouping.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardProjectGroup {
  /// Project path used for grouping (e.g., "/Users/dev/myproject")
  pub path: String,
  /// Display name for the project (e.g., "myproject")
  pub name: String,
  /// Endpoint ID for multi-server setups
  pub endpoint_id: String,
  /// Optional endpoint display name
  #[serde(skip_serializing_if = "Option::is_none")]
  pub endpoint_name: Option<String>,
  /// Count of sessions needing attention (permission/question)
  pub attention_count: u32,
  /// Count of sessions currently working
  pub working_count: u32,
  /// Count of sessions ready/waiting
  pub ready_count: u32,
  /// Session IDs in this group (references into conversations array)
  pub session_ids: Vec<String>,
  /// Most recent activity timestamp in this group
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardSnapshot {
  pub revision: u64,
  pub conversations: Vec<DashboardConversationItem>,
  pub counts: DashboardCounts,
  /// Pre-computed project groups for efficient client rendering.
  /// Groups are sorted alphabetically by name.
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub project_groups: Vec<DashboardProjectGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSummaryModelCost {
  pub model: String,
  pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSummaryBucket {
  pub session_count: u64,
  #[serde(default)]
  pub distinct_session_count: u64,
  pub total_tokens: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_cost_usd: f64,
  #[serde(default)]
  pub cost_by_model: Vec<UsageSummaryModelCost>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSummarySnapshot {
  pub today: UsageSummaryBucket,
  pub all_time: UsageSummaryBucket,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageOverviewSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub today_start_unix: Option<u64>,
  pub summary: UsageSummarySnapshot,
  pub today_provider_breakdown: UsageBreakdownSnapshot,
  pub today_model_breakdown: UsageBreakdownSnapshot,
  pub day_breakdown: UsageBreakdownSnapshot,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum UsageBreakdownGroupBy {
  Provider,
  #[default]
  Model,
  Session,
  Day,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageBreakdownEntry {
  pub group_key: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub provider: Option<Provider>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_id: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub day_start_unix: Option<u64>,
  pub turn_count: u64,
  pub session_count: u64,
  #[serde(default)]
  pub distinct_session_count: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_tokens: u64,
  pub total_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageBreakdownSnapshot {
  pub group_by: UsageBreakdownGroupBy,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub end_unix: Option<u64>,
  pub totals: UsageSummaryBucket,
  #[serde(default)]
  pub groups: Vec<UsageBreakdownEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageSessionSummary {
  pub session_id: String,
  pub provider: Provider,
  pub display_name: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub project_name: Option<String>,
  pub project_path: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub context_line: Option<String>,
  pub turn_count: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_tokens: u64,
  pub total_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsageSessionsSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub end_unix: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub next_offset: Option<u64>,
  pub total_count: u64,
  #[serde(default)]
  pub sessions: Vec<UsageSessionSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UsagePricingSnapshotPayload {
  pub source: String,
  pub version: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_key: Option<String>,
  pub input_cost_per_token: f64,
  pub output_cost_per_token: f64,
  pub cache_read_cost_per_token: f64,
  pub cache_write_cost_per_token: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionUsageTurnEntry {
  pub turn_id: String,
  pub turn_seq: u64,
  pub provider: Provider,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub observed_at: Option<String>,
  pub snapshot_kind: TokenUsageSnapshotKind,
  pub raw_usage: TokenUsage,
  pub billable_input_tokens: u64,
  pub billable_output_tokens: u64,
  pub cache_read_tokens: u64,
  pub cache_write_tokens: u64,
  pub context_input_tokens: u64,
  pub estimated_cost_usd: f64,
  pub pricing: UsagePricingSnapshotPayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionUsageTurnsPage {
  pub session_id: String,
  pub total_turn_count: u64,
  pub has_more_before: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub oldest_turn_seq: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub newest_turn_seq: Option<u64>,
  pub summary: UsageSummaryBucket,
  #[serde(default)]
  pub rows: Vec<SessionUsageTurnEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MissionsSnapshot {
  pub revision: u64,
  pub missions: Vec<MissionSummary>,
}

/// Codex rate-limit window.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexRateLimitWindow {
  pub used_percent: f64,
  pub window_duration_mins: u32,
  pub resets_at_unix: f64,
}

/// Codex-specific reason the account is currently blocked by usage limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRateLimitReachedType {
  RateLimitReached,
  WorkspaceOwnerCreditsDepleted,
  WorkspaceMemberCreditsDepleted,
  WorkspaceOwnerUsageLimitReached,
  WorkspaceMemberUsageLimitReached,
}

/// Endpoint-scoped Codex usage snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CodexUsageSnapshot {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub primary: Option<CodexRateLimitWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary: Option<CodexRateLimitWindow>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub rate_limit_reached_type: Option<CodexRateLimitReachedType>,
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
// Mission Control
// ---------------------------------------------------------------------------

/// Orchestration state for a mission issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrchestrationState {
  Queued,
  Claimed,
  Provisioning,
  Running,
  RetryQueued,
  Completed,
  Failed,
  Blocked,
}

impl OrchestrationState {
  /// Returns the valid admin transitions from this state.
  pub fn allowed_transitions(&self) -> Vec<OrchestrationState> {
    match self {
      Self::Queued => vec![Self::Completed, Self::Blocked],
      Self::Claimed => vec![
        Self::Queued,
        Self::Provisioning,
        Self::Completed,
        Self::Blocked,
        Self::Failed,
      ],
      Self::Provisioning => {
        vec![
          Self::Queued,
          Self::Running,
          Self::Completed,
          Self::Blocked,
          Self::Failed,
        ]
      }
      Self::Running => vec![Self::Queued, Self::Completed, Self::Blocked, Self::Failed],
      Self::RetryQueued => vec![Self::Queued, Self::Completed, Self::Blocked],
      Self::Failed => vec![Self::Queued, Self::Completed],
      Self::Blocked => vec![Self::Queued, Self::Completed],
      Self::Completed => vec![Self::Queued],
    }
  }

  /// Check if transitioning to the target state is valid.
  pub fn can_transition_to(&self, target: &Self) -> bool {
    self.allowed_transitions().contains(target)
  }

  /// Convert to the DB string representation.
  pub fn as_db_str(&self) -> &'static str {
    match self {
      Self::Queued => "queued",
      Self::Claimed => "claimed",
      Self::Provisioning => "provisioning",
      Self::Running => "running",
      Self::RetryQueued => "retry_queued",
      Self::Completed => "completed",
      Self::Failed => "failed",
      Self::Blocked => "blocked",
    }
  }

  /// Parse from DB string representation.
  pub fn from_db_str(s: &str) -> Option<Self> {
    match s {
      "queued" => Some(Self::Queued),
      "claimed" => Some(Self::Claimed),
      "provisioning" => Some(Self::Provisioning),
      "running" => Some(Self::Running),
      "retry_queued" => Some(Self::RetryQueued),
      "completed" => Some(Self::Completed),
      "failed" => Some(Self::Failed),
      "blocked" => Some(Self::Blocked),
      _ => None,
    }
  }
}

/// Summary of a configured mission.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MissionSummary {
  pub id: String,
  pub name: String,
  pub repo_root: String,
  pub enabled: bool,
  pub paused: bool,
  pub tracker_kind: String,
  pub provider_strategy: String,
  pub primary_provider: Provider,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary_provider: Option<Provider>,
  pub active_count: u32,
  pub queued_count: u32,
  pub completed_count: u32,
  pub failed_count: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub parse_error: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub orchestrator_status: Option<String>,
  /// ISO-8601 timestamp of the last orchestrator poll for this mission.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_polled_at: Option<String>,
  /// Configured poll interval in seconds.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub poll_interval: Option<u64>,
  /// Custom mission file path (e.g. `MISSION-foo.md`). `None` means default `MISSION.md`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub mission_file_path: Option<String>,
  /// Where the tracker credential comes from: "mission", "env", "global", or `None`.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub tracker_key_source: Option<String>,
}

/// Server-authored prompt metadata for mission worktree cleanup UX.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MissionCleanupPrompt {
  /// Number of mission-linked worktrees that are still present on disk and
  /// eligible for review/cleanup in the client.
  pub lingering_worktree_count: u32,
}

/// A single issue tracked by a mission.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MissionIssueItem {
  pub issue_id: String,
  pub identifier: String,
  pub title: String,
  pub tracker_state: String,
  pub orchestration_state: OrchestrationState,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_id: Option<String>,
  pub provider: Provider,
  pub attempt: u32,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub error: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub url: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_activity: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub completed_at: Option<String>,
  /// Valid admin transitions from the current state (server-driven UX).
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub allowed_transitions: Vec<OrchestrationState>,
  /// Live work status from the linked session (only present for running issues).
  #[serde(skip_serializing_if = "Option::is_none")]
  pub work_status: Option<WorkStatus>,
  /// Most recent agent message or activity summary.
  #[serde(skip_serializing_if = "Option::is_none")]
  pub last_message: Option<String>,
  /// URL of the linked pull request (set by `mission_link_pr`).
  #[serde(skip_serializing_if = "Option::is_none")]
  pub pr_url: Option<String>,
}

// ---------------------------------------------------------------------------
// Permission Rules (returned by GET /api/sessions/{id}/permissions/rules)
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_policy_details: Option<CodexApprovalPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sandbox_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sandbox_policy_details: Option<CodexSandboxPolicy>,
  },
}

#[cfg(test)]
#[path = "types_tests.rs"]
mod tests;
