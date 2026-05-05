use serde::{Deserialize, Serialize};

use crate::domain_events::AgentType;

use super::{
  ApprovalRequest, ClaudeIntegrationMode, CodexApprovalPolicy, CodexConfigMode, CodexConfigSource,
  CodexIntegrationMode, CodexSandboxPolicy, CodexSessionOverrides, Provider, ReviewComment,
  SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

/// Normalized control ownership for a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionControlMode {
  Direct,
  Passive,
}

/// Normalized runtime lifecycle for a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionLifecycleState {
  Open,
  Resumable,
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
  #[serde(default = "SessionSummary::default_control_mode")]
  pub control_mode: SessionControlMode,
  #[serde(default = "SessionSummary::default_lifecycle_state")]
  pub lifecycle_state: SessionLifecycleState,
  #[serde(default)]
  pub accepts_user_input: bool,
  #[serde(default)]
  pub steerable: bool,
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
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(default)]
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
  pub last_progress_at: Option<String>,
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
  pub(crate) fn default_control_mode() -> SessionControlMode {
    SessionControlMode::Passive
  }

  pub(crate) fn default_lifecycle_state() -> SessionLifecycleState {
    SessionLifecycleState::Ended
  }

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
        if let Some(derived_title) = derive_prompt_display_title(first_prompt) {
          return derived_title;
        }
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

fn derive_prompt_display_title(value: &str) -> Option<String> {
  let normalized = collapse_whitespace(value);
  if normalized.is_empty() {
    return None;
  }

  let mut candidate = strip_skill_invocation_prefix(&normalized);
  candidate = strip_leading_prompt_filler(&candidate);
  candidate = first_prompt_clause(&candidate).trim().to_string();
  candidate = trim_weak_trailing_words(&candidate);

  if candidate.is_empty() {
    return None;
  }

  let titled = title_case_prompt_phrase(&candidate);
  let capped = truncate_display_title(&titled, 48);
  if capped.is_empty() {
    None
  } else {
    Some(capped)
  }
}

