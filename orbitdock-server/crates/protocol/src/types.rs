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

impl std::str::FromStr for Provider {
    type Err = std::convert::Infallible;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "codex" => Provider::Codex,
            _ => Provider::Claude,
        })
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

/// Root/list-facing session display status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionListStatus {
    Working,
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
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub allow_bypass_permissions: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collaboration_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub multi_agent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub personality: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_mode: Option<CodexConfigMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_source: Option<CodexConfigSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_overrides: Option<CodexSessionOverrides>,
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
    /// Monotonic counter for root-summary freshness.
    #[serde(default)]
    pub summary_revision: u64,
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
    #[serde(default)]
    pub has_turn_diff: bool,
    pub display_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_line: Option<String>,
    pub list_status: SessionListStatus,
    /// Number of active sub-agent workers.
    #[serde(default)]
    pub active_worker_count: u32,
    /// Tool family of the pending tool (typed status icon).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_tool_family: Option<crate::domain_events::ToolFamily>,
    /// Session this was forked from (fork lineage).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forked_from_session_id: Option<String>,
    /// Mission ID if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mission_id: Option<String>,
    /// Issue identifier (e.g. "PROJ-123") if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_identifier: Option<String>,
}

impl SessionSummary {
    pub fn display_title_from_parts(
        custom_name: Option<&str>,
        summary: Option<&str>,
        first_prompt: Option<&str>,
        project_name: Option<&str>,
        project_path: &str,
    ) -> String {
        let project_name_clean = project_name
            .map(clean_display_text)
            .filter(|value| !value.is_empty());
        let project_leaf_clean = project_path
            .rsplit('/')
            .next()
            .map(clean_display_text)
            .filter(|value| !value.is_empty());
        let project_fallback = project_name_clean
            .clone()
            .or_else(|| project_leaf_clean.clone())
            .unwrap_or_else(|| "Unknown".to_string());

        if let Some(custom_name) = custom_name
            .map(clean_display_text)
            .filter(|value| !value.is_empty())
        {
            return custom_name;
        }

        let summary_clean = summary
            .map(clean_display_text)
            .filter(|value| !value.is_empty());
        let first_prompt_clean = first_prompt
            .map(clean_display_text)
            .filter(|value| !value.is_empty());

        // Prefer the conversation summary (title) over the first prompt.
        if let Some(summary) = summary_clean.as_ref() {
            if !matches_project_label(
                summary,
                project_name_clean.as_deref(),
                project_leaf_clean.as_deref(),
            ) {
                return summary.clone();
            }
        }

        if let Some(first_prompt) = first_prompt_clean.as_ref() {
            if !matches_project_label(
                first_prompt,
                project_name_clean.as_deref(),
                project_leaf_clean.as_deref(),
            ) {
                return first_prompt.clone();
            }
        }

        summary_clean
            .or(first_prompt_clean)
            .unwrap_or(project_fallback)
    }

    pub fn context_line_from_parts(
        summary: Option<&str>,
        first_prompt: Option<&str>,
        last_message: Option<&str>,
    ) -> Option<String> {
        let last_message_clean = last_message
            .map(clean_display_text)
            .filter(|value| !value.is_empty());
        if last_message_clean.is_some() {
            return last_message_clean;
        }

        // Prefer first_prompt as fallback (summary is now shown in the title).
        let first_prompt_clean = first_prompt
            .map(clean_display_text)
            .filter(|value| !value.is_empty());
        let summary_clean = summary
            .map(clean_display_text)
            .filter(|value| !value.is_empty());

        if let Some(prompt) = first_prompt_clean.as_ref() {
            if summary_clean.as_ref() != Some(prompt) {
                return Some(prompt.clone());
            }
        }

        first_prompt_clean.or(summary_clean)
    }

    pub fn list_status_from_parts(
        status: SessionStatus,
        work_status: WorkStatus,
    ) -> SessionListStatus {
        if status != SessionStatus::Active {
            return SessionListStatus::Ended;
        }

        match work_status {
            WorkStatus::Working => SessionListStatus::Working,
            WorkStatus::Permission => SessionListStatus::Permission,
            WorkStatus::Question => SessionListStatus::Question,
            WorkStatus::Waiting | WorkStatus::Reply | WorkStatus::Ended => SessionListStatus::Reply,
        }
    }
}

