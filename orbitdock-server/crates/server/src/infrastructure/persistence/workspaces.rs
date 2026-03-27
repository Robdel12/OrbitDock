use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use orbitdock_protocol::WorkspaceProviderKind;

use crate::support::session_time::chrono_now;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceRecord {
  pub id: String,
  pub provider: WorkspaceProviderKind,
  pub external_id: Option<String>,
  pub status: String,
  pub last_heartbeat_at: Option<String>,
  pub created_at: String,
  pub destroyed_at: Option<String>,
}

pub(crate) struct WorkspaceRecordInsert<'a> {
  pub id: &'a str,
  pub mission_issue_id: &'a str,
  pub session_id: Option<&'a str>,
  pub provider: WorkspaceProviderKind,
  pub repo_url: &'a str,
  pub branch: &'a str,
  pub sync_token: &'a str,
}

pub(crate) fn insert_workspace_record(
  conn: &Connection,
  insert: &WorkspaceRecordInsert<'_>,
) -> Result<()> {
  conn
    .execute(
      "INSERT INTO workspaces (
         id, mission_issue_id, session_id, provider, repo_url, branch, status, sync_token
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'creating', ?7)",
      params![
        insert.id,
        insert.mission_issue_id,
        insert.session_id,
        insert.provider.as_str(),
        insert.repo_url,
        insert.branch,
        insert.sync_token,
      ],
    )
    .with_context(|| format!("insert workspace record {}", insert.id))?;

  Ok(())
}

pub(crate) fn load_workspace_record(
  conn: &Connection,
  workspace_id: &str,
) -> Result<Option<WorkspaceRecord>> {
  let mut stmt = conn
    .prepare(
      "SELECT id, provider, external_id, status, last_heartbeat_at, created_at, destroyed_at
         FROM workspaces
         WHERE id = ?1",
    )
    .with_context(|| format!("prepare workspace lookup for {workspace_id}"))?;

  let row = stmt
    .query_row(params![workspace_id], |row| {
      Ok(WorkspaceRecord {
        id: row.get(0)?,
        provider: row.get::<_, String>(1)?.parse().map_err(|error| {
          rusqlite::Error::FromSqlConversionFailure(
            1,
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, error)),
          )
        })?,
        external_id: row.get(2)?,
        status: row.get(3)?,
        last_heartbeat_at: row.get(4)?,
        created_at: row.get(5)?,
        destroyed_at: row.get(6)?,
      })
    })
    .optional()
    .with_context(|| format!("load workspace record {workspace_id}"))?;

  Ok(row)
}

pub(crate) struct WorkspaceRecordUpdate<'a> {
  pub id: &'a str,
  pub external_id: Option<&'a str>,
  pub status: &'a str,
  pub connection_info: Option<&'a Value>,
  pub ready: bool,
  pub destroyed: bool,
}

pub(crate) fn update_workspace_record(
  conn: &Connection,
  update: &WorkspaceRecordUpdate<'_>,
) -> Result<()> {
  let connection_info = update
    .connection_info
    .map(serde_json::to_string)
    .transpose()
    .context("serialize workspace connection_info")?;

  conn
    .execute(
      "UPDATE workspaces
         SET external_id = COALESCE(?2, external_id),
             status = ?3,
             connection_info = COALESCE(?4, connection_info),
             ready_at = CASE WHEN ?5 THEN ?6 ELSE ready_at END,
             destroyed_at = CASE WHEN ?7 THEN ?8 ELSE destroyed_at END
         WHERE id = ?1",
      params![
        update.id,
        update.external_id,
        update.status,
        connection_info,
        update.ready,
        chrono_now(),
        update.destroyed,
        chrono_now(),
      ],
    )
    .with_context(|| format!("update workspace record {}", update.id))?;

  Ok(())
}
