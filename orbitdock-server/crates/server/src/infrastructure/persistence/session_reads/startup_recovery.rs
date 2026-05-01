use std::path::PathBuf;

#[cfg(test)]
use rusqlite::OptionalExtension;
use rusqlite::{params, Connection};

use crate::support::session_time::parse_unix_z;

use super::super::chrono_now;
use super::super::messages::load_messages_from_db;
use super::super::transcripts::load_messages_from_transcript;
use super::super::usage::snapshot_kind_from_str;
use super::codecs::{parse_control_mode, parse_lifecycle_state};
use super::hydration::{build_restored_session, load_restored_session_supplement};
use super::projections::{ActiveSessionRow, RestoredSessionParts};
use super::RestoredSession;
use orbitdock_protocol::SessionControlMode;

fn parse_timestamp_to_unix(value: Option<&str>) -> Option<u64> {
  let raw = value?;
  if let Some(unix) = parse_unix_z(Some(raw)) {
    return Some(unix);
  }
  chrono::DateTime::parse_from_rfc3339(raw)
    .ok()
    .map(|parsed| parsed.timestamp().max(0) as u64)
}

#[cfg(test)]
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

    // Normalize control_mode first so the rest of startup recovery can rely on
    // one persisted authority instead of re-deriving direct/passive state from
    // provider-specific integration columns at every call site.
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
                   AND control_mode = 'passive'
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
                   AND control_mode = 'direct'",
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
                   AND control_mode = 'direct'",
      [],
    )?;

    let resumable_count = conn.execute(
      "UPDATE sessions
                 SET lifecycle_state = 'resumable',
                     work_status = 'waiting'
                 WHERE status = 'active'
                   AND control_mode = 'direct'
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

    let mut stmt = conn.prepare(
      "SELECT s.id, s.provider, s.status, s.work_status,
                        s.control_mode,
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END),
                        s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.codex_thread_id, s.claude_sdk_session_id, s.started_at, s.last_activity_at, s.last_progress_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                        s.pending_tool_name, s.pending_tool_input, s.pending_question,
                        COALESCE(uss.snapshot_input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, 0),
                        COALESCE(uss.snapshot_kind, 'unknown'),
                        s.end_reason
                 FROM sessions s
                 LEFT JOIN usage_session_state uss ON uss.session_id = s.id
                 WHERE (s.status = 'active')
                    OR (s.status = 'ended' AND s.end_reason = 'server_shutdown')
                 ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END,
                          COALESCE(s.last_progress_at, s.last_activity_at, s.started_at, '') DESC",
    )?;

    let session_rows: Vec<ActiveSessionRow> = stmt
      .query_map([], ActiveSessionRow::from_row)?
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
        summary,
        codex_thread_id,
        claude_sdk_session_id,
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
        end_reason,
      } = row;
      let token_usage_snapshot_kind =
        snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));
      let control_mode = parse_control_mode(control_mode).unwrap_or(SessionControlMode::Passive);
      let lifecycle_state = parse_lifecycle_state(Some(lifecycle_state));
      let is_ended_history =
        status == "ended" && !matches!(end_reason.as_deref(), Some("server_shutdown"));

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
      let supplement = load_restored_session_supplement(
        &conn,
        &id,
        &provider,
        transcript_path.as_deref(),
        summary,
        true,
      );

      sessions.push(build_restored_session(RestoredSessionParts {
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
        summary: supplement.summary,
        codex_thread_id,
        claude_sdk_session_id,
        started_at,
        last_activity_at,
        last_progress_at,
        approval_policy,
        sandbox_mode,
        permission_mode,
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
        input_tokens,
        output_tokens,
        cached_tokens,
        context_window,
        token_usage_snapshot_kind,
        pending_tool_name,
        pending_tool_input,
        pending_question,
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
        first_prompt,
        last_message: supplement.last_message,
        end_reason,
        effort: supplement.effort,
        terminal_session_id: supplement.terminal_session_id,
        terminal_app: supplement.terminal_app,
        approval_version: supplement.approval_version,
        unread_count: supplement.unread_count,
        mission_id: supplement.mission_id,
        issue_identifier: supplement.issue_identifier,
        allow_bypass_permissions: supplement.allow_bypass_permissions,
      }));
    }

    sessions.sort_by(|left, right| {
      let left_progress = parse_timestamp_to_unix(left.last_progress_at.as_deref());
      let right_progress = parse_timestamp_to_unix(right.last_progress_at.as_deref());
      let left_activity = parse_timestamp_to_unix(left.last_activity_at.as_deref())
        .or_else(|| parse_timestamp_to_unix(left.started_at.as_deref()));
      let right_activity = parse_timestamp_to_unix(right.last_activity_at.as_deref())
        .or_else(|| parse_timestamp_to_unix(right.started_at.as_deref()));

      right_progress
        .cmp(&left_progress)
        .then_with(|| right_activity.cmp(&left_activity))
    });

    Ok(sessions)
  })
  .await??;

  Ok(sessions)
}