fn clean_display_text(value: &str) -> String {
    let mut stripped = String::with_capacity(value.len());
    let mut inside_tag = false;

    for ch in value.chars() {
        match ch {
            '<' => inside_tag = true,
            '>' => inside_tag = false,
            _ if !inside_tag => stripped.push(ch),
            _ => {}
        }
    }

    stripped.trim().to_string()
}

fn matches_project_label(
    candidate: &str,
    project_name: Option<&str>,
    project_leaf: Option<&str>,
) -> bool {
    let normalized_candidate = normalize_display_comparison(candidate);
    project_name
        .into_iter()
        .chain(project_leaf)
        .map(normalize_display_comparison)
        .any(|project_label| !project_label.is_empty() && project_label == normalized_candidate)
}

fn normalize_display_comparison(value: &str) -> String {
    value.trim().to_lowercase()
}

impl SessionSummary {
    pub fn to_list_item(&self) -> SessionListItem {
        SessionListItem {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            project_name: self.project_name.clone(),
            git_branch: self.git_branch.clone(),
            model: self.model.clone(),
            status: self.status,
            work_status: self.work_status,
            codex_integration_mode: self.codex_integration_mode,
            claude_integration_mode: self.claude_integration_mode,
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
            unread_count: self.unread_count,
            has_turn_diff: self.has_turn_diff,
            pending_tool_name: self.pending_tool_name.clone(),
            repository_root: self.repository_root.clone(),
            is_worktree: self.is_worktree,
            worktree_id: self.worktree_id.clone(),
            total_tokens: self.token_usage.input_tokens + self.token_usage.output_tokens,
            total_cost_usd: 0.0,
            display_title: self.display_title.clone(),
            context_line: self.context_line.clone(),
            list_status: self.list_status,
            effort: self.effort.clone(),
            summary_revision: self.summary_revision,
            active_worker_count: self.active_worker_count,
            pending_tool_family: self.pending_tool_family,
            forked_from_session_id: self.forked_from_session_id.clone(),
            mission_id: self.mission_id.clone(),
            issue_identifier: self.issue_identifier.clone(),
        }
    }
}

