use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexApprovalPolicy, CodexConfigMode, CodexConfigSource,
  CodexIntegrationMode, CodexSessionOverrides, Provider, SessionState, SessionStatus,
  SessionSummary, TokenUsage, TurnDiff, WorkStatus,
};
use tracing::warn;

use crate::domain::sessions::session::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionHandle, SessionIdentity,
  SessionRestoreData, SessionTimestamps,
};
use crate::infrastructure::persistence::{
  load_messages_from_transcript_path, load_session_by_id, RestoredSession,
};

/// Parse a stored provider string into a [`Provider`], falling back to
/// `Provider::Claude` and logging a warning when the value doesn't match a
/// known provider name.
fn parse_provider(raw: &str) -> Provider {
  let normalised = raw.to_ascii_lowercase();
  match normalised.as_str() {
    "claude" | "codex" => normalised.parse::<Provider>().unwrap_or(Provider::Claude),
    _ => {
      warn!(
          stored_value = %raw,
          "unrecognised provider in restored session, falling back to Claude"
      );
      Provider::Claude
    }
  }
}

pub(crate) struct PreparedResumeSession {
  pub provider: Provider,
  pub project_path: String,
  pub transcript_path: Option<String>,
  pub model: Option<String>,
  pub codex_thread_id: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub codex_config_mode: Option<CodexConfigMode>,
  pub codex_config_profile: Option<String>,
  pub codex_model_provider: Option<String>,
  pub codex_config_source: Option<CodexConfigSource>,
  pub codex_config_overrides: Option<CodexSessionOverrides>,
  pub claude_sdk_session_id: Option<String>,
  pub row_count: usize,
  pub transcript_loaded: bool,
  pub summary: SessionSummary,
  pub handle: SessionHandle,
  pub allow_bypass_permissions: bool,
}

pub(crate) async fn hydrate_restored_rows_if_missing(
  restored: &mut RestoredSession,
  session_id: &str,
) {
  if !restored.rows.is_empty() {
    return;
  }

  if let Some(ref transcript_path) = restored.transcript_path {
    if let Ok(rows) = load_messages_from_transcript_path(transcript_path, session_id).await {
      if !rows.is_empty() {
        restored.rows = rows;
      }
    }
  }
}

pub(crate) fn parse_session_status(end_reason: Option<&String>, value: &str) -> SessionStatus {
  if end_reason.is_some() {
    return SessionStatus::Ended;
  }

  if value.eq_ignore_ascii_case("ended") {
    SessionStatus::Ended
  } else {
    SessionStatus::Active
  }
}

pub(crate) fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
  if status == SessionStatus::Ended {
    return WorkStatus::Ended;
  }

  match value.to_ascii_lowercase().as_str() {
    "working" => WorkStatus::Working,
    "waiting" => WorkStatus::Waiting,
    "permission" => WorkStatus::Permission,
    "question" => WorkStatus::Question,
    "reply" => WorkStatus::Reply,
    "ended" => WorkStatus::Ended,
    _ => WorkStatus::Waiting,
  }
}

