use rusqlite::{params, Connection, OptionalExtension};
use std::path::PathBuf;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
  CodexConfigMode, CodexConfigSource, CodexSessionOverrides, SessionControlMode,
  SessionLifecycleState, SessionStatus, TokenUsageSnapshotKind,
};

use super::chrono_now;
use super::messages::{load_latest_completed_conversation_message_from_db, load_messages_from_db};
use super::transcripts::{extract_summary_from_transcript, load_messages_from_transcript};
use super::usage::snapshot_kind_from_str;

type StoredCodexConfigRow = (
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<bool>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
  Option<String>,
);

fn infer_codex_config_mode(
  raw_mode: Option<&str>,
  config_profile: Option<&str>,
  model_provider: Option<&str>,
) -> Option<CodexConfigMode> {
  match raw_mode {
    Some("inherit") => Some(CodexConfigMode::Inherit),
    Some("profile") => Some(CodexConfigMode::Profile),
    Some("custom") => Some(CodexConfigMode::Custom),
    Some(_) => None,
    None => {
      if config_profile.is_some_and(|value| !value.trim().is_empty()) {
        Some(CodexConfigMode::Profile)
      } else if model_provider.is_some_and(|value| !value.trim().is_empty()) {
        Some(CodexConfigMode::Custom)
      } else {
        None
      }
    }
  }
}

/// Intermediate row from the active-sessions SQL query.
struct ActiveSessionRow {
  id: String,
  provider: String,
  status: String,
  work_status: String,
  control_mode: Option<String>,
  lifecycle_state: SessionLifecycleState,
  project_path: String,
  transcript_path: Option<String>,
  project_name: Option<String>,
  model: Option<String>,
  custom_name: Option<String>,
  first_prompt: Option<String>,
  summary: Option<String>,
  codex_integration_mode: Option<String>,
  codex_thread_id: Option<String>,
  started_at: Option<String>,
  last_activity_at: Option<String>,
  last_progress_at: Option<String>,
  approval_policy: Option<String>,
  sandbox_mode: Option<String>,
  permission_mode: Option<String>,
  pending_tool_name: Option<String>,
  pending_tool_input: Option<String>,
  pending_question: Option<String>,
  input_tokens: i64,
  output_tokens: i64,
  cached_tokens: i64,
  context_window: i64,
  token_usage_snapshot_kind_str: String,
}

/// A session restored from the database on startup.
#[derive(Debug)]
pub struct RestoredSession {
  pub id: String,
  pub provider: String,
  pub status: String,
  pub work_status: String,
  pub control_mode: SessionControlMode,
  pub lifecycle_state: SessionLifecycleState,
  pub project_path: String,
  pub transcript_path: Option<String>,
  pub project_name: Option<String>,
  pub model: Option<String>,
  pub custom_name: Option<String>,
  pub summary: Option<String>,
  pub codex_integration_mode: Option<String>,
  pub claude_integration_mode: Option<String>,
  pub codex_thread_id: Option<String>,
  pub claude_sdk_session_id: Option<String>,
  pub started_at: Option<String>,
  pub last_activity_at: Option<String>,
  pub last_progress_at: Option<String>,
  pub approval_policy: Option<String>,
  pub sandbox_mode: Option<String>,
  pub permission_mode: Option<String>,
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
  pub input_tokens: i64,
  pub output_tokens: i64,
  pub cached_tokens: i64,
  pub context_window: i64,
  pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub pending_approval_id: Option<String>,
  pub rows: Vec<ConversationRowEntry>,
  pub forked_from_session_id: Option<String>,
  pub current_diff: Option<String>,
  pub current_plan: Option<String>,
  pub turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)>,
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub first_prompt: Option<String>,
  pub last_message: Option<String>,
  pub end_reason: Option<String>,
  pub effort: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub approval_version: u64,
  pub unread_count: u64,
  pub mission_id: Option<String>,
  pub issue_identifier: Option<String>,
  pub allow_bypass_permissions: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectClaudeOwner {
  pub session_id: String,
  pub status: SessionStatus,
  pub lifecycle_state: SessionLifecycleState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectCodexOwner {
  pub session_id: String,
  pub status: SessionStatus,
  pub lifecycle_state: SessionLifecycleState,
}

fn resolve_custom_name_from_first_prompt(
  _conn: &Connection,
  _session_id: &str,
  custom_name: Option<String>,
  _first_prompt: Option<&str>,
) -> Result<Option<String>, rusqlite::Error> {
  Ok(custom_name)
}

fn parse_lifecycle_state(value: Option<String>) -> SessionLifecycleState {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("resumable") => SessionLifecycleState::Resumable,
    Some("ended") => SessionLifecycleState::Ended,
    _ => SessionLifecycleState::Open,
  }
}

