use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use orbitdock_protocol::SessionControlMode;

use super::super::messages::load_messages_from_db;
use super::super::usage::snapshot_kind_from_str;
use super::codecs::{parse_control_mode, parse_lifecycle_state};
use super::hydration::{build_restored_session, load_restored_session_supplement};
use super::projections::{RestoredSessionParts, RestoredSessionRow};

pub async fn load_session_by_id(id: &str) -> Result<Option<super::RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, true).await
}

pub async fn load_session_metadata_by_id(
  id: &str,
) -> Result<Option<super::RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, false).await
}

async fn load_session_by_id_with_db_path(
  db_path: PathBuf,
  id: &str,
  include_rows: bool,
) -> Result<Option<super::RestoredSession>, anyhow::Error> {
  let id_owned = id.to_string();
  let result = tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
    if !db_path.exists() {
      return Ok(None);
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
    )?;

    let mut stmt = conn.prepare(
      "SELECT s.id, s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.status, s.work_status, s.started_at, s.last_activity_at, s.last_progress_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                        s.pending_tool_name, s.pending_tool_input, s.pending_question,
                        COALESCE(uss.snapshot_input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, 0),
                        s.provider, s.control_mode,
                        s.claude_sdk_session_id, s.codex_thread_id, s.end_reason,
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                        COALESCE(uss.snapshot_kind, 'unknown')
                 FROM sessions s
                 LEFT JOIN usage_session_state uss ON uss.session_id = s.id
                 WHERE s.id = ?1",
    )?;

    let row = stmt
      .query_row(params![&id_owned], RestoredSessionRow::from_row)
      .optional()?;

    let Some(row) = row else {
      return Ok(None);
    };

    let token_usage_snapshot_kind =
      snapshot_kind_from_str(Some(row.token_usage_snapshot_kind_str.as_str()));
    let control_mode = parse_control_mode(row.control_mode).unwrap_or(SessionControlMode::Passive);
    let rows = if include_rows {
      load_messages_from_db(&conn, &row.id)?
    } else {
      Vec::new()
    };
    let supplement = load_restored_session_supplement(
      &conn,
      &row.id,
      &row.provider,
      row.transcript_path.as_deref(),
      row.summary,
      include_rows,
    );

    Ok(Some(build_restored_session(RestoredSessionParts {
      id: row.id,
      provider: row.provider,
      status: row.status,
      work_status: row.work_status,
      control_mode,
      lifecycle_state: parse_lifecycle_state(Some(row.lifecycle_state)),
      project_path: row.project_path,
      transcript_path: row.transcript_path,
      project_name: row.project_name,
      model: row.model,
      custom_name: row.custom_name,
      summary: supplement.summary,
      codex_thread_id: row.codex_thread_id,
      claude_sdk_session_id: row.claude_sdk_session_id,
      started_at: row.started_at,
      last_activity_at: row.last_activity_at,
      last_progress_at: row.last_progress_at,
      approval_policy: row.approval_policy,
      sandbox_mode: row.sandbox_mode,
      permission_mode: row.permission_mode,
      collaboration_mode: supplement.collaboration_mode,
      multi_agent: supplement.multi_agent,
      personality: supplement.personality,
      service_tier: supplement.service_tier,
      developer_instructions: supplement.developer_instructions,
      codex_config_mode: supplement.codex_config_mode,
      codex_config_profile: supplement.codex_config_profile,
      codex_model_provider: supplement.codex_model_provider,
      codex_config_source: supplement.codex_config_source,
      codex_config_overrides: supplement.codex_config_overrides,
      input_tokens: row.input_tokens,
      output_tokens: row.output_tokens,
      cached_tokens: row.cached_tokens,
      context_window: row.context_window,
      token_usage_snapshot_kind,
      pending_tool_name: row.pending_tool_name,
      pending_tool_input: row.pending_tool_input,
      pending_question: row.pending_question,
      pending_approval_id: supplement.pending_approval_id,
      rows,
      forked_from_session_id: supplement.forked_from_session_id,
      current_diff: supplement.current_diff,
      current_plan: supplement.current_plan,
      turn_count: supplement.turn_count,
      turn_diffs: supplement.turn_diffs,
      git_branch: supplement.git_branch,
      git_sha: supplement.git_sha,
      current_cwd: supplement.current_cwd,
      first_prompt: row.first_prompt,
      last_message: supplement.last_message,
      end_reason: row.end_reason,
      effort: supplement.effort,
      terminal_session_id: supplement.terminal_session_id,
      terminal_app: supplement.terminal_app,
      approval_version: supplement.approval_version,
      unread_count: supplement.unread_count,
      mission_id: supplement.mission_id,
      issue_identifier: supplement.issue_identifier,
      allow_bypass_permissions: supplement.allow_bypass_permissions,
    })))
  })
  .await??;

  Ok(result)
}
