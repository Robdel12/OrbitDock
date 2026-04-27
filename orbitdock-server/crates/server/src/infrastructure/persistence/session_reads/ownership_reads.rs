use std::path::PathBuf;

use rusqlite::{params, Connection, OptionalExtension};

use super::{parse_lifecycle_state, parse_session_status, DirectClaudeOwner, DirectCodexOwner};

pub async fn load_direct_claude_owner_by_sdk_session_id(
  sdk_session_id: &str,
) -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
  load_direct_claude_owner_by_sdk_session_id_with_db_path(
    crate::infrastructure::paths::db_path(),
    sdk_session_id,
  )
  .await
}

async fn load_direct_claude_owner_by_sdk_session_id_with_db_path(
  db_path: PathBuf,
  sdk_session_id: &str,
) -> Result<Option<DirectClaudeOwner>, anyhow::Error> {
  let sdk_session_id = sdk_session_id.to_string();
  tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
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

async fn load_direct_codex_owner_by_thread_id_with_db_path(
  db_path: PathBuf,
  thread_id: &str,
) -> Result<Option<DirectCodexOwner>, anyhow::Error> {
  let thread_id = thread_id.to_string();
  tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
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

pub async fn load_session_permission_mode(id: &str) -> Result<Option<String>, anyhow::Error> {
  let db_path = crate::infrastructure::paths::db_path();
  let id_owned = id.to_string();

  let mode = tokio::task::spawn_blocking(move || -> Result<_, anyhow::Error> {
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
