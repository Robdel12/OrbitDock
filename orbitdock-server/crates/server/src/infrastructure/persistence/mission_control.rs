//! Mission Control persistence: read queries.
//!
//! Write operations use PersistCommand variants dispatched through the
//! batched PersistenceWriter — this file provides synchronous read helpers.

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};

/// A mission row loaded from the database.
#[derive(Debug, Clone)]
pub struct MissionRow {
  pub id: String,
  pub name: String,
  pub repo_root: String,
  pub tracker_kind: String,
  pub provider: String,
  pub config_json: Option<String>,
  pub prompt_template: Option<String>,
  pub enabled: bool,
  pub paused: bool,
  pub parse_error: Option<String>,
  pub mission_file_path: Option<String>,
}

impl MissionRow {
  /// Resolve the full path to the mission file (MISSION.md or custom path).
  pub fn resolved_mission_path(&self) -> std::path::PathBuf {
    let file_name = self
      .mission_file_path
      .as_deref()
      .filter(|p| !p.is_empty())
      .unwrap_or("MISSION.md");
    std::path::Path::new(&self.repo_root).join(file_name)
  }

  /// Map a row whose SELECT list matches the 11-column missions projection.
  pub fn from_row(row: &rusqlite::Row) -> rusqlite::Result<Self> {
    Ok(Self {
      id: row.get(0)?,
      name: row.get(1)?,
      repo_root: row.get(2)?,
      tracker_kind: row.get(3)?,
      provider: row.get(4)?,
      config_json: row.get(5)?,
      prompt_template: row.get(6)?,
      enabled: row.get::<_, i64>(7)? != 0,
      paused: row.get::<_, i64>(8)? != 0,
      parse_error: row.get(9)?,
      mission_file_path: row.get(10)?,
    })
  }
}

/// A mission issue row loaded from the database.
#[derive(Debug, Clone)]
pub struct MissionIssueRow {
  pub issue_id: String,
  pub issue_identifier: String,
  pub issue_title: Option<String>,
  pub issue_state: Option<String>,
  pub orchestration_state: String,
  pub session_id: Option<String>,
  pub provider: Option<String>,
  pub attempt: u32,
  pub last_error: Option<String>,
  pub started_at: Option<String>,
  pub completed_at: Option<String>,
  pub url: Option<String>,
  pub workspace_id: Option<String>,
  pub created_at: String,
  pub pr_url: Option<String>,
}

/// Minimal mission-linked worktree row used for cleanup UX summaries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissionCleanupCandidateRow {
  pub worktree_id: String,
  pub worktree_path: String,
}

impl MissionIssueRow {
  /// Map a row whose SELECT list matches the 15-column mission_issues projection.
  pub fn from_row(row: &rusqlite::Row) -> rusqlite::Result<Self> {
    Ok(Self {
      issue_id: row.get(0)?,
      issue_identifier: row.get(1)?,
      issue_title: row.get(2)?,
      issue_state: row.get(3)?,
      orchestration_state: row.get(4)?,
      session_id: row.get(5)?,
      provider: row.get(6)?,
      attempt: row.get::<_, u32>(7)?,
      last_error: row.get(8)?,
      started_at: row.get(9)?,
      completed_at: row.get(10)?,
      url: row.get(11)?,
      workspace_id: row.get(12)?,
      created_at: row.get(13)?,
      pr_url: row.get(14)?,
    })
  }
}

