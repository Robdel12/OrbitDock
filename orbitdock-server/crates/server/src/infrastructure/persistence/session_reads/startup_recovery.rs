use std::path::PathBuf;

#[cfg(test)]
use rusqlite::OptionalExtension;
use rusqlite::{params, Connection};

use orbitdock_protocol::{CodexConfigSource, CodexSessionOverrides, SessionControlMode};

use super::{
  chrono_now, control_mode_to_integration_mode, infer_codex_config_mode,
  load_latest_usage_turn_seq, parse_control_mode, parse_lifecycle_state,
  resolve_custom_name_from_first_prompt, snapshot_kind_from_str, ActiveSessionRow, RestoredSession,
  StoredCodexConfigRow,
};
use super::{
  extract_summary_from_transcript, load_latest_completed_conversation_message_from_db,
  load_messages_from_db, load_messages_from_transcript,
};

#[cfg(test)]
#[allow(dead_code)]
pub async fn load_session_lifecycle_state(
  id: &str,
) -> Result<Option<orbitdock_protocol::SessionLifecycleState>, anyhow::Error> {
  load_session_lifecycle_state_with_db_path(crate::infrastructure::paths::db_path(), id).await
}

#[cfg(test)]
async fn load_session_lifecycle_state_with_db_path(
  db_path: PathBuf,
  id: &str,
) -> Result<Option<orbitdock_protocol::SessionLifecycleState>, anyhow::Error> {
  let id_owned = id.to_string();

  tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
    if !db_path.exists() {
      return Ok(None);
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )?;

    let lifecycle_state: Option<String> = conn
      .query_row(
        "SELECT COALESCE(lifecycle_state, CASE WHEN status = 'ended' THEN 'ended' ELSE 'open' END)
                 FROM sessions
                 WHERE id = ?1",
        params![&id_owned],
        |row| row.get(0),
      )
      .optional()?;

    Ok(lifecycle_state.map(|value| parse_lifecycle_state(Some(value))))
  })
  .await?
}

pub async fn load_sessions_for_startup() -> Result<Vec<RestoredSession>, anyhow::Error> {
  load_sessions_for_startup_with_db_path(crate::infrastructure::paths::db_path()).await
}

#[cfg(test)]
#[allow(dead_code)]
pub async fn load_sessions_for_startup_from_db_path(
  db_path: PathBuf,
) -> Result<Vec<RestoredSession>, anyhow::Error> {
  load_sessions_for_startup_with_db_path(db_path).await
}