fn parse_session_status(value: &str) -> SessionStatus {
  match value.to_ascii_lowercase().as_str() {
    "ended" => SessionStatus::Ended,
    _ => SessionStatus::Active,
  }
}

fn parse_control_mode(value: Option<String>) -> Option<SessionControlMode> {
  match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
    Some("direct") => Some(SessionControlMode::Direct),
    Some("passive") => Some(SessionControlMode::Passive),
    _ => None,
  }
}

fn control_mode_to_integration_mode(
  provider: &str,
  control_mode: SessionControlMode,
) -> (Option<String>, Option<String>) {
  match provider.to_ascii_lowercase().as_str() {
    "claude" => (
      None,
      Some(match control_mode {
        SessionControlMode::Direct => "direct".to_string(),
        SessionControlMode::Passive => "passive".to_string(),
      }),
    ),
    _ => (
      Some(match control_mode {
        SessionControlMode::Direct => "direct".to_string(),
        SessionControlMode::Passive => "passive".to_string(),
      }),
      None,
    ),
  }
}

/// Load just the persisted lifecycle state for a session.
#[cfg(test)]
#[allow(dead_code)]
pub async fn load_session_lifecycle_state(
  id: &str,
) -> Result<Option<SessionLifecycleState>, anyhow::Error> {
  load_session_lifecycle_state_with_db_path(crate::infrastructure::paths::db_path(), id).await
}

#[cfg(test)]
#[allow(dead_code)] // Shared test helper for db-path scoped lifecycle assertions.
pub async fn load_session_lifecycle_state_from_db_path(
  db_path: PathBuf,
  id: &str,
) -> Result<Option<SessionLifecycleState>, anyhow::Error> {
  load_session_lifecycle_state_with_db_path(db_path, id).await
}

#[cfg(test)]
async fn load_session_lifecycle_state_with_db_path(
  db_path: PathBuf,
  id: &str,
) -> Result<Option<SessionLifecycleState>, anyhow::Error> {
  let id_owned = id.to_string();

  tokio::task::spawn_blocking(move || -> Result<Option<SessionLifecycleState>, anyhow::Error> {
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

/// Load recent sessions from the database for server restart recovery.
/// Includes ended sessions so UI history remains visible after app restart.
pub async fn load_sessions_for_startup() -> Result<Vec<RestoredSession>, anyhow::Error> {
  load_sessions_for_startup_with_db_path(crate::infrastructure::paths::db_path()).await
}

#[cfg(test)]
#[allow(dead_code)] // Shared test helper for db-path scoped startup restoration assertions.
pub async fn load_sessions_for_startup_from_db_path(
  db_path: PathBuf,
) -> Result<Vec<RestoredSession>, anyhow::Error> {
  load_sessions_for_startup_with_db_path(db_path).await
}

async fn load_sessions_for_startup_with_db_path(
  db_path: PathBuf,
) -> Result<Vec<RestoredSession>, anyhow::Error> {
  let sessions = tokio::task::spawn_blocking(
        move || -> Result<Vec<RestoredSession>, anyhow::Error> {
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

            // Mark all active direct sessions as resumable on startup.
            // The connector process from the previous server run is gone,
            // so the user must explicitly resume each session.
            conn.execute(
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
                        COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, s.context_window, 0),
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
                let control_mode = parse_control_mode(control_mode)
                    .unwrap_or_else(|| {
                        if provider == "codex"
                            && raw_codex_integration_mode.as_deref() == Some("direct")
                        {
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
                let is_ended_history = status == "ended"
                    && !matches!(end_reason_val.as_deref(), Some("server_shutdown"));

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

                let turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)> =
                    conn.prepare(
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

                let (git_branch, git_sha, current_cwd): (
                    Option<String>,
                    Option<String>,
                    Option<String>,
                ) = conn
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
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?, row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?)),
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
                    let mode = match control_mode {
                        SessionControlMode::Direct => "direct",
                        SessionControlMode::Passive => "passive",
                    };
                    Some(mode.to_string())
                } else {
                    codex_integration_mode
                };
                let claude_integration_mode = if provider == "claude" {
                    let mode = match control_mode {
                        SessionControlMode::Direct => "direct",
                        SessionControlMode::Passive => "passive",
                    };
                    Some(mode.to_string())
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

                let end_reason = end_reason_val;

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
                            let _ = conn.execute(
                                "UPDATE sessions SET summary = ? WHERE id = ?",
                                params![extracted, id],
                            );
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
                });
            }

            Ok(sessions)
        },
    )
    .await??;

  Ok(sessions)
}

/// Load a specific session by ID (for resume — includes ended sessions).
pub async fn load_session_by_id(id: &str) -> Result<Option<RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, true).await
}

