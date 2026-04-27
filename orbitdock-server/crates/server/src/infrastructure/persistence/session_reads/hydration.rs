use rusqlite::{params, Connection};

use super::projections::{RestoredSession, RestoredSessionParts};

pub(crate) fn load_latest_usage_turn_seq(conn: &Connection, session_id: &str) -> u64 {
  // `turn_count` seeds the next `turn-N` id, so restore from the latest
  // persisted sequence instead of counting rows and risking id reuse.
  conn
    .query_row(
      "SELECT COALESCE(MAX(turn_seq), 0)
       FROM usage_turns
       WHERE session_id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0),
    )
    .unwrap_or(0)
    .max(0) as u64
}

pub(crate) fn build_restored_session(parts: RestoredSessionParts) -> RestoredSession {
  RestoredSession {
    id: parts.id,
    provider: parts.provider,
    status: parts.status,
    work_status: parts.work_status,
    control_mode: parts.control_mode,
    lifecycle_state: parts.lifecycle_state,
    project_path: parts.project_path,
    transcript_path: parts.transcript_path,
    project_name: parts.project_name,
    model: parts.model,
    custom_name: parts.custom_name,
    summary: parts.summary,
    codex_thread_id: parts.codex_thread_id,
    claude_sdk_session_id: parts.claude_sdk_session_id,
    started_at: parts.started_at,
    last_activity_at: parts.last_activity_at,
    last_progress_at: parts.last_progress_at,
    approval_policy: parts.approval_policy,
    sandbox_mode: parts.sandbox_mode,
    permission_mode: parts.permission_mode,
    collaboration_mode: parts.collaboration_mode,
    multi_agent: parts.multi_agent,
    personality: parts.personality,
    service_tier: parts.service_tier,
    developer_instructions: parts.developer_instructions,
    codex_config_mode: parts.codex_config_mode,
    codex_config_profile: parts.codex_config_profile,
    codex_model_provider: parts.codex_model_provider,
    codex_config_source: parts.codex_config_source,
    codex_config_overrides: parts.codex_config_overrides,
    input_tokens: parts.input_tokens,
    output_tokens: parts.output_tokens,
    cached_tokens: parts.cached_tokens,
    context_window: parts.context_window,
    token_usage_snapshot_kind: parts.token_usage_snapshot_kind,
    pending_tool_name: parts.pending_tool_name,
    pending_tool_input: parts.pending_tool_input,
    pending_question: parts.pending_question,
    pending_approval_id: parts.pending_approval_id,
    rows: parts.rows,
    forked_from_session_id: parts.forked_from_session_id,
    current_diff: parts.current_diff,
    current_plan: parts.current_plan,
    turn_count: parts.turn_count,
    turn_diffs: parts.turn_diffs,
    git_branch: parts.git_branch,
    git_sha: parts.git_sha,
    current_cwd: parts.current_cwd,
    first_prompt: parts.first_prompt,
    last_message: parts.last_message,
    end_reason: parts.end_reason,
    effort: parts.effort,
    terminal_session_id: parts.terminal_session_id,
    terminal_app: parts.terminal_app,
    approval_version: parts.approval_version,
    unread_count: parts.unread_count,
    mission_id: parts.mission_id,
    issue_identifier: parts.issue_identifier,
    allow_bypass_permissions: parts.allow_bypass_permissions,
  }
}