async fn load_sessions_for_startup_with_db_path(
  db_path: PathBuf,
) -> Result<Vec<RestoredSession>, anyhow::Error> {
  let sessions = tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
    if !db_path.exists() {
      return Ok(Vec::new());
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, 'startup_direct_shadow')
                 WHERE provider = 'claude'
                   AND status = 'active'
                   AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')
                   AND EXISTS (
                       SELECT 1
                       FROM sessions direct
                       WHERE direct.provider = 'claude'
                         AND direct.claude_integration_mode = 'direct'
                         AND direct.claude_sdk_session_id = sessions.id
                   )",
      params![chrono_now()],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     lifecycle_state = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, 'startup_stale_passive')
                 WHERE provider = 'codex'
                   AND COALESCE(control_mode, CASE
                         WHEN provider = 'codex' AND codex_integration_mode = 'direct' THEN 'direct'
                         ELSE 'passive'
                       END) = 'passive'
                   AND status = 'active'
                   AND COALESCE(work_status, 'waiting') NOT IN ('permission', 'question')
                   AND last_activity_at IS NOT NULL
                   AND last_activity_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-15 minutes')",
      params![chrono_now()],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, 'startup_empty_shell')
                 WHERE provider = 'claude'
                   AND status = 'active'
                   AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')
                   AND COALESCE(prompt_count, 0) = 0
                   AND COALESCE(tool_count, 0) = 0
                   AND (first_prompt IS NULL OR trim(first_prompt) = '')
                   AND (custom_name IS NULL OR trim(custom_name) = '')
                   AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
      params![chrono_now()],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, 'startup_ghost_direct')
                 WHERE provider = 'claude'
                   AND claude_integration_mode = 'direct'
                   AND status = 'active'
                   AND claude_sdk_session_id IS NULL
                   AND (first_prompt IS NULL OR trim(first_prompt) = '')
                   AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
      params![chrono_now()],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'ended',
                     work_status = 'ended',
                     ended_at = COALESCE(ended_at, ?1),
                     end_reason = COALESCE(end_reason, 'startup_ghost_direct')
                 WHERE provider = 'codex'
                   AND codex_integration_mode = 'direct'
                   AND status = 'active'
                   AND codex_thread_id IS NULL
                   AND (first_prompt IS NULL OR trim(first_prompt) = '')
                   AND id NOT IN (SELECT DISTINCT session_id FROM messages)",
      params![chrono_now()],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET work_status = 'reply'
                 WHERE status = 'active'
                   AND work_status = 'working'
                   AND ((provider = 'claude' AND claude_integration_mode = 'direct')
                     OR (provider = 'codex' AND codex_integration_mode = 'direct')
                     OR control_mode = 'direct')",
      [],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET status = 'active',
                     work_status = 'waiting',
                     lifecycle_state = 'resumable',
                     ended_at = NULL,
                     end_reason = NULL
                 WHERE status = 'ended'
                   AND end_reason = 'server_shutdown'
                   AND ((provider = 'claude' AND claude_integration_mode = 'direct')
                     OR (provider = 'codex' AND codex_integration_mode = 'direct')
                     OR control_mode = 'direct')",
      [],
    )?;

    let resumable_count = conn.execute(
      "UPDATE sessions
                 SET lifecycle_state = 'resumable',
                     work_status = 'waiting'
                 WHERE status = 'active'
                   AND ((provider = 'claude' AND claude_integration_mode = 'direct')
                     OR (provider = 'codex' AND codex_integration_mode = 'direct')
                     OR control_mode = 'direct')
                   AND COALESCE(lifecycle_state, 'open') != 'ended'",
      [],
    )?;
    tracing::info!(
      component = "restore",
      event = "restore.startup_cleanup.resumable",
      sessions_updated = resumable_count,
      "Set active direct sessions to resumable"
    );

    conn.execute(
      "UPDATE sessions
                 SET lifecycle_state = 'ended'
                 WHERE status = 'ended'
                   AND COALESCE(lifecycle_state, 'ended') != 'ended'",
      [],
    )?;

    conn.execute(
      "UPDATE sessions
                 SET control_mode = CASE
                     WHEN provider = 'claude' AND claude_integration_mode = 'direct' THEN 'direct'
                     WHEN provider = 'codex' AND codex_integration_mode = 'direct' THEN 'direct'
                     ELSE 'passive'
                 END
                 WHERE control_mode IS NULL OR trim(control_mode) = ''",
      [],
    )?;

    let mut stmt = conn.prepare(
      "SELECT s.id, s.provider, s.status, s.work_status,
                        COALESCE(s.control_mode, CASE
                            WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                            WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
                            ELSE 'passive'
                        END),
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                        s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.codex_integration_mode, s.codex_thread_id, s.started_at, s.last_activity_at, s.last_progress_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                        s.pending_tool_name, s.pending_tool_input, s.pending_question,
                        COALESCE(uss.snapshot_input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, 0),
                        COALESCE(uss.snapshot_kind, 'unknown')
                 FROM sessions s
                 LEFT JOIN usage_session_state uss ON uss.session_id = s.id
                 WHERE (s.status = 'active'
                    AND NOT (
                      s.provider = 'claude'
                      AND COALESCE(s.control_mode, CASE
                            WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                            ELSE 'passive'
                          END) != 'direct'
                      AND EXISTS (
                          SELECT 1
                          FROM sessions direct
                          WHERE direct.provider = 'claude'
                            AND direct.claude_sdk_session_id = s.id
                            AND COALESCE(direct.control_mode, CASE
                                  WHEN direct.provider = 'claude' AND direct.claude_integration_mode = 'direct' THEN 'direct'
                                  ELSE 'passive'
                                END) = 'direct'
                      )
                    ))
                    OR (s.status = 'ended' AND s.end_reason = 'server_shutdown')
                 ORDER BY
                   COALESCE(
                     CAST(REPLACE(s.last_progress_at, 'Z', '') AS INTEGER),
                     CAST(REPLACE(s.last_activity_at, 'Z', '') AS INTEGER),
                     0
                   ) DESC,
                   COALESCE(CAST(REPLACE(s.last_activity_at, 'Z', '') AS INTEGER), 0) DESC",
    )?;

    let session_rows: Vec<ActiveSessionRow> = stmt
      .query_map([], |row| {
        Ok(ActiveSessionRow {
          id: row.get(0)?,
          provider: row.get(1)?,
          status: row.get(2)?,
          work_status: row.get(3)?,
          control_mode: row.get(4)?,
          lifecycle_state: parse_lifecycle_state(row.get(5)?),
          project_path: row.get(6)?,
          transcript_path: row.get(7)?,
          project_name: row.get(8)?,
          model: row.get(9)?,
          custom_name: row.get(10)?,
          first_prompt: row.get(11)?,
          summary: row.get(12)?,
          codex_integration_mode: row.get(13)?,
          codex_thread_id: row.get(14)?,
          started_at: row.get(15)?,
          last_activity_at: row.get(16)?,
          last_progress_at: row.get(17)?,
          approval_policy: row.get(18)?,
          sandbox_mode: row.get(19)?,
          permission_mode: row.get(20)?,
          pending_tool_name: row.get(21)?,
          pending_tool_input: row.get(22)?,
          pending_question: row.get(23)?,
          input_tokens: row.get(24)?,
          output_tokens: row.get(25)?,
          cached_tokens: row.get(26)?,
          context_window: row.get(27)?,
          token_usage_snapshot_kind_str: row.get(28)?,
        })
      })?
      .filter_map(|row| row.ok())
      .collect();

    let mut sessions = Vec::new();

    for row in session_rows {
      let ActiveSessionRow {
        id,
        provider,
        status,
        work_status,
        control_mode,
        lifecycle_state,
        project_path,
        transcript_path,
        project_name,
        model,
        custom_name,
        first_prompt,
        summary: _summary,
        codex_integration_mode: raw_codex_integration_mode,
        codex_thread_id,
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
        token_usage_snapshot_kind_str,
      } = row;
      let token_usage_snapshot_kind =
        snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));
      let control_mode = parse_control_mode(control_mode).unwrap_or_else(|| {
        if provider == "codex" && raw_codex_integration_mode.as_deref() == Some("direct") {
          SessionControlMode::Direct
        } else {
          SessionControlMode::Passive
        }
      });
      let (codex_integration_mode, claude_integration_mode) =
        control_mode_to_integration_mode(&provider, control_mode);

      let end_reason_val: Option<String> = conn
        .query_row(
          "SELECT end_reason FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);
      let is_ended_history =
        status == "ended" && !matches!(end_reason_val.as_deref(), Some("server_shutdown"));

      let rows = if is_ended_history {
        Vec::new()
      } else {
        let mut rows = load_messages_from_db(&conn, &id)?;
        if rows.is_empty() {
          if let Some(path) = transcript_path.as_deref() {
            rows = load_messages_from_transcript(path, &id)?;
          }
        }
        rows
      };
      let custom_name = resolve_custom_name_from_first_prompt(
        &conn,
        &id,
        custom_name,
        first_prompt.as_deref(),
      )?;

      let forked_from_session_id: Option<String> = conn
        .query_row(
          "SELECT forked_from_session_id FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);

      let (current_diff, current_plan): (Option<String>, Option<String>) = conn
        .query_row(
          "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
          params![id],
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
          let rows = stmt.query_map(params![id], |row| {
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
            params![id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
          )
          .unwrap_or((None, None, None));

      let claude_sdk_session_id: Option<String> = conn
        .query_row(
          "SELECT claude_sdk_session_id FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);

      let persisted_last_message: Option<String> = conn
        .query_row(
          "SELECT last_message FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);
      let last_message = load_latest_completed_conversation_message_from_db(&conn, &id)
        .unwrap_or(None)
        .or(persisted_last_message);

      let effort: Option<String> = conn
        .query_row(
          "SELECT effort FROM sessions WHERE id = ?1",
          params![id],
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
          params![id],
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
      let codex_config_mode = infer_codex_config_mode(
        codex_config_mode_raw.as_deref(),
        codex_config_profile.as_deref(),
        codex_model_provider.as_deref(),
      );
      let codex_config_source = match codex_config_source_raw.as_deref() {
        Some("orbitdock") => Some(CodexConfigSource::Orbitdock),
        Some("user") => Some(CodexConfigSource::User),
        _ => None,
      };
      let codex_config_overrides = codex_config_overrides_raw
        .and_then(|value| serde_json::from_str::<CodexSessionOverrides>(&value).ok());
      let codex_integration_mode = if provider == "codex" {
        Some(
          match control_mode {
            SessionControlMode::Direct => "direct",
            SessionControlMode::Passive => "passive",
          }
          .to_string(),
        )
      } else {
        codex_integration_mode
      };
      let claude_integration_mode = if provider == "claude" {
        Some(
          match control_mode {
            SessionControlMode::Direct => "direct",
            SessionControlMode::Passive => "passive",
          }
          .to_string(),
        )
      } else {
        claude_integration_mode
      };

      let (terminal_session_id, terminal_app): (Option<String>, Option<String>) = conn
        .query_row(
          "SELECT terminal_session_id, terminal_app FROM sessions WHERE id = ?1",
          params![id],
          |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap_or((None, None));

      let pending_approval_id: Option<String> = conn
        .query_row(
          "SELECT pending_approval_id FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);

      let approval_version: u64 = conn
        .query_row(
          "SELECT approval_version FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get::<_, i64>(0).map(|value| value as u64),
        )
        .unwrap_or(0);

      let unread_count: u64 = conn
        .query_row(
          "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND sequence > (SELECT COALESCE(last_read_sequence, 0) FROM sessions WHERE id = ?1) AND type NOT IN ('user', 'steer')",
          params![id],
          |row| row.get::<_, i64>(0).map(|value| value as u64),
        )
        .unwrap_or(0);

      let (mission_id, issue_identifier): (Option<String>, Option<String>) = conn
        .query_row(
          "SELECT mission_id, issue_identifier FROM sessions WHERE id = ?1",
          params![id],
          |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap_or((None, None));

      let allow_bypass_permissions: bool = conn
        .query_row(
          "SELECT COALESCE(allow_bypass_permissions, 0) FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get::<_, i64>(0).map(|v| v != 0),
        )
        .unwrap_or(false);

      let mut summary: Option<String> = conn
        .query_row(
          "SELECT summary FROM sessions WHERE id = ?1",
          params![id],
          |row| row.get(0),
        )
        .unwrap_or(None);

      if summary.is_none() && provider == "claude" {
        if let Some(path) = transcript_path.as_deref() {
          if let Some(extracted) = extract_summary_from_transcript(path) {
            summary = Some(extracted);
          }
        }
      }

      sessions.push(RestoredSession {
        id,
        provider,
        status,
        work_status,
        control_mode,
        lifecycle_state,
        project_path,
        transcript_path,
        project_name,
        model,
        custom_name,
        summary,
        codex_integration_mode,
        claude_integration_mode,
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
        forked_from_session_id,
        current_diff,
        current_plan,
        turn_count,
        turn_diffs,
        git_branch,
        git_sha,
        current_cwd,
        first_prompt,
        last_message,
        end_reason: end_reason_val,
        effort,
        terminal_session_id,
        terminal_app,
        approval_version,
        unread_count,
        mission_id,
        issue_identifier,
        allow_bypass_permissions,
      });
    }

    Ok(sessions)
  })
  .await??;

  Ok(sessions)
}