/// Load session metadata by ID without hydrating full message rows.
pub async fn load_session_metadata_by_id(
  id: &str,
) -> Result<Option<RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(crate::infrastructure::paths::db_path(), id, false).await
}

#[cfg(test)]
#[allow(dead_code)] // Shared test helper for db-path scoped session lookup assertions.
pub async fn load_session_by_id_from_db_path(
  db_path: PathBuf,
  id: &str,
) -> Result<Option<RestoredSession>, anyhow::Error> {
  load_session_by_id_with_db_path(db_path, id, true).await
}

async fn load_session_by_id_with_db_path(
  db_path: PathBuf,
  id: &str,
  include_rows: bool,
) -> Result<Option<RestoredSession>, anyhow::Error> {
  let id_owned = id.to_string();
  let result = tokio::task::spawn_blocking(
        move || -> Result<Option<RestoredSession>, anyhow::Error> {
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
                        COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, s.context_window, 0),
                        s.provider, COALESCE(s.control_mode, CASE
                            WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                            WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
                            ELSE 'passive'
                        END), s.codex_integration_mode, s.claude_integration_mode,
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
                        row.get::<_, String>(24)?,
                        row.get::<_, Option<String>>(25)?,
                        row.get::<_, Option<String>>(26)?,
                        row.get::<_, Option<String>>(27)?,
                        row.get::<_, Option<String>>(28)?,
                        row.get::<_, Option<String>>(29)?,
                        row.get::<_, String>(30)?,
                        row.get::<_, Option<String>>(31)?,
                        row.get::<_, Option<String>>(32)?,
                        row.get::<_, String>(33)?,
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
                _codex_integration_mode,
                _claude_integration_mode,
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
            let control_mode = parse_control_mode(Some(control_mode))
                .unwrap_or(SessionControlMode::Passive);
            let (codex_integration_mode, claude_integration_mode) =
                control_mode_to_integration_mode(&provider, control_mode);

            let rows = if include_rows {
                load_messages_from_db(&conn, &id)?
            } else {
                Vec::new()
            };
            let custom_name = resolve_custom_name_from_first_prompt(
                &conn,
                &id,
                custom_name,
                first_prompt.as_deref(),
            )?;

            let (current_diff, current_plan): (Option<String>, Option<String>) = conn
                .query_row(
                    "SELECT current_diff, current_plan FROM sessions WHERE id = ?1",
                    params![&id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap_or((None, None));

            let turn_diffs: Vec<(String, String, i64, i64, i64, i64, TokenUsageSnapshotKind)> =
                conn.prepare(
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

            let (git_branch, git_sha, current_cwd): (Option<String>, Option<String>, Option<String>) =
                conn.query_row(
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
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?, row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?)),
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
                forked_from_session_id: None,
                current_diff,
                current_plan,
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
        },
    )
    .await??;

  Ok(result)
}

pub async fn load_direct_claude_owner_by_sdk_session_id(
  sdk_session_id: &str,
) -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
  load_direct_claude_owner_by_sdk_session_id_with_db_path(
    crate::infrastructure::paths::db_path(),
    sdk_session_id,
  )
  .await
}