impl From<SessionSummary> for SessionListItem {
    fn from(summary: SessionSummary) -> Self {
        SessionListItem {
            id: summary.id,
            provider: summary.provider,
            project_path: summary.project_path,
            project_name: summary.project_name,
            git_branch: summary.git_branch,
            model: summary.model,
            status: summary.status,
            work_status: summary.work_status,
            codex_integration_mode: summary.codex_integration_mode,
            claude_integration_mode: summary.claude_integration_mode,
            started_at: summary.started_at,
            last_activity_at: summary.last_activity_at,
            unread_count: summary.unread_count,
            has_turn_diff: summary.has_turn_diff,
            pending_tool_name: summary.pending_tool_name,
            repository_root: summary.repository_root,
            is_worktree: summary.is_worktree,
            worktree_id: summary.worktree_id,
            total_tokens: summary.token_usage.input_tokens + summary.token_usage.output_tokens,
            total_cost_usd: 0.0,
            display_title: summary.display_title,
            context_line: summary.context_line,
            list_status: summary.list_status,
            effort: summary.effort,
            summary_revision: summary.summary_revision,
            active_worker_count: summary.active_worker_count,
            pending_tool_family: summary.pending_tool_family,
            forked_from_session_id: summary.forked_from_session_id,
            mission_id: summary.mission_id,
            issue_identifier: summary.issue_identifier,
        }
    }
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SubagentStatus {
    Pending,
    #[default]
    Running,
    Completed,
    Failed,
    Cancelled,
    Shutdown,
    NotFound,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubagentInfo {
    pub id: String,
    pub agent_type: String,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<Provider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub status: SubagentStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_subagent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<String>,
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
    pub pending_approval: Option<ApprovalRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub permission_mode: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub allow_bypass_permissions: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collaboration_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub multi_agent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub personality: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_mode: Option<CodexConfigMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_source: Option<CodexConfigSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_config_overrides: Option<CodexSessionOverrides>,
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

    /// Mission ID if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mission_id: Option<String>,
    /// Issue identifier (e.g. "PROJ-123") if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_identifier: Option<String>,

    // -- Conversation row payload (server-populated) --
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<crate::conversation_contracts::ConversationRowEntry>,
    #[serde(default)]
    pub total_row_count: u64,
    #[serde(default)]
    pub has_more_before: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldest_sequence: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub newest_sequence: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionListItem {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_integration_mode: Option<ClaudeIntegrationMode>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    #[serde(default)]
    pub unread_count: u64,
    #[serde(default)]
    pub has_turn_diff: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<String>,
    #[serde(default)]
    pub is_worktree: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<String>,
    #[serde(default)]
    pub total_tokens: u64,
    #[serde(default)]
    pub total_cost_usd: f64,
    pub display_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_line: Option<String>,
    pub list_status: SessionListStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    /// Monotonic counter for root-summary freshness.
    #[serde(default)]
    pub summary_revision: u64,
    /// Number of active sub-agent workers.
    #[serde(default)]
    pub active_worker_count: u32,
    /// Tool family of the pending tool (typed status icon).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_tool_family: Option<crate::domain_events::ToolFamily>,
    /// Session this was forked from (fork lineage).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forked_from_session_id: Option<String>,
    /// Mission ID if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mission_id: Option<String>,
    /// Issue identifier (e.g. "PROJ-123") if this session is orchestrated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_identifier: Option<String>,
}

impl SessionListItem {
    pub fn from_summary(summary: &SessionSummary) -> Self {
        Self {
            id: summary.id.clone(),
            provider: summary.provider,
            project_path: summary.project_path.clone(),
            project_name: summary.project_name.clone(),
            git_branch: summary.git_branch.clone(),
            model: summary.model.clone(),
            status: summary.status,
            work_status: summary.work_status,
            codex_integration_mode: summary.codex_integration_mode,
            claude_integration_mode: summary.claude_integration_mode,
            started_at: summary.started_at.clone(),
            last_activity_at: summary.last_activity_at.clone(),
            unread_count: summary.unread_count,
            has_turn_diff: summary.has_turn_diff,
            pending_tool_name: summary.pending_tool_name.clone(),
            repository_root: summary.repository_root.clone(),
            is_worktree: summary.is_worktree,
            worktree_id: summary.worktree_id.clone(),
            total_tokens: summary.token_usage.input_tokens + summary.token_usage.output_tokens,
            total_cost_usd: 0.0,
            display_title: summary.display_title.clone(),
            context_line: summary.context_line.clone(),
            list_status: summary.list_status,
            effort: summary.effort.clone(),
            summary_revision: summary.summary_revision,
            active_worker_count: summary.active_worker_count,
            pending_tool_family: summary.pending_tool_family,
            forked_from_session_id: summary.forked_from_session_id.clone(),
            mission_id: summary.mission_id.clone(),
            issue_identifier: summary.issue_identifier.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardDiffPreview {
    #[serde(default)]
    pub file_count: u32,
    #[serde(default)]
    pub additions: u32,
    #[serde(default)]
    pub deletions: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub file_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardConversationItem {
    pub session_id: String,
    pub provider: Provider,
    pub project_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository_root: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    #[serde(default)]
    pub is_worktree: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_integration_mode: Option<ClaudeIntegrationMode>,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub list_status: SessionListStatus,
    pub display_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_line: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_message: Option<String>,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    #[serde(default)]
    pub unread_count: u64,
    #[serde(default)]
    pub has_turn_diff: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_preview: Option<DashboardDiffPreview>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_tool_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_tool_input: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_question: Option<String>,
    #[serde(default)]
    pub tool_count: u64,
    #[serde(default)]
    pub active_worker_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue_identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
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
    pub collaboration_mode: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub multi_agent: Option<Option<bool>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub personality: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_tier: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub developer_instructions: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_config_mode: Option<Option<CodexConfigMode>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_config_profile: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_model_provider: Option<Option<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_config_source: Option<Option<CodexConfigSource>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codex_config_overrides: Option<Option<CodexSessionOverrides>>,
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
    pub subagents: Option<Vec<SubagentInfo>>,
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

/// Explicit OrbitDock-managed overrides layered on top of Codex config.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct CodexSessionOverrides {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval_policy: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sandbox_mode: Option<String>,
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
// Mission Control
// ---------------------------------------------------------------------------

/// Orchestration state for a mission issue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrchestrationState {
    Queued,
    Claimed,
    Running,
    RetryQueued,
    Completed,
    Failed,
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
    /// Primary provider (backward compat — same as primary_provider).
    pub provider: Provider,
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

#[cfg(test)]
mod tests {
    use super::{
        Provider, SessionListItem, SessionListStatus, SessionStatus, SessionSummary, TokenUsage,
        TokenUsageSnapshotKind, WorkStatus,
    };

    #[test]
    fn display_title_prefers_summary_over_prompt() {
        let title = SessionSummary::display_title_from_parts(
            None,
            Some("Dashboard polish and cleanup"),
            Some("Add a calmer dashboard shell"),
            Some("OrbitDock"),
            "/Users/robert/OrbitDock",
        );

        assert_eq!(title, "Dashboard polish and cleanup");
    }

    #[test]
    fn display_title_falls_back_to_prompt_when_summary_matches_project() {
        let title = SessionSummary::display_title_from_parts(
            None,
            Some("OrbitDock"),
            Some("Add a calmer dashboard shell"),
            Some("OrbitDock"),
            "/Users/robert/OrbitDock",
        );

        assert_eq!(title, "Add a calmer dashboard shell");
    }

    #[test]
    fn context_line_prefers_last_message_then_distinct_prompt() {
        // No last_message → falls back to first_prompt (distinct from summary)
        let context = SessionSummary::context_line_from_parts(
            Some("Project-level cleanup is in flight"),
            Some("Tighten the root shell"),
            None,
        );
        assert_eq!(context.as_deref(), Some("Tighten the root shell"));

        let duplicate = SessionSummary::context_line_from_parts(
            Some("Tighten the root shell"),
            Some("Tighten the root shell"),
            None,
        );
        assert_eq!(duplicate.as_deref(), Some("Tighten the root shell"));

        let last_message = SessionSummary::context_line_from_parts(
            Some("Project-level cleanup is in flight"),
            Some("Tighten the root shell"),
            Some("The worker finished and returned its result."),
        );
        assert_eq!(
            last_message.as_deref(),
            Some("The worker finished and returned its result.")
        );
    }

    #[test]
    fn session_list_item_from_summary_preserves_summary_revision() {
        let summary = SessionSummary {
            id: "sess-1".to_string(),
            provider: Provider::Codex,
            project_path: "/tmp/orbitdock".to_string(),
            transcript_path: None,
            project_name: Some("OrbitDock".to_string()),
            model: Some("gpt-5.4".to_string()),
            custom_name: None,
            summary: None,
            first_prompt: None,
            last_message: None,
            status: SessionStatus::Active,
            work_status: WorkStatus::Working,
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::default(),
            has_pending_approval: false,
            codex_integration_mode: None,
            claude_integration_mode: None,
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            collaboration_mode: None,
            multi_agent: None,
            personality: None,
            service_tier: None,
            developer_instructions: None,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
            pending_tool_name: None,
            pending_tool_input: None,
            pending_question: None,
            pending_approval_id: None,
            started_at: None,
            last_activity_at: None,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            effort: None,
            approval_version: Some(4),
            summary_revision: 27,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            unread_count: 0,
            has_turn_diff: false,
            display_title: "OrbitDock".to_string(),
            context_line: None,
            list_status: SessionListStatus::Working,
            active_worker_count: 3,
            pending_tool_family: Some(crate::domain_events::ToolFamily::Shell),
            forked_from_session_id: Some("sess-0".to_string()),
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
        };

        let item = SessionListItem::from_summary(&summary);

        assert_eq!(item.summary_revision, 27);
        assert_eq!(item.active_worker_count, 3);
        assert_eq!(
            item.pending_tool_family,
            Some(crate::domain_events::ToolFamily::Shell)
        );
        assert_eq!(item.forked_from_session_id.as_deref(), Some("sess-0"));
    }

    // classify_tool_family and ensure_tool_family tests removed —
}
