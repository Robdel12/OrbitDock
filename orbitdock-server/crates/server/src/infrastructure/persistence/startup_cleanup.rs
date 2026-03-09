use rusqlite::{params, Connection};
use tracing::info;

use super::chrono_now;

/// Clean up sessions where the DB has stale awaitingPermission/awaitingQuestion state
/// but the work_status has already moved on (e.g. Claude process crashed without a Stop hook).
///
/// This runs at server startup to repair any sessions left in an inconsistent state
/// from a previous run.
pub async fn cleanup_stale_permission_state() -> Result<u64, anyhow::Error> {
    let db_path = crate::infrastructure::paths::db_path();

    let (moved_on_count, orphaned_permission_count, orphaned_approval_count) =
        tokio::task::spawn_blocking(move || -> Result<(u64, u64, u64), anyhow::Error> {
            if !db_path.exists() {
                return Ok((0, 0, 0));
            }

            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
            )?;

            let now = chrono_now();

            let moved_on_rows = conn.execute(
                "UPDATE sessions
                 SET pending_tool_name = NULL,
                     pending_tool_input = NULL,
                     pending_question = NULL,
                     pending_approval_id = NULL,
                     attention_reason = CASE
                         WHEN attention_reason IN ('awaitingPermission', 'awaitingQuestion') THEN 'awaitingReply'
                         ELSE attention_reason
                     END
                 WHERE status = 'active'
                   AND work_status NOT IN ('permission', 'question')
                   AND (
                       pending_tool_name IS NOT NULL
                       OR pending_question IS NOT NULL
                       OR attention_reason IN ('awaitingPermission', 'awaitingQuestion')
                   )",
                [],
            )?;

            let orphaned_approval_rows = conn.execute(
                "UPDATE approval_history
                 SET decision = 'abort',
                     decided_at = COALESCE(decided_at, ?1)
                 WHERE decision IS NULL
                   AND session_id IN (
                       SELECT id
                       FROM sessions
                       WHERE status = 'active'
                         AND work_status IN ('permission', 'question')
                         AND pending_approval_id IS NULL
                         AND pending_tool_name IS NULL
                         AND pending_tool_input IS NULL
                         AND pending_question IS NULL
                   )",
                params![now],
            )?;

            let orphaned_permission_rows = conn.execute(
                "UPDATE sessions
                 SET work_status = 'waiting',
                     attention_reason = 'awaitingReply',
                     pending_tool_name = NULL,
                     pending_tool_input = NULL,
                     pending_question = NULL,
                     pending_approval_id = NULL
                 WHERE status = 'active'
                   AND work_status IN ('permission', 'question')
                   AND pending_approval_id IS NULL
                   AND pending_tool_name IS NULL
                   AND pending_tool_input IS NULL
                   AND pending_question IS NULL",
                [],
            )?;

            Ok((
                moved_on_rows as u64,
                orphaned_permission_rows as u64,
                orphaned_approval_rows as u64,
            ))
        })
        .await??;

    let count = moved_on_count + orphaned_permission_count;
    if count > 0 {
        info!(
            component = "startup",
            event = "startup.stale_permission_cleanup",
            sessions_fixed = count,
            moved_on_sessions_fixed = moved_on_count,
            orphaned_permission_sessions_fixed = orphaned_permission_count,
            orphaned_approval_rows_aborted = orphaned_approval_count,
            "Cleared stale pending permission/question state from prior crash"
        );
    }

    Ok(count)
}

/// Clean up tool messages stuck with is_in_progress = 1 from sessions that are no longer working.
/// This handles the case where the server crashed or restarted while tools were mid-execution.
///
/// Runs at server startup alongside `cleanup_stale_permission_state`.
pub async fn cleanup_dangling_in_progress_messages() -> Result<u64, anyhow::Error> {
    let db_path = crate::infrastructure::paths::db_path();

    let count = tokio::task::spawn_blocking(move || -> Result<u64, anyhow::Error> {
        if !db_path.exists() {
            return Ok(0);
        }

        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let rows = conn.execute(
            "UPDATE messages SET is_in_progress = 0
             WHERE is_in_progress = 1
               AND session_id IN (SELECT id FROM sessions WHERE work_status != 'working')",
            [],
        )?;

        Ok(rows as u64)
    })
    .await??;

    if count > 0 {
        info!(
            component = "startup",
            event = "startup.dangling_in_progress_cleanup",
            messages_fixed = count,
            "Cleared dangling is_in_progress tool messages from prior crash"
        );
    }

    Ok(count)
}
