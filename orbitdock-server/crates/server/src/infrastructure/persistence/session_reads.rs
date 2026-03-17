use rusqlite::{params, Connection, OptionalExtension};

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::TokenUsageSnapshotKind;

use super::chrono_now;
use super::messages::{load_latest_completed_conversation_message_from_db, load_messages_from_db};
use super::transcripts::{extract_summary_from_transcript, load_messages_from_transcript};
use super::usage::snapshot_kind_from_str;

type StoredCodexConfigRow = (
    Option<String>,
    Option<bool>,
    Option<String>,
    Option<String>,
    Option<String>,
);

/// A session restored from the database on startup.
#[derive(Debug)]
pub struct RestoredSession {
    pub id: String,
    pub provider: String,
    pub status: String,
    pub work_status: String,
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
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
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
}

fn resolve_custom_name_from_first_prompt(
    _conn: &Connection,
    _session_id: &str,
    custom_name: Option<String>,
    _first_prompt: Option<&str>,
) -> Result<Option<String>, rusqlite::Error> {
    Ok(custom_name)
}

/// Load recent sessions from the database for server restart recovery.
/// Includes ended sessions so UI history remains visible after app restart.
pub async fn load_sessions_for_startup() -> Result<Vec<RestoredSession>, anyhow::Error> {
    let db_path = crate::infrastructure::paths::db_path();

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
                     end_reason = COALESCE(end_reason, 'startup_stale_passive')
                 WHERE provider = 'codex'
                   AND codex_integration_mode = 'passive'
                   AND status = 'active'
                   AND COALESCE(work_status, 'waiting') NOT IN ('permission', 'question')
                   AND datetime(COALESCE(last_activity_at, started_at)) < datetime('now', '-15 minutes')",
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
                     OR (provider = 'codex' AND codex_integration_mode = 'direct'))",
                [],
            )?;

            conn.execute(
                "UPDATE sessions
                 SET status = 'active',
                     work_status = 'reply',
                     ended_at = NULL,
                     end_reason = NULL
                 WHERE provider = 'claude'
                   AND claude_integration_mode = 'direct'
                   AND status = 'ended'
                   AND end_reason = 'server_shutdown'",
                [],
            )?;

            let mut stmt = conn.prepare(
                "SELECT s.id, s.provider, s.status, s.work_status, s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.codex_integration_mode, s.codex_thread_id, s.started_at, s.last_activity_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                        s.pending_tool_name, s.pending_tool_input, s.pending_question,
                        COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, s.context_window, 0),
                        COALESCE(uss.snapshot_kind, 'unknown')
                 FROM sessions s
                 LEFT JOIN usage_session_state uss ON uss.session_id = s.id
                 WHERE s.status = 'active'
                    OR (s.status = 'ended' AND s.end_reason = 'server_shutdown')
                 ORDER BY
                   datetime(s.last_activity_at) DESC,
                   datetime(s.started_at) DESC",
            )?;

            #[allow(clippy::type_complexity)]
            let session_rows: Vec<(
                String,
                String,
                String,
                String,
                String,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                Option<String>,
                i64,
                i64,
                i64,
                i64,
                String,
            )> = stmt
                .query_map([], |row| {
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
                        row.get(10)?,
                        row.get(11)?,
                        row.get(12)?,
                        row.get(13)?,
                        row.get(14)?,
                        row.get(15)?,
                        row.get(16)?,
                        row.get(17)?,
                        row.get(18)?,
                        row.get(19)?,
                        row.get(20)?,
                        row.get(21)?,
                        row.get(22)?,
                        row.get(23)?,
                        row.get(24)?,
                        row.get(25)?,
                    ))
                })?
                .filter_map(|row| row.ok())
                .collect();

            let mut sessions = Vec::new();

            for (
                id,
                provider,
                status,
                work_status,
                project_path,
                transcript_path,
                project_name,
                model,
                custom_name,
                first_prompt,
                _summary,
                codex_integration_mode,
                codex_thread_id,
                started_at,
                last_activity_at,
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
            ) in session_rows
            {
                let token_usage_snapshot_kind =
                    snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));

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

                let claude_integration_mode: Option<String> = conn
                    .query_row(
                        "SELECT claude_integration_mode FROM sessions WHERE id = ?1",
                        params![id],
                        |row| row.get(0),
                    )
                    .unwrap_or(None);

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
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions,
                ): StoredCodexConfigRow = conn
                    .query_row(
                        "SELECT collaboration_mode, multi_agent, personality, service_tier, developer_instructions FROM sessions WHERE id = ?1",
                        params![id],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
                    )
                    .unwrap_or((None, None, None, None, None));

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
                    approval_policy,
                    sandbox_mode,
                    permission_mode,
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions,
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
    let db_path = crate::infrastructure::paths::db_path();
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
                "SELECT s.id, s.project_path, s.transcript_path, s.project_name, s.model, s.custom_name, s.first_prompt, s.summary, s.started_at, s.last_activity_at, s.approval_policy, s.sandbox_mode, s.permission_mode,
                        s.pending_tool_name, s.pending_tool_input, s.pending_question,
                        COALESCE(uss.snapshot_input_tokens, s.input_tokens, 0),
                        COALESCE(uss.snapshot_output_tokens, s.output_tokens, 0),
                        COALESCE(uss.snapshot_cached_tokens, s.cached_tokens, 0),
                        COALESCE(uss.snapshot_context_window, s.context_window, 0),
                        s.provider, s.codex_integration_mode, s.claude_integration_mode,
                        s.claude_sdk_session_id, s.codex_thread_id, s.end_reason,
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
                        row.get::<_, Option<String>>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, Option<String>>(10)?,
                        row.get::<_, Option<String>>(11)?,
                        row.get::<_, Option<String>>(12)?,
                        row.get::<_, Option<String>>(13)?,
                        row.get::<_, Option<String>>(14)?,
                        row.get::<_, Option<String>>(15)?,
                        row.get::<_, i64>(16)?,
                        row.get::<_, i64>(17)?,
                        row.get::<_, i64>(18)?,
                        row.get::<_, i64>(19)?,
                        row.get::<_, String>(20)?,
                        row.get::<_, Option<String>>(21)?,
                        row.get::<_, Option<String>>(22)?,
                        row.get::<_, Option<String>>(23)?,
                        row.get::<_, Option<String>>(24)?,
                        row.get::<_, Option<String>>(25)?,
                        row.get::<_, Option<String>>(26)?,
                        row.get::<_, Option<String>>(27)?,
                        row.get::<_, String>(28)?,
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
                started_at,
                last_activity_at,
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
                codex_integration_mode,
                claude_integration_mode,
                claude_sdk_session_id,
                codex_thread_id,
                end_reason,
                terminal_session_id,
                terminal_app,
                token_usage_snapshot_kind_str,
            )) = row
            else {
                return Ok(None);
            };

            let token_usage_snapshot_kind =
                snapshot_kind_from_str(Some(token_usage_snapshot_kind_str.as_str()));

            let rows = load_messages_from_db(&conn, &id)?;
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
            let last_message = load_latest_completed_conversation_message_from_db(&conn, &id)
                .unwrap_or(None)
                .or(persisted_last_message);

            let effort: Option<String> = conn
                .query_row(
                    "SELECT effort FROM sessions WHERE id = ?1",
                    params![&id],
                    |row| row.get(0),
                )
                .unwrap_or(None);

            let (
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
            ): StoredCodexConfigRow = conn
                .query_row(
                    "SELECT collaboration_mode, multi_agent, personality, service_tier, developer_instructions FROM sessions WHERE id = ?1",
                    params![&id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
                )
                .unwrap_or((None, None, None, None, None));

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

            Ok(Some(RestoredSession {
                id,
                provider,
                status: "active".to_string(),
                work_status: "waiting".to_string(),
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
                approval_policy,
                sandbox_mode,
                permission_mode,
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
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
            }))
        },
    )
    .await??;

    Ok(result)
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
