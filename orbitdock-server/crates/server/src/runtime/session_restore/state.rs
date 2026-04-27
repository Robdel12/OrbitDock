use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexApprovalPolicy, CodexIntegrationMode, Provider, SessionControlMode,
  SessionState, SessionStatus, TokenUsage, TurnDiff, WorkStatus,
};

use crate::domain::sessions::facets::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use crate::domain::sessions::session::{SessionHandle, SessionRestoreData};
use crate::infrastructure::persistence::RestoredSession;

use super::parsing::{parse_provider, parse_session_status, parse_work_status};

fn approval_policy_details(restored: &RestoredSession) -> Option<CodexApprovalPolicy> {
  restored
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.approval_policy_details.clone())
    .or_else(|| {
      restored
        .approval_policy
        .as_deref()
        .and_then(CodexApprovalPolicy::from_storage_text)
    })
}

fn sandbox_policy_details(
  restored: &RestoredSession,
) -> Option<orbitdock_protocol::CodexSandboxPolicy> {
  restored
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.sandbox_policy_details.clone())
    .or_else(|| {
      restored
        .sandbox_mode
        .as_deref()
        .and_then(orbitdock_protocol::CodexSandboxPolicy::from_storage_text)
    })
}

fn turn_diffs_from_restored(
  turn_diffs: Vec<(
    String,
    String,
    i64,
    i64,
    i64,
    i64,
    orbitdock_protocol::TokenUsageSnapshotKind,
  )>,
) -> Vec<TurnDiff> {
  turn_diffs
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
    .collect()
}

fn turn_diffs_with_optional_usage(
  turn_diffs: Vec<(
    String,
    String,
    i64,
    i64,
    i64,
    i64,
    orbitdock_protocol::TokenUsageSnapshotKind,
  )>,
) -> Vec<TurnDiff> {
  turn_diffs
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
    .collect()
}

pub(crate) fn restored_session_to_state(restored: RestoredSession) -> SessionState {
  let provider = parse_provider(&restored.provider);
  let status = parse_session_status(restored.end_reason.as_ref(), &restored.status);
  let work_status = parse_work_status(status, &restored.work_status);
  let control_mode = restored.control_mode;
  let approval_policy_details = approval_policy_details(&restored);
  let sandbox_policy_details = sandbox_policy_details(&restored);
  let total_row_count = restored.rows.len() as u64;
  let oldest_sequence = restored.rows.first().map(|entry| entry.sequence);
  let newest_sequence = restored.rows.last().map(|entry| entry.sequence);
  let turn_diffs = turn_diffs_from_restored(restored.turn_diffs);
  let turn_count = restored.turn_count.max(turn_diffs.len() as u64);

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
    accepts_user_input: false,
    steerable: false,
    connector_attached: false,
    can_interrupt: false,
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
    codex_integration_mode: matches!(provider, Provider::Codex).then_some(
      match restored.control_mode {
        SessionControlMode::Direct => CodexIntegrationMode::Direct,
        SessionControlMode::Passive => CodexIntegrationMode::Passive,
      },
    ),
    claude_integration_mode: matches!(provider, Provider::Claude).then_some(
      match restored.control_mode {
        SessionControlMode::Direct => ClaudeIntegrationMode::Direct,
        SessionControlMode::Passive => ClaudeIntegrationMode::Passive,
      },
    ),
    approval_policy_details,
    approval_policy: restored.approval_policy,
    sandbox_mode: restored.sandbox_mode,
    sandbox_policy_details,
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
  let turn_count = restored.turn_count.max(restored.turn_diffs.len() as u64);
  let approval_policy_details = approval_policy_details(&restored);
  let sandbox_policy_details = sandbox_policy_details(&restored);

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
      sandbox_policy_details,
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
    turn_count,
    turn_diffs: turn_diffs_with_optional_usage(restored.turn_diffs),
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