#[cfg(test)]
#[allow(dead_code)] // Shared test helper for db-path scoped direct-owner assertions.
pub async fn load_direct_claude_owner_by_sdk_session_id_from_db_path(
  db_path: PathBuf,
  sdk_session_id: &str,
) -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
  load_direct_claude_owner_by_sdk_session_id_with_db_path(db_path, sdk_session_id).await
}

async fn load_direct_claude_owner_by_sdk_session_id_with_db_path(
  db_path: PathBuf,
  sdk_session_id: &str,
) -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
  let sdk_session_id = sdk_session_id.to_string();
  tokio::task::spawn_blocking(move || -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let row = conn
            .query_row(
                "SELECT s.id,
                        s.status,
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END)
                 FROM sessions s
                 WHERE s.provider = 'claude'
                   AND s.claude_sdk_session_id = ?1
                   AND COALESCE(s.control_mode, CASE
                        WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
                        ELSE 'passive'
                   END) = 'direct'
                 ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END,
                          COALESCE(s.last_activity_at, s.started_at, '') DESC
                 LIMIT 1",
                params![sdk_session_id],
                |row| {
                    let status: String = row.get(1)?;
                    let lifecycle_state: String = row.get(2)?;
                    Ok(DirectClaudeOwner {
                        session_id: row.get(0)?,
                        status: parse_session_status(&status),
                        lifecycle_state: parse_lifecycle_state(Some(lifecycle_state)),
                    })
                },
            )
            .optional()?;

        Ok(row)
    })
    .await?
}

pub async fn load_direct_codex_owner_by_thread_id(
  thread_id: &str,
) -> Result<Option<DirectCodexOwner>, anyhow::Error> {
  load_direct_codex_owner_by_thread_id_with_db_path(
    crate::infrastructure::paths::db_path(),
    thread_id,
  )
  .await
}

#[cfg(test)]
#[allow(dead_code)] // Shared test helper for db-path scoped direct-owner assertions.
pub async fn load_direct_codex_owner_by_thread_id_from_db_path(
  db_path: PathBuf,
  thread_id: &str,
) -> Result<Option<DirectCodexOwner>, anyhow::Error> {
  load_direct_codex_owner_by_thread_id_with_db_path(db_path, thread_id).await
}

async fn load_direct_codex_owner_by_thread_id_with_db_path(
  db_path: PathBuf,
  thread_id: &str,
) -> Result<Option<DirectCodexOwner>, anyhow::Error> {
  let thread_id = thread_id.to_string();
  tokio::task::spawn_blocking(move || -> Result<Option<DirectCodexOwner>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let row = conn
            .query_row(
                "SELECT s.id,
                        s.status,
                        COALESCE(s.lifecycle_state, CASE WHEN s.status = 'ended' THEN 'ended' ELSE 'open' END)
                 FROM sessions s
                 WHERE s.provider = 'codex'
                   AND s.codex_thread_id = ?1
                   AND COALESCE(s.control_mode, CASE
                        WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
                        ELSE 'passive'
                   END) = 'direct'
                 ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END,
                          COALESCE(s.last_activity_at, s.started_at, '') DESC
                 LIMIT 1",
                params![thread_id],
                |row| {
                    let status: String = row.get(1)?;
                    let lifecycle_state: String = row.get(2)?;
                    Ok(DirectCodexOwner {
                        session_id: row.get(0)?,
                        status: parse_session_status(&status),
                        lifecycle_state: parse_lifecycle_state(Some(lifecycle_state)),
                    })
                },
            )
            .optional()?;

        Ok(row)
    })
    .await?
}

/// Load only the persisted Claude permission_mode for a session.
pub async fn load_session_permission_mode(id: &str) -> Result<Option<String>, anyhow::Error> {
  let db_path = crate::infrastructure::paths::db_path();
  let id_owned = id.to_string();

  let mode = tokio::task::spawn_blocking(move || -> Result<Option<String>, anyhow::Error> {
    if !db_path.exists() {
      return Ok(None);
    }

    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )?;

    let mode = conn
      .query_row(
        "SELECT permission_mode FROM sessions WHERE id = ?1",
        params![&id_owned],
        |row| row.get::<_, Option<String>>(0),
      )
      .optional()?
      .flatten();

    Ok(mode)
  })
  .await??;

  Ok(mode)
}