fn collapse_whitespace(value: &str) -> String {
  value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_skill_invocation_prefix(value: &str) -> String {
  let mut candidate = value.trim().to_string();

  loop {
    let trimmed = candidate.trim_start();
    let Some(rest) = trimmed.strip_prefix('/') else {
      break;
    };
    let command_len = rest.find(char::is_whitespace).unwrap_or(rest.len());
    if command_len == rest.len() {
      return String::new();
    }
    candidate = rest[command_len..].trim_start().to_string();
  }

  let lower = candidate.to_ascii_lowercase();
  if lower.starts_with("using /") {
    if let Some(idx) = lower.find(" can you ") {
      return candidate[(idx + " can you ".len())..].trim().to_string();
    }
  }

  candidate
}

fn strip_leading_prompt_filler(value: &str) -> String {
  let prefixes = [
    "can you help me ",
    "could you help me ",
    "would you help me ",
    "can you ",
    "could you ",
    "would you ",
    "can we ",
    "help me ",
    "please ",
    "i need you to ",
    "i need to ",
    "i want to ",
    "let's ",
    "lets ",
  ];

  let mut candidate = value.trim().to_string();
  loop {
    let lower = candidate.to_ascii_lowercase();
    let mut stripped = false;
    for prefix in prefixes {
      if lower.starts_with(prefix) {
        candidate = candidate[prefix.len()..].trim_start().to_string();
        stripped = true;
        break;
      }
    }
    if !stripped {
      break;
    }
  }

  candidate
}

fn first_prompt_clause(value: &str) -> String {
  let mut cutoff = value.len();

  for marker in ["\n", "? ", "! ", ".", "?", "!"] {
    if let Some(idx) = value.find(marker) {
      let marker_is_period = marker == ".";
      let is_sentence_period = marker_is_period
        && value
          .get(idx + 1..)
          .and_then(|rest| rest.chars().next())
          .is_some_and(char::is_whitespace);

      if !marker_is_period || is_sentence_period {
        cutoff = cutoff.min(idx);
      }
    }
  }

  value[..cutoff].trim().to_string()
}

fn trim_weak_trailing_words(value: &str) -> String {
  let weak_words = ["this", "that", "it", "here", "there", "please", "thanks"];
  let mut words = value.split_whitespace().collect::<Vec<_>>();
  while let Some(last) = words.last() {
    let normalized = last
      .trim_matches(|ch: char| !ch.is_alphanumeric())
      .to_ascii_lowercase();
    if weak_words.contains(&normalized.as_str()) {
      words.pop();
    } else {
      break;
    }
  }
  words.join(" ")
}

fn title_case_prompt_phrase(value: &str) -> String {
  let minor_words = [
    "a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with",
  ];

  value
    .split_whitespace()
    .enumerate()
    .map(|(idx, word)| {
      if word.chars().any(|ch| "/._-".contains(ch)) || word.chars().any(|ch| ch.is_uppercase()) {
        return word.to_string();
      }

      let lower = word.to_ascii_lowercase();
      if idx > 0 && minor_words.contains(&lower.as_str()) {
        return lower;
      }

      capitalize_ascii_word(&lower)
    })
    .collect::<Vec<_>>()
    .join(" ")
}

fn capitalize_ascii_word(value: &str) -> String {
  let mut chars = value.chars();
  match chars.next() {
    Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
    None => String::new(),
  }
}

fn truncate_display_title(value: &str, max_chars: usize) -> String {
  let char_count = value.chars().count();
  if char_count <= max_chars {
    return value.to_string();
  }

  let mut truncated = value.chars().take(max_chars).collect::<String>();
  while truncated.ends_with(' ') {
    truncated.pop();
  }
  truncated.push('…');
  truncated
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
      control_mode: summary.control_mode,
      lifecycle_state: summary.lifecycle_state,
      codex_integration_mode: summary.codex_integration_mode,
      claude_integration_mode: summary.claude_integration_mode,
      started_at: summary.started_at,
      last_activity_at: summary.last_activity_at,
      last_progress_at: summary.last_progress_at,
      unread_count: summary.unread_count,
      has_turn_diff: summary.has_turn_diff,
      pending_tool_name: summary.pending_tool_name,
      repository_root: summary.repository_root,
      is_worktree: summary.is_worktree,
      worktree_id: summary.worktree_id,
      total_tokens: summary.token_usage.input_tokens + summary.token_usage.output_tokens,
      total_cost_usd: 0.0,
      input_tokens: summary.token_usage.input_tokens,
      output_tokens: summary.token_usage.output_tokens,
      cached_tokens: summary.token_usage.cached_tokens,
      display_title: summary.display_title,
      context_line: summary.context_line,
      list_status: summary.list_status,
      effort: summary.effort,
      summary_revision: summary.summary_revision,
      active_worker_count: summary.active_worker_count,
      pending_tool_family: summary.pending_tool_family,
      forked_from_session_id: summary.forked_from_session_id,
      steerable: summary.steerable,
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
  Interrupted,
  Completed,
  Failed,
  Cancelled,
  Shutdown,
  NotFound,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SubagentInfo {
  pub id: String,
  pub agent_type: AgentType,
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
  #[serde(default = "SessionSummary::default_control_mode")]
  pub control_mode: SessionControlMode,
  #[serde(default = "SessionSummary::default_lifecycle_state")]
  pub lifecycle_state: SessionLifecycleState,
  #[serde(default)]
  pub accepts_user_input: bool,
  #[serde(default)]
  pub steerable: bool,
  #[serde(default)]
  pub connector_attached: bool,
  #[serde(default)]
  pub can_interrupt: bool,
  pub pending_approval: Option<ApprovalRequest>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub permission_mode: Option<String>,
  #[serde(default)]
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
  /// Server-computed cumulative diff: all turn diffs + current_diff merged so
  /// each file appears exactly once. Clients should prefer this over
  /// manually concatenating turn diffs.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub cumulative_diff: Option<String>,
  pub current_plan: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub codex_integration_mode: Option<CodexIntegrationMode>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub claude_integration_mode: Option<ClaudeIntegrationMode>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub approval_policy: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub last_progress_at: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub forked_from_session_id: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub revision: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub current_turn_id: Option<String>,
  #[serde(default)]
  pub turn_count: u64,
  #[serde(default)]
  pub turn_diffs: Vec<TurnDiff>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub git_branch: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub git_sha: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub current_cwd: Option<String>,
  #[serde(default)]
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
  #[serde(default)]
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
  #[serde(default = "SessionSummary::default_control_mode")]
  pub control_mode: SessionControlMode,
  #[serde(default = "SessionSummary::default_lifecycle_state")]
  pub lifecycle_state: SessionLifecycleState,
  #[serde(default)]
  pub steerable: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub codex_integration_mode: Option<CodexIntegrationMode>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub claude_integration_mode: Option<ClaudeIntegrationMode>,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub last_progress_at: Option<String>,
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
  #[serde(default)]
  pub input_tokens: u64,
  #[serde(default)]
  pub output_tokens: u64,
  #[serde(default)]
  pub cached_tokens: u64,
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
      control_mode: summary.control_mode,
      lifecycle_state: summary.lifecycle_state,
      steerable: summary.steerable,
      codex_integration_mode: summary.codex_integration_mode,
      claude_integration_mode: summary.claude_integration_mode,
      started_at: summary.started_at.clone(),
      last_activity_at: summary.last_activity_at.clone(),
      last_progress_at: summary.last_progress_at.clone(),
      unread_count: summary.unread_count,
      has_turn_diff: summary.has_turn_diff,
      pending_tool_name: summary.pending_tool_name.clone(),
      repository_root: summary.repository_root.clone(),
      is_worktree: summary.is_worktree,
      worktree_id: summary.worktree_id.clone(),
      total_tokens: summary.token_usage.input_tokens + summary.token_usage.output_tokens,
      total_cost_usd: 0.0,
      input_tokens: summary.token_usage.input_tokens,
      output_tokens: summary.token_usage.output_tokens,
      cached_tokens: summary.token_usage.cached_tokens,
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
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub grouping_path: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub grouping_name: Option<String>,
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
  #[serde(default = "SessionSummary::default_control_mode")]
  pub control_mode: SessionControlMode,
  #[serde(default = "SessionSummary::default_lifecycle_state")]
  pub lifecycle_state: SessionLifecycleState,
  pub list_status: SessionListStatus,
  pub display_title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub context_line: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub last_message: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview_text: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub activity_summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub alert_context: Option<String>,
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
  pub control_mode: Option<SessionControlMode>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub lifecycle_state: Option<SessionLifecycleState>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub accepts_user_input: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub steerable: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub pending_approval: Option<Option<ApprovalRequest>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub token_usage: Option<TokenUsage>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub token_usage_snapshot_kind: Option<TokenUsageSnapshotKind>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub current_diff: Option<Option<String>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cumulative_diff: Option<Option<String>>,
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
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<Option<CodexApprovalPolicy>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub sandbox_mode: Option<Option<String>>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_policy_details: Option<Option<CodexSandboxPolicy>>,
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
  pub last_progress_at: Option<String>,
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
  #[serde(skip_serializing_if = "Option::is_none")]
  pub approval_version: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub repository_root: Option<Option<String>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub is_worktree: Option<bool>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub unread_count: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionSurface {
  Detail,
  Composer,
  Conversation,
  Review,
  Capabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionsSummaryCounts {
  pub total: u64,
  pub active: u32,
  pub working: u32,
  pub attention: u32,
  pub ready: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionsSummarySnapshot {
  pub revision: u64,
  pub counts: SessionsSummaryCounts,
  pub active_sessions: Vec<SessionListItem>,
  pub recent_sessions: Vec<SessionListItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibrarySnapshot {
  pub revision: u64,
  pub sessions: Vec<SessionListItem>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub next_offset: Option<u64>,
  pub total_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionDetailSnapshot {
  pub revision: u64,
  pub session: SessionState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationSnapshotPage {
  pub replay_cursor: u64,
  pub session_id: String,
  pub rows: Vec<crate::conversation_contracts::RowEntrySummary>,
  pub total_row_count: u64,
  pub has_more_before: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub forked_from_session_id: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub oldest_sequence: Option<u64>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub newest_sequence: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionReviewSnapshot {
  pub session_id: String,
  pub revision: u64,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub current_diff: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cumulative_diff: Option<String>,
  pub turn_diffs: Vec<TurnDiff>,
  pub comments: Vec<ReviewComment>,
}
