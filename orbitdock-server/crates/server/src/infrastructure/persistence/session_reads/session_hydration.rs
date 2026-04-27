use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides, SessionControlMode};

use super::super::messages::{
  load_latest_completed_conversation_message_from_db, load_messages_from_db,
};
use super::super::usage::snapshot_kind_from_str;
use super::{
  infer_codex_config_mode, load_latest_usage_turn_seq, parse_control_mode, parse_lifecycle_state,
  RestoredSession, StoredCodexConfigRow,
};

pub async fn load_session_by_id(id: &str) -> Result<Option<RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, true).await
}

pub async fn load_session_metadata_by_id(
  id: &str,
) -> Result<Option<RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, false).await
}

async fn load_session_by_id_with_db_path(
  db_path: PathBuf,
  id: &str,
  include_rows: bool,
) -> Result<Option<RestoredSession>, anyhow::Error> {
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
                        s.provider, COALESCE(s.control_mode, CASE
                            WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                            WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
                            ELSE 'passive'
                        END),
                        s.claude_sdk_session_id, s.codex_thread_id, s.end_reason,
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                        s.terminal_session_id, s.terminal_app,
                        COALESCE(uss.snapshot_kind, 'unknown')
                 FROM sessions s
                 LEFT JOIN usage_session_state uss ON uss.session_id = s.id
                 WHERE s.id = ?1",
    )?;

    let row = stmt
      .query_row(params![&id_owned], |row| {
        Ok((
          row.get::<_, String>(0)?,
          row.get::<_, String>(1)?,
          row.get::<_, Option<String>>(2)?,
          row.get::<_, Option<String>>(3)?,
          row.get::<_, Option<String>>(4)?,
          row.get::<_, Option<String>>(5)?,
          row.get::<_, Option<String>>(6)?,
          row.get::<_, Option<String>>(7)?,
          row.get::<_, String>(8)?,
          row.get::<_, String>(9)?,
          row.get::<_, Option<String>>(10)?,
          row.get::<_, Option<String>>(11)?,
          row.get::<_, Option<String>>(12)?,
          row.get::<_, Option<String>>(13)?,
          row.get::<_, Option<String>>(14)?,
          row.get::<_, Option<String>>(15)?,
          row.get::<_, Option<String>>(16)?,
          row.get::<_, Option<String>>(17)?,
          row.get::<_, Option<String>>(18)?,
          row.get::<_, i64>(19)?,
          row.get::<_, i64>(20)?,
          row.get::<_, i64>(21)?,
          row.get::<_, i64>(22)?,
          row.get::<_, String>(23)?,
          row.get::<_, Option<String>>(24)?,
          row.get::<_, Option<String>>(25)?,
          row.get::<_, Option<String>>(26)?,
          row.get::<_, Option<String>>(27)?,
          row.get::<_, String>(28)?,
          row.get::<_, Option<String>>(29)?,
          row.get::<_, Option<String>>(30)?,
          row.get::<_, String>(31)?,
        ))
      })
      .optional()?;

    let Some((
      id,
      project_path,
      transcript_path,
      project_name,
      model,
      custom_name,
      first_prompt,
      summary,
      status,
      work_status,
      started_at,
      last_activity_at,
      last_progress_at,
      approval_policy,
      sandbox_mode,
      permission_mode,
      pending_tool_name,
      pending_tool_input,
      pending_question,
      input_tokens,
      output_tokens,
      cached_tokens,
      context_window,
      provider,
      control_mode,
      claude_sdk_session_id,
      codex_thread_id,
      end_reason,
      lifecycle_state,
      terminal_session_id,
      terminal_app,
      token_usage_snapshot_kind_str,
    )) = row
    else {
      return Ok(None);
    };

    let token_usage_snapshot_kind =
      snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));
    let control_mode = parse_control_mode(control_mode).unwrap_or(SessionControlMode::Passive);
    let rows = if include_rows {
      load_messages_from_db(&conn, &id)?
    } else {
      Vec::new()
    };

    let (current_diff, current_plan): (Option<String>, Option<String>) = conn
      .query_row(
        "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
        params![&id],
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
        let rows = stmt.query_map(params![&id], |row| {
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
    let turn_count = load_latest_usage_turn_seq(&conn, &id).max(turn_diffs.len() as u64);

    let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) =
      conn
        .query_row(
          "SELECT git_branch, git_sha, current_cwd FROM sessions WHERE id = ?1",
          params![&id],
          |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap_or((None, None, None));

    let persisted_last_message: Option<String> = conn
      .query_row(
        "SELECT last_message FROM sessions WHERE id = ?1",
        params![&id],
        |row| row.get(0),
      )
      .unwrap_or(None);
    let last_message = if include_rows {
      load_latest_completed_conversation_message_from_db(&conn, &id)
        .unwrap_or(None)
        .or(persisted_last_message)
    } else {
      persisted_last_message
    };

    let effort: Option<String> = conn
      .query_row(
        "SELECT effort FROM sessions WHERE id = ?1",
        params![&id],
        |row| row.get(0),
      )
      .unwrap_or(None);

    let (
      codex_config_mode_raw,
      codex_config_profile,
      codex_model_provider,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      codex_config_source_raw,
      codex_config_overrides_raw,
    ): StoredCodexConfigRow = conn
      .query_row(
        "SELECT codex_config_mode, codex_config_profile, codex_model_provider, collaboration_mode, multi_agent, personality, service_tier, developer_instructions, codex_config_source, codex_config_overrides_json FROM sessions WHERE id = ?1",
        params![&id],
        |row| {
          Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
            row.get(5)?,
            row.get(6)?,
            row.get(7)?,
            row.get(8)?,
            row.get(9)?,
          ))
        },
      )
      .unwrap_or((None, None, None, None, None, None, None, None, None, None));
    let codex_config_mode = infer_codex_config_mode(codex_config_mode_raw.as_deref());
    let codex_config_source = match codex_config_source_raw.as_deref() {
      Some("orbitdock") => Some(CodexConfigSource::Orbitdock),
      Some("user") => Some(CodexConfigSource::User),
      _ => None,
    };
    let codex_config_overrides =
      codex_config_overrides_raw.and_then(|value| serde_json::from_str::<CodexSessionOverrides>(&value).ok());

    let pending_approval_id: Option<String> = conn
      .query_row(
        "SELECT pending_approval_id FROM sessions WHERE id = ?1",
        params![&id],
        |row| row.get(0),
      )
      .unwrap_or(None);

    let approval_version: u64 = conn
      .query_row(
        "SELECT approval_version FROM sessions WHERE id = ?1",
        params![&id],
        |row| row.get::<_, i64>(0).map(|value| value as u64),
      )
      .unwrap_or(0);

    let unread_count: u64 = conn
      .query_row(
        "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
        params![&id],
        |row| row.get::<_, i64>(0).map(|value| value as u64),
      )
      .unwrap_or(0);

    let (mission_id, issue_identifier): (Option<String>, Option<String>) = conn
      .query_row(
        "SELECT mission_id, issue_identifier FROM sessions WHERE id = ?1",
        params![&id],
        |row| Ok((row.get(0)?, row.get(1)?)),
      )
      .unwrap_or((None, None));

    let allow_bypass_permissions: bool = conn
      .query_row(
        "SELECT COALESCE(allow_bypass_permissions, 0) FROM sessions WHERE id = ?1",
        params![&id],
        |row| row.get::<_, i64>(0).map(|v| v != 0),
      )
      .unwrap_or(false);

    Ok(Some(RestoredSession {
      id,
      provider,
      status,
      work_status,
      control_mode,
      lifecycle_state: parse_lifecycle_state(Some(lifecycle_state)),
      project_path,
      transcript_path,
      project_name,
      model,
      custom_name,
      summary,
      codex_thread_id,
      claude_sdk_session_id,
      started_at,
      last_activity_at,
      last_progress_at,
      approval_policy,
      sandbox_mode,
      permission_mode,
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
      input_tokens,
      output_tokens,
      cached_tokens,
      context_window,
      token_usage_snapshot_kind,
      pending_tool_name,
      pending_tool_input,
      pending_question,
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
      first_prompt,
      last_message,
      end_reason,
      effort,
      terminal_session_id,
      terminal_app,
      approval_version,
      unread_count,
      mission_id,
      issue_identifier,
      allow_bypass_permissions,
    }))
  })
  .await??;

  Ok(result)
}
