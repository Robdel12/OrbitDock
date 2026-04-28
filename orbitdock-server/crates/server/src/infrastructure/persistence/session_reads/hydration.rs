use rusqlite::{params, Connection};

use super::super::messages::load_latest_completed_conversation_message_from_db;
use super::super::transcripts::extract_summary_from_transcript;
use super::codecs::infer_codex_config_mode;
use super::projections::{RestoredSession, RestoredSessionParts, StoredCodexConfigRow};
use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides, TokenUsageSnapshotKind};

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

pub(crate) struct RestoredSessionSupplement {
  pub summary: Option<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub codex_config_mode: Option<orbitdock_protocol::CodexConfigMode>,
  pub codex_config_profile: Option<String>,
  pub codex_model_provider: Option<String>,
  pub codex_config_source: Option<CodexConfigSource>,
  pub codex_config_overrides: Option<CodexSessionOverrides>,
  pub pending_approval_id: Option<String>,
  pub forked_from_session_id: Option<String>,
  pub current_diff: Option<String>,
  pub current_plan: Option<String>,
  pub turn_count: u64,
  pub turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)>,
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub last_message: Option<String>,
  pub effort: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub approval_version: u64,
  pub unread_count: u64,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub allow_bypass_permissions: bool,
}

pub(crate) fn load_restored_session_supplement(
  conn: &Connection,
  session_id: &str,
  provider: &str,
  transcript_path: Option<&str>,
  summary: Option<String>,
  include_completed_last_message: bool,
) -> RestoredSessionSupplement {
  let forked_from_session_id: Option<String> = conn
    .query_row(
      "SELECT forked_from_session_id FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get(0),
    )
    .unwrap_or(None);

  let (current_diff, current_plan): (Option<String>, Option<String>) = conn
    .query_row(
      "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap_or((None, None));

  let turn_diffs = conn
    .prepare(
      "SELECT td.turn_id,
              td.diff,
              COALESCE(ut.input_tokens, td.input_tokens, 0),
              COALESCE(ut.output_tokens, td.output_tokens, 0),
              COALESCE(ut.cached_tokens, td.cached_tokens, 0),
              COALESCE(ut.context_window, td.context_window, 0),
              COALESCE(ut.snapshot_kind, 'unknown')
       FROM turn_diffs td
       LEFT JOIN usage_turns ut
         ON ut.session_id = td.session_id
        AND ut.turn_id = td.turn_id
       WHERE td.session_id = ?1
       ORDER BY COALESCE(ut.turn_seq, td.rowid)",
    )
    .and_then(|mut stmt| {
      let rows = stmt.query_map(params![session_id], |row| {
        let snapshot_kind: String = row.get(6)?;
        Ok((
          row.get::<_, String>(0)?,
          row.get::<_, String>(1)?,
          row.get::<_, i64>(2)?,
          row.get::<_, i64>(3)?,
          row.get::<_, i64>(4)?,
          row.get::<_, i64>(5)?,
          super::super::usage::snapshot_kind_from_str(Some(snapshot_kind.as_str())),
        ))
      })?;
      rows.collect::<Result<Vec<_>, _>>()
    })
    .unwrap_or_default();
  let turn_count = load_latest_usage_turn_seq(conn, session_id).max(turn_diffs.len() as u64);

  let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) = conn
    .query_row(
      "SELECT git_branch, git_sha, current_cwd FROM sessions WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .unwrap_or((None, None, None));

  let persisted_last_message: Option<String> = conn
    .query_row(
      "SELECT last_message FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get(0),
    )
    .unwrap_or(None);
  let last_message = if include_completed_last_message {
    load_latest_completed_conversation_message_from_db(conn, session_id)
      .unwrap_or(None)
      .or(persisted_last_message)
  } else {
    persisted_last_message
  };

  let effort: Option<String> = conn
    .query_row(
      "SELECT effort FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get(0),
    )
    .unwrap_or(None);

  let config_row: StoredCodexConfigRow = conn
    .query_row(
      "SELECT codex_config_mode, codex_config_profile, codex_model_provider, collaboration_mode, multi_agent, personality, service_tier, developer_instructions, codex_config_source, codex_config_overrides_json FROM sessions WHERE id = ?1",
      params![session_id],
      StoredCodexConfigRow::from_row,
    )
    .unwrap_or(StoredCodexConfigRow {
      codex_config_mode_raw: None,
      codex_config_profile: None,
      codex_model_provider: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_source_raw: None,
      codex_config_overrides_raw: None,
    });
  let codex_config_mode = infer_codex_config_mode(config_row.codex_config_mode_raw.as_deref());
  let codex_config_source = match config_row.codex_config_source_raw.as_deref() {
    Some("orbitdock") => Some(CodexConfigSource::Orbitdock),
    Some("user") => Some(CodexConfigSource::User),
    _ => None,
  };
  let codex_config_overrides = config_row
    .codex_config_overrides_raw
    .and_then(|value| serde_json::from_str::<CodexSessionOverrides>(&value).ok());
  let (terminal_session_id, terminal_app): (Option<String>, Option<String>) = conn
    .query_row(
      "SELECT terminal_session_id, terminal_app FROM sessions WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap_or((None, None));

  let pending_approval_id: Option<String> = conn
    .query_row(
      "SELECT pending_approval_id FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get(0),
    )
    .unwrap_or(None);

  let approval_version: u64 = conn
    .query_row(
      "SELECT approval_version FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0).map(|value| value as u64),
    )
    .unwrap_or(0);

  let unread_count: u64 = conn
    .query_row(
      "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
      params![session_id],
      |row| row.get::<_, i64>(0).map(|value| value as u64),
    )
    .unwrap_or(0);

  let (mission_id, issue_identifier): (Option<String>, Option<String>) = conn
    .query_row(
      "SELECT mission_id, issue_identifier FROM sessions WHERE id = ?1",
      params![session_id],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap_or((None, None));

  let allow_bypass_permissions: bool = conn
    .query_row(
      "SELECT COALESCE(allow_bypass_permissions, 0) FROM sessions WHERE id = ?1",
      params![session_id],
      |row| row.get::<_, i64>(0).map(|v| v != 0),
    )
    .unwrap_or(false);

  let mut summary = summary;
  if summary.is_none() && provider == "claude" {
    if let Some(path) = transcript_path {
      if let Some(extracted) = extract_summary_from_transcript(path) {
        summary = Some(extracted);
      }
    }
  }

  RestoredSessionSupplement {
    summary,
    collaboration_mode: config_row.collaboration_mode,
    multi_agent: config_row.multi_agent,
    personality: config_row.personality,
    service_tier: config_row.service_tier,
    developer_instructions: config_row.developer_instructions,
    codex_config_mode,
    codex_config_profile: config_row.codex_config_profile,
    codex_model_provider: config_row.codex_model_provider,
    codex_config_source,
    codex_config_overrides,
    pending_approval_id,
    forked_from_session_id,
    current_diff,
    current_plan,
    turn_count,
    turn_diffs,
    git_branch,
    git_sha,
    current_cwd,
    last_message,
    effort,
    terminal_session_id,
    terminal_app,
    approval_version,
    unread_count,
    mission_id,
    issue_identifier,
    allow_bypass_permissions,
  }
}
