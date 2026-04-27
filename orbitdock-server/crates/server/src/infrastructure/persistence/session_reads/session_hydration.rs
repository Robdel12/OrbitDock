use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides, SessionControlMode};

use super::super::messages::{
  load_latest_completed_conversation_message_from_db, load_messages_from_db,
};
use super::super::transcripts::extract_summary_from_transcript;
use super::super::usage::snapshot_kind_from_str;
use super::codecs::{infer_codex_config_mode, parse_control_mode, parse_lifecycle_state};
use super::hydration::{build_restored_session, load_latest_usage_turn_seq};
use super::projections::{RestoredSessionParts, RestoredSessionRow, StoredCodexConfigRow};

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
                        s.terminal_session_id, s.terminal_app,
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

    let (current_diff, current_plan): (Option<String>, Option<String>) = conn
      .query_row(
        "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
        params![&row.id],
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
        let rows = stmt.query_map(params![&row.id], |row| {
          let snapshot_kind: String = row.get(6)?;
          Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            snapshot_kind_from_str(Some(snapshot_kind.as_str())),
          ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()
      })
      .unwrap_or_default();
    let turn_count = load_latest_usage_turn_seq(&conn, &row.id).max(turn_diffs.len() as u64);

    let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) =
      conn
        .query_row(
          "SELECT git_branch, git_sha, current_cwd FROM sessions WHERE id = ?1",
          params![&row.id],
          |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap_or((None, None, None));

    let persisted_last_message: Option<String> = conn
      .query_row(
        "SELECT last_message FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| row.get(0),
      )
      .unwrap_or(None);
    let last_message = if include_rows {
      load_latest_completed_conversation_message_from_db(&conn, &row.id)
        .unwrap_or(None)
        .or(persisted_last_message)
    } else {
      persisted_last_message
    };

    let effort: Option<String> = conn
      .query_row(
        "SELECT effort FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| row.get(0),
      )
      .unwrap_or(None);

    let config_row: StoredCodexConfigRow = conn
      .query_row(
        "SELECT codex_config_mode, codex_config_profile, codex_model_provider, collaboration_mode, multi_agent, personality, service_tier, developer_instructions, codex_config_source, codex_config_overrides_json FROM sessions WHERE id = ?1",
        params![&row.id],
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

    let pending_approval_id: Option<String> = conn
      .query_row(
        "SELECT pending_approval_id FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| row.get(0),
      )
      .unwrap_or(None);

    let approval_version: u64 = conn
      .query_row(
        "SELECT approval_version FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| row.get::<_, i64>(0).map(|value| value as u64),
      )
      .unwrap_or(0);

    let unread_count: u64 = conn
      .query_row(
        "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
        params![&row.id],
        |row| row.get::<_, i64>(0).map(|value| value as u64),
      )
      .unwrap_or(0);

    let (mission_id, issue_identifier): (Option<String>, Option<String>) = conn
      .query_row(
        "SELECT mission_id, issue_identifier FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| Ok((row.get(0)?, row.get(1)?)),
      )
      .unwrap_or((None, None));

    let allow_bypass_permissions: bool = conn
      .query_row(
        "SELECT COALESCE(allow_bypass_permissions, 0) FROM sessions WHERE id = ?1",
        params![&row.id],
        |row| row.get::<_, i64>(0).map(|v| v != 0),
      )
      .unwrap_or(false);

    let mut summary = row.summary;
    if summary.is_none() && row.provider == "claude" {
      if let Some(path) = row.transcript_path.as_deref() {
        if let Some(extracted) = extract_summary_from_transcript(path) {
          summary = Some(extracted);
        }
      }
    }

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
      summary,
      codex_thread_id: row.codex_thread_id,
      claude_sdk_session_id: row.claude_sdk_session_id,
      started_at: row.started_at,
      last_activity_at: row.last_activity_at,
      last_progress_at: row.last_progress_at,
      approval_policy: row.approval_policy,
      sandbox_mode: row.sandbox_mode,
      permission_mode: row.permission_mode,
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
      input_tokens: row.input_tokens,
      output_tokens: row.output_tokens,
      cached_tokens: row.cached_tokens,
      context_window: row.context_window,
      token_usage_snapshot_kind,
      pending_tool_name: row.pending_tool_name,
      pending_tool_input: row.pending_tool_input,
      pending_question: row.pending_question,
      pending_approval_id,
      rows,
      forked_from_session_id: None,
      current_diff,
      current_plan,
      turn_count,
      turn_diffs,
      git_branch,
      git_sha,
      current_cwd,
      first_prompt: row.first_prompt,
      last_message,
      end_reason: row.end_reason,
      effort,
      terminal_session_id: row.terminal_session_id,
      terminal_app: row.terminal_app,
      approval_version,
      unread_count,
      mission_id,
      issue_identifier,
      allow_bypass_permissions,
    })))
  })
  .await??;

  Ok(result)
}