pub fn load_missions(conn: &Connection) -> Result<Vec<MissionRow>> {
  let mut stmt = conn
    .prepare(
      "SELECT id, name, repo_root, tracker_kind, provider, config_json, prompt_template,
                    enabled, paused, parse_error, mission_file_path
             FROM missions
             ORDER BY created_at DESC",
    )
    .context("prepare load_missions")?;

  let rows = stmt
    .query_map([], MissionRow::from_row)
    .context("query load_missions")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

/// (active, queued, completed, failed) counts for a mission.
pub type MissionIssueCounts = (u32, u32, u32, u32);

pub fn load_missions_with_counts(
  conn: &Connection,
) -> Result<Vec<(MissionRow, MissionIssueCounts)>> {
  let mut stmt = conn
        .prepare(
            "SELECT m.id, m.name, m.repo_root, m.tracker_kind, m.provider, m.config_json,
                    m.prompt_template, m.enabled, m.paused, m.parse_error,
                    m.mission_file_path,
                    COUNT(CASE WHEN mi.orchestration_state IN ('running','claimed','provisioning') THEN 1 END),
                    COUNT(CASE WHEN mi.orchestration_state IN ('queued','retry_queued') THEN 1 END),
                    COUNT(CASE WHEN mi.orchestration_state = 'completed' THEN 1 END),
                    COUNT(CASE WHEN mi.orchestration_state = 'failed' THEN 1 END)
             FROM missions m
             LEFT JOIN mission_issues mi ON mi.mission_id = m.id
             GROUP BY m.id
             ORDER BY m.created_at DESC",
        )
        .context("prepare load_missions_with_counts")?;

  let rows = stmt
    .query_map([], |row| {
      let mission = MissionRow::from_row(row)?;
      let active: u32 = row.get::<_, Option<u32>>(11)?.unwrap_or(0);
      let queued: u32 = row.get::<_, Option<u32>>(12)?.unwrap_or(0);
      let completed: u32 = row.get::<_, Option<u32>>(13)?.unwrap_or(0);
      let failed: u32 = row.get::<_, Option<u32>>(14)?.unwrap_or(0);
      Ok((mission, (active, queued, completed, failed)))
    })
    .context("query load_missions_with_counts")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

pub fn load_mission_by_id(conn: &Connection, id: &str) -> Result<Option<MissionRow>> {
  let row = conn
    .query_row(
      "SELECT id, name, repo_root, tracker_kind, provider, config_json, prompt_template,
                    enabled, paused, parse_error, mission_file_path
             FROM missions WHERE id = ?1",
      params![id],
      MissionRow::from_row,
    )
    .optional()
    .context("query load_mission_by_id")?;

  Ok(row)
}

/// Load just the tracker API key for a mission (synchronous, for credential resolution).
pub fn load_mission_tracker_key(mission_id: &str) -> Option<String> {
  let db_path = crate::infrastructure::paths::db_path();
  if !db_path.exists() {
    return None;
  }

  let conn = Connection::open(&db_path).ok()?;
  conn
    .execute_batch(
      "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )
    .ok()?;

  let raw: Option<String> = conn
    .query_row(
      "SELECT tracker_api_key FROM missions WHERE id = ?1",
      params![mission_id],
      |row| row.get(0),
    )
    .optional()
    .ok()
    .flatten()?;

  raw.and_then(|v| crate::infrastructure::crypto::decrypt(&v))
}

/// Count how many missions share the same repo root directory.
pub fn count_missions_by_repo_root(conn: &Connection, repo_root: &str) -> Result<i64> {
  let count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM missions WHERE repo_root = ?1",
      params![repo_root],
      |row| row.get(0),
    )
    .context("count_missions_by_repo_root")?;
  Ok(count)
}

pub fn load_mission_issues(conn: &Connection, mission_id: &str) -> Result<Vec<MissionIssueRow>> {
  let mut stmt = conn
    .prepare(
      "SELECT issue_id, issue_identifier, issue_title, issue_state,
                    orchestration_state, session_id, provider, attempt, last_error,
                    started_at, completed_at, url, workspace_id, created_at, pr_url
             FROM mission_issues
             WHERE mission_id = ?1
             ORDER BY created_at ASC",
    )
    .context("prepare load_mission_issues")?;

  let rows = stmt
    .query_map(params![mission_id], MissionIssueRow::from_row)
    .context("query load_mission_issues")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

pub fn load_mission_cleanup_candidates(
  conn: &Connection,
  mission_id: &str,
) -> Result<Vec<MissionCleanupCandidateRow>> {
  let mut stmt = conn
    .prepare(
      "SELECT DISTINCT
                w.id,
                w.worktree_path
             FROM mission_issues mi
             JOIN sessions s ON s.id = mi.session_id
             JOIN worktrees w ON (
                (s.worktree_id IS NOT NULL AND s.worktree_id != '' AND w.id = s.worktree_id)
                OR
                (COALESCE(s.worktree_id, '') = '' AND w.worktree_path = s.project_path)
             )
             WHERE mi.mission_id = ?1
               AND mi.orchestration_state IN ('completed', 'failed', 'blocked')
               AND w.status != 'removed'
             ORDER BY mi.created_at ASC",
    )
    .context("prepare load_mission_cleanup_candidates")?;

  let rows = stmt
    .query_map(params![mission_id], |row| {
      Ok(MissionCleanupCandidateRow {
        worktree_id: row.get(0)?,
        worktree_path: row.get(1)?,
      })
    })
    .context("query load_mission_cleanup_candidates")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

/// Load retry-ready issues: state = 'retry_queued', retry_due_at <= now, attempt <= max_retries.
pub fn load_retry_ready_issues(
  conn: &Connection,
  mission_id: &str,
  now: &str,
  max_retries: u32,
) -> Result<Vec<MissionIssueRow>> {
  let mut stmt = conn
    .prepare(
      "SELECT issue_id, issue_identifier, issue_title, issue_state,
                    orchestration_state, session_id, provider, attempt, last_error,
                    started_at, completed_at, url, workspace_id, created_at, pr_url
             FROM mission_issues
             WHERE mission_id = ?1
               AND orchestration_state = 'retry_queued'
               AND retry_due_at IS NOT NULL
               AND retry_due_at <= ?2
               AND attempt <= ?3
             ORDER BY retry_due_at ASC",
    )
    .context("prepare load_retry_ready_issues")?;

  let rows = stmt
    .query_map(params![mission_id, now, max_retries], |row| {
      MissionIssueRow::from_row(row)
    })
    .context("query load_retry_ready_issues")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

/// Load manually-queued issues that weren't returned by the tracker candidate fetch.
/// These are issues an admin moved back to `queued` via the transition API.
pub fn load_manually_queued_issues(
  conn: &Connection,
  mission_id: &str,
  exclude_ids: &[String],
) -> Result<Vec<MissionIssueRow>> {
  // Build a set of placeholders for the exclusion list
  let base_query = "SELECT issue_id, issue_identifier, issue_title, issue_state,
                    orchestration_state, session_id, provider, attempt, last_error,
                    started_at, completed_at, url, workspace_id, created_at, pr_url
             FROM mission_issues
             WHERE mission_id = ?1
               AND orchestration_state = 'queued'";

  if exclude_ids.is_empty() {
    let mut stmt = conn
      .prepare(&format!("{base_query} ORDER BY created_at ASC"))
      .context("prepare load_manually_queued_issues")?;
    let rows = stmt
      .query_map(params![mission_id], MissionIssueRow::from_row)
      .context("query load_manually_queued_issues")?
      .filter_map(|r| r.ok())
      .collect();
    return Ok(rows);
  }

  let placeholders: Vec<String> = (0..exclude_ids.len())
    .map(|i| format!("?{}", i + 2))
    .collect();
  let full_query = format!(
    "{base_query} AND issue_id NOT IN ({}) ORDER BY created_at ASC",
    placeholders.join(", ")
  );

  let mut stmt = conn
    .prepare(&full_query)
    .context("prepare load_manually_queued_issues")?;

  let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(mission_id.to_string())];
  for id in exclude_ids {
    params.push(Box::new(id.clone()));
  }

  let rows = stmt
    .query_map(
      rusqlite::params_from_iter(params.iter().map(|p| p.as_ref())),
      MissionIssueRow::from_row,
    )
    .context("query load_manually_queued_issues")?
    .filter_map(|r| r.ok())
    .collect();

  Ok(rows)
}

/// Fields to update on a mission issue's orchestration state.
/// `None` means "don't touch this field"; `Some(None)` (for nullable fields) means "set to NULL".
pub struct MissionIssueStateUpdate<'a> {
  pub orchestration_state: &'a str,
  pub session_id: Option<&'a str>,
  pub workspace_id: Option<&'a str>,
  pub attempt: Option<u32>,
  pub last_error: Option<Option<&'a str>>,
  pub started_at: Option<Option<&'a str>>,
  pub completed_at: Option<Option<&'a str>>,
}

/// Synchronously update a mission issue's orchestration state and optional fields.
/// Used by dispatch paths that need the write to be visible before broadcasting.
pub fn update_mission_issue_state_sync(
  conn: &Connection,
  mission_id: &str,
  issue_id: &str,
  update: &MissionIssueStateUpdate<'_>,
) -> Result<()> {
  let MissionIssueStateUpdate {
    orchestration_state,
    session_id,
    workspace_id,
    attempt,
    last_error,
    started_at,
    completed_at,
  } = update;

  let mut set_parts = vec![String::from("orchestration_state = ?1")];
  let mut values: Vec<Box<dyn rusqlite::types::ToSql>> =
    vec![Box::new(orchestration_state.to_string())];
  let mut idx: usize = 2;

  macro_rules! push_field {
    ($field:expr, $val:expr) => {{
      set_parts.push(format!("{} = ?{}", $field, idx));
      values.push(Box::new($val));
      idx += 1;
    }};
  }

  if let Some(sid) = session_id {
    push_field!("session_id", sid.to_string());
  }
  if let Some(wid) = workspace_id {
    push_field!("workspace_id", wid.to_string());
  }
  if let Some(a) = attempt {
    push_field!("attempt", *a);
  }
  if let Some(err) = last_error {
    push_field!("last_error", err.map(|s| s.to_string()));
  }
  if let Some(sa) = started_at {
    push_field!("started_at", sa.map(|s| s.to_string()));
  }
  if let Some(ca) = completed_at {
    push_field!("completed_at", ca.map(|s| s.to_string()));
  }

  set_parts.push(String::from(
    "updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
  ));
  values.push(Box::new(mission_id.to_string()));
  values.push(Box::new(issue_id.to_string()));

  let sql = format!(
    "UPDATE mission_issues SET {} WHERE mission_id = ?{} AND issue_id = ?{}",
    set_parts.join(", "),
    idx,
    idx + 1,
  );

  let params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(|v| v.as_ref()).collect();
  conn
    .execute(&sql, params.as_slice())
    .context("update mission_issue_state")?;

  Ok(())
}

#[cfg(test)]
#[path = "mission_control_tests.rs"]
mod tests;