pub(crate) fn restored_session_to_state(restored: RestoredSession) -> SessionState {
  let provider = parse_provider(&restored.provider);
  let status = parse_session_status(restored.end_reason.as_ref(), &restored.status);
  let work_status = parse_work_status(status, &restored.work_status);
  let control_mode = restored.control_mode;
  let total_row_count = restored.rows.len() as u64;
  let oldest_sequence = restored.rows.first().map(|entry| entry.sequence);
  let newest_sequence = restored.rows.last().map(|entry| entry.sequence);
  let approval_policy_details = restored
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.approval_policy_details.clone())
    .or_else(|| {
      restored
        .approval_policy
        .as_deref()
        .and_then(CodexApprovalPolicy::from_storage_text)
    });

  let turn_diffs: Vec<TurnDiff> = restored
    .turn_diffs
    .into_iter()
    .map(
      |(
        turn_id,
        diff,
        input_tokens,
        output_tokens,
        cached_tokens,
        context_window,
        snapshot_kind,
      )| TurnDiff {
        turn_id,
        diff,
        token_usage: Some(TokenUsage {
          input_tokens: input_tokens as u64,
          output_tokens: output_tokens as u64,
          cached_tokens: cached_tokens as u64,
          context_window: context_window as u64,
        }),
        snapshot_kind: Some(snapshot_kind),
      },
    )
    .collect();
  let turn_count = turn_diffs.len() as u64;

  SessionState {
    id: restored.id,
    provider,
    project_path: restored.project_path,
    transcript_path: restored.transcript_path,
    project_name: restored.project_name,
    model: restored.model,
    custom_name: restored.custom_name,
    summary: restored.summary,
    first_prompt: restored.first_prompt,
    last_message: restored.last_message,
    status,
    work_status,
    control_mode,
    lifecycle_state: restored.lifecycle_state,
    accepts_user_input: restored.lifecycle_state == orbitdock_protocol::SessionLifecycleState::Open
      && control_mode == orbitdock_protocol::SessionControlMode::Direct
      && status == SessionStatus::Active,
    steerable: work_status == WorkStatus::Working,
    rows: restored.rows,
    total_row_count,
    has_more_before: false,
    oldest_sequence,
    newest_sequence,
    pending_approval: None,
    permission_mode: restored.permission_mode,
    collaboration_mode: restored.collaboration_mode,
    multi_agent: restored.multi_agent,
    personality: restored.personality,
    service_tier: restored.service_tier,
    developer_instructions: restored.developer_instructions,
    codex_config_mode: restored.codex_config_mode,
    codex_config_profile: restored.codex_config_profile,
    codex_model_provider: restored.codex_model_provider,
    codex_config_source: restored.codex_config_source,
    codex_config_overrides: restored.codex_config_overrides,
    pending_tool_name: restored.pending_tool_name,
    pending_tool_input: restored.pending_tool_input,
    pending_question: restored.pending_question,
    pending_approval_id: restored.pending_approval_id,
    token_usage: TokenUsage {
      input_tokens: restored.input_tokens as u64,
      output_tokens: restored.output_tokens as u64,
      cached_tokens: restored.cached_tokens as u64,
      context_window: restored.context_window as u64,
    },
    token_usage_snapshot_kind: restored.token_usage_snapshot_kind,
    current_diff: restored.current_diff,
    cumulative_diff: None,
    current_plan: restored.current_plan,
    codex_integration_mode: parse_codex_integration_mode(restored.codex_integration_mode),
    claude_integration_mode: parse_claude_integration_mode(restored.claude_integration_mode),
    approval_policy_details,
    approval_policy: restored.approval_policy,
    sandbox_mode: restored.sandbox_mode,
    started_at: restored.started_at,
    last_activity_at: restored.last_activity_at,
    last_progress_at: restored.last_progress_at,
    forked_from_session_id: restored.forked_from_session_id,
    revision: Some(0),
    current_turn_id: None,
    turn_count,
    turn_diffs,
    git_branch: restored.git_branch,
    git_sha: restored.git_sha,
    current_cwd: restored.current_cwd,
    subagents: Vec::new(),
    effort: restored.effort,
    terminal_session_id: restored.terminal_session_id,
    terminal_app: restored.terminal_app,
    approval_version: Some(restored.approval_version),
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    unread_count: restored.unread_count,
    mission_id: restored.mission_id,
    issue_identifier: restored.issue_identifier,
    allow_bypass_permissions: restored.allow_bypass_permissions,
  }
}

