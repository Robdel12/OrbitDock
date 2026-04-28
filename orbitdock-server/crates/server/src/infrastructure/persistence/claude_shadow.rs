use rusqlite::{params, Connection};

use super::timestamps::chrono_now;

fn claude_shadow_is_owned_by_direct_session(
  conn: &Connection,
  session_id: &str,
) -> Result<bool, rusqlite::Error> {
  let exists: i64 = conn.query_row(
    "SELECT EXISTS(
            SELECT 1
            FROM sessions direct
            WHERE direct.provider = 'claude'
              AND direct.claude_sdk_session_id = ?1
              AND COALESCE(direct.control_mode, CASE
                    WHEN direct.provider = 'claude'
                         AND direct.claude_integration_mode = 'direct'
                        THEN 'direct'
                    ELSE 'passive'
                  END) = 'direct'
        )",
    params![session_id],
    |row| row.get(0),
  )?;

  Ok(exists == 1)
}

pub(crate) fn preserve_direct_owned_claude_shadow(
  conn: &Connection,
  session_id: &str,
  reason: &str,
) -> Result<bool, rusqlite::Error> {
  if !claude_shadow_is_owned_by_direct_session(conn, session_id)? {
    return Ok(false);
  }

  let now = chrono_now();
  conn.execute(
    "UPDATE sessions
             SET status = 'ended',
                 work_status = 'ended',
                 lifecycle_state = 'ended',
                 ended_at = COALESCE(ended_at, ?1),
                 end_reason = COALESCE(end_reason, ?2),
                 attention_reason = 'none',
                 pending_tool_name = NULL,
                 pending_tool_input = NULL,
                 pending_question = NULL,
                 pending_approval_id = NULL,
                 active_subagent_id = NULL,
                 active_subagent_type = NULL
             WHERE id = ?3
               AND provider = 'claude'
               AND (claude_integration_mode IS NULL OR claude_integration_mode != 'direct')",
    params![now, reason, session_id],
  )?;

  Ok(true)
}
