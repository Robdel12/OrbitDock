use super::*;

/// Load subagents for a session (for snapshot building)
pub async fn load_subagents_for_session(
    session_id: &str,
) -> Result<Vec<orbitdock_protocol::SubagentInfo>, anyhow::Error> {
    let session_id = session_id.to_string();
    let db_path = crate::infrastructure::paths::db_path();

    let subagents = tokio::task::spawn_blocking(
        move || -> Result<Vec<orbitdock_protocol::SubagentInfo>, anyhow::Error> {
            if !db_path.exists() {
                return Ok(Vec::new());
            }
            let conn = Connection::open(&db_path)?;
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA busy_timeout = 5000;",
            )?;

            let table_exists: i64 = conn.query_row(
                "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'subagents'",
                [],
                |row| row.get(0),
            )?;
            if table_exists == 0 {
                return Ok(Vec::new());
            }

            let mut stmt = conn.prepare(
                "SELECT id, agent_type, started_at, ended_at FROM subagents WHERE session_id = ?1 ORDER BY started_at",
            )?;
            let rows = stmt.query_map(params![session_id], |row| {
                Ok(orbitdock_protocol::SubagentInfo {
                    id: row.get(0)?,
                    agent_type: row.get(1)?,
                    started_at: row.get(2)?,
                    ended_at: row.get(3)?,
                })
            })?;

            let mut subagents = Vec::new();
            for row in rows {
                subagents.push(row?);
            }
            Ok(subagents)
        },
    )
    .await??;

    Ok(subagents)
}

/// Load the transcript path for a specific subagent
pub async fn load_subagent_transcript_path(
    subagent_id: &str,
) -> Result<Option<String>, anyhow::Error> {
    let subagent_id = subagent_id.to_string();
    let db_path = crate::infrastructure::paths::db_path();

    let path = tokio::task::spawn_blocking(move || -> Result<Option<String>, anyhow::Error> {
        if !db_path.exists() {
            return Ok(None);
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )?;

        let table_exists: i64 = conn.query_row(
            "SELECT COUNT(1) FROM sqlite_master WHERE type = 'table' AND name = 'subagents'",
            [],
            |row| row.get(0),
        )?;
        if table_exists == 0 {
            return Ok(None);
        }

        let path: Option<String> = conn
            .query_row(
                "SELECT transcript_path FROM subagents WHERE id = ?1",
                params![subagent_id],
                |row| {
                    let val: Option<String> = row.get(0)?;
                    Ok(val)
                },
            )
            .optional()?
            .flatten();

        Ok(path)
    })
    .await??;

    Ok(path)
}