pub(crate) fn restored_session_to_handle(
  restored: RestoredSession,
  status: SessionStatus,
  work_status: WorkStatus,
) -> SessionHandle {
  let provider = parse_provider(&restored.provider);

  let mission_id = restored.mission_id.clone();
  let issue_identifier = restored.issue_identifier.clone();
  let allow_bypass = restored.allow_bypass_permissions;
  let approval_policy_details = restored
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.approval_policy_details.clone())
    .or_else(|| {
      restored
        .approval_policy
        .as_deref()
        .and_then(CodexApprovalPolicy::from_storage_text)
    });

  let mut handle = SessionHandle::restore(SessionRestoreData {
    identity: SessionIdentity {
      id: restored.id,
      provider,
      project_path: restored.project_path,
      transcript_path: restored.transcript_path,
      project_name: restored.project_name,
    },
    config: SessionConfig {
      model: restored.model,
      approval_policy: restored.approval_policy,
      approval_policy_details,
      sandbox_mode: restored.sandbox_mode,
      collaboration_mode: restored.collaboration_mode,
      multi_agent: restored.multi_agent,
      personality: restored.personality,
      service_tier: restored.service_tier,
      developer_instructions: restored.developer_instructions,
      codex_config_mode: restored.codex_config_mode,
      codex_config_profile: restored.codex_config_profile,
      codex_model_provider: restored.codex_model_provider,
      codex_config_source: restored.codex_config_source,
      codex_config_overrides: restored.codex_config_overrides,
      effort: restored.effort,
    },
    display: SessionDisplay {
      custom_name: restored.custom_name,
      summary: restored.summary,
      first_prompt: restored.first_prompt,
      last_message: restored.last_message,
    },
    environment: SessionEnvironment {
      git_branch: restored.git_branch,
      git_sha: restored.git_sha,
      current_cwd: restored.current_cwd,
      ..Default::default()
    },
    timestamps: SessionTimestamps {
      started_at: restored.started_at,
      last_activity_at: restored.last_activity_at,
      last_progress_at: restored.last_progress_at,
    },
    status,
    work_status,
    control_mode: restored.control_mode,
    lifecycle_state: restored.lifecycle_state,
    permission_mode: restored.permission_mode,
    token_usage: TokenUsage {
      input_tokens: restored.input_tokens.max(0) as u64,
      output_tokens: restored.output_tokens.max(0) as u64,
      cached_tokens: restored.cached_tokens.max(0) as u64,
      context_window: restored.context_window.max(0) as u64,
    },
    token_usage_snapshot_kind: restored.token_usage_snapshot_kind,
    rows: restored.rows,
    current_diff: restored.current_diff,
    current_plan: restored.current_plan,
    turn_diffs: restored
      .turn_diffs
      .into_iter()
      .map(
        |(
          turn_id,
          diff,
          input_tokens,
          output_tokens,
          cached_tokens,
          context_window,
          snapshot_kind,
        )| {
          let has_tokens = input_tokens > 0 || output_tokens > 0 || context_window > 0;
          TurnDiff {
            turn_id,
            diff,
            token_usage: if has_tokens {
              Some(TokenUsage {
                input_tokens: input_tokens as u64,
                output_tokens: output_tokens as u64,
                cached_tokens: cached_tokens as u64,
                context_window: context_window as u64,
              })
            } else {
              None
            },
            snapshot_kind: Some(snapshot_kind),
          }
        },
      )
      .collect(),
    pending_tool_name: restored.pending_tool_name,
    pending_tool_input: restored.pending_tool_input,
    pending_question: restored.pending_question,
    pending_approval_id: restored.pending_approval_id,
    terminal_session_id: restored.terminal_session_id,
    terminal_app: restored.terminal_app,
    approval_version: restored.approval_version,
    unread_count: restored.unread_count,
  });
  handle.set_control_mode(restored.control_mode);
  handle.set_mission_context(mission_id, issue_identifier);
  if allow_bypass {
    handle.set_allow_bypass_permissions(true);
  }
  handle
}

pub(crate) fn prepare_restored_session_for_direct_resume(
  restored: RestoredSession,
  transcript_loaded: bool,
) -> PreparedResumeSession {
  let provider = parse_provider(&restored.provider);
  let project_path = restored.project_path.clone();
  let transcript_path = restored.transcript_path.clone();
  let model = restored.model.clone();
  let codex_thread_id = restored.codex_thread_id.clone();
  let approval_policy = restored.approval_policy.clone();
  let sandbox_mode = restored.sandbox_mode.clone();
  let collaboration_mode = restored.collaboration_mode.clone();
  let multi_agent = restored.multi_agent;
  let personality = restored.personality.clone();
  let service_tier = restored.service_tier.clone();
  let developer_instructions = restored.developer_instructions.clone();
  let codex_config_mode = restored.codex_config_mode;
  let codex_config_profile = restored.codex_config_profile.clone();
  let codex_model_provider = restored.codex_model_provider.clone();
  let codex_config_source = restored.codex_config_source;
  let codex_config_overrides = restored.codex_config_overrides.clone();
  let claude_sdk_session_id = restored.claude_sdk_session_id.clone();
  let allow_bypass_permissions = restored.allow_bypass_permissions;
  let row_count = restored.rows.len();

  let mut handle = restored_session_to_handle(restored, SessionStatus::Active, WorkStatus::Waiting);
  match provider {
    Provider::Claude => handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct)),
    Provider::Codex => handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct)),
  }
  let summary = handle.summary();

  PreparedResumeSession {
    provider,
    project_path,
    transcript_path,
    model,
    codex_thread_id,
    approval_policy,
    sandbox_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides,
    claude_sdk_session_id,
    row_count,
    transcript_loaded,
    summary,
    handle,
    allow_bypass_permissions,
  }
}

pub(crate) async fn load_prepared_resume_session(
  session_id: &str,
) -> Result<Option<PreparedResumeSession>, anyhow::Error> {
  let Some(mut restored) = load_session_by_id(session_id).await? else {
    return Ok(None);
  };

  let initial_row_count = restored.rows.len();
  hydrate_restored_rows_if_missing(&mut restored, session_id).await;
  let transcript_loaded = initial_row_count == 0 && !restored.rows.is_empty();

  Ok(Some(prepare_restored_session_for_direct_resume(
    restored,
    transcript_loaded,
  )))
}

fn parse_codex_integration_mode(value: Option<String>) -> Option<CodexIntegrationMode> {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("direct") => Some(CodexIntegrationMode::Direct),
    Some("passive") => Some(CodexIntegrationMode::Passive),
    _ => None,
  }
}

fn parse_claude_integration_mode(value: Option<String>) -> Option<ClaudeIntegrationMode> {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("direct") => Some(ClaudeIntegrationMode::Direct),
    Some("passive") => Some(ClaudeIntegrationMode::Passive),
    _ => None,
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::{SessionControlMode, SessionLifecycleState, TokenUsageSnapshotKind};

  #[test]
  fn parse_provider_valid_lowercase() {
    assert_eq!(parse_provider("claude"), Provider::Claude);
    assert_eq!(parse_provider("codex"), Provider::Codex);
  }

  #[test]
  fn parse_provider_valid_mixed_case() {
    assert_eq!(parse_provider("Claude"), Provider::Claude);
    assert_eq!(parse_provider("CLAUDE"), Provider::Claude);
    assert_eq!(parse_provider("Codex"), Provider::Codex);
    assert_eq!(parse_provider("CODEX"), Provider::Codex);
  }

  #[test]
  fn parse_provider_invalid_falls_back_to_claude() {
    assert_eq!(parse_provider(""), Provider::Claude);
    assert_eq!(parse_provider("gpt4"), Provider::Claude);
    assert_eq!(parse_provider("unknown"), Provider::Claude);
    assert_eq!(parse_provider("  codex  "), Provider::Claude);
  }

  #[test]
  fn restored_state_sets_turn_count_from_persisted_turn_diffs() {
    let mut restored = fixture_restored_session();
    restored.turn_diffs = vec![
      (
        "turn-1".to_string(),
        "diff 1".to_string(),
        1,
        2,
        3,
        4,
        TokenUsageSnapshotKind::ContextTurn,
      ),
      (
        "turn-2".to_string(),
        "diff 2".to_string(),
        5,
        6,
        7,
        8,
        TokenUsageSnapshotKind::LifetimeTotals,
      ),
    ];

    let state = restored_session_to_state(restored);
    assert_eq!(state.turn_count, 2);
    assert_eq!(state.turn_diffs.len(), 2);
  }

  fn fixture_restored_session() -> RestoredSession {
    RestoredSession {
      id: "session-1".to_string(),
      provider: "codex".to_string(),
      status: "active".to_string(),
      work_status: "waiting".to_string(),
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      project_path: "/tmp/project".to_string(),
      transcript_path: None,
      project_name: None,
      model: None,
      custom_name: None,
      summary: None,
      codex_integration_mode: None,
      claude_integration_mode: None,
      codex_thread_id: None,
      claude_sdk_session_id: None,
      started_at: None,
      last_activity_at: None,
      last_progress_at: None,
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
      input_tokens: 0,
      output_tokens: 0,
      cached_tokens: 0,
      context_window: 0,
      token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
      pending_approval_id: None,
      rows: Vec::new(),
      forked_from_session_id: None,
      current_diff: None,
      current_plan: None,
      turn_diffs: Vec::new(),
      git_branch: None,
      git_sha: None,
      current_cwd: None,
      first_prompt: None,
      last_message: None,
      end_reason: None,
      effort: None,
      terminal_session_id: None,
      terminal_app: None,
      approval_version: 0,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
    }
  }
}
