use super::*;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct WorktreeRow {
  pub id: String,
  pub repo_root: String,
  pub worktree_path: String,
  pub branch: String,
  pub base_branch: Option<String>,
  pub status: String,
  pub created_at: String,
  pub last_session_ended_at: Option<String>,
  pub auto_prune: bool,
  pub custom_name: Option<String>,
  pub created_by: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorktreeSessionStats {
  pub active_session_count: u32,
  pub total_session_count: u32,
  pub last_session_ended_at: Option<String>,
}

pub fn load_worktree_by_id(db_path: &PathBuf, worktree_id: &str) -> Option<WorktreeRow> {
  let conn = open_readonly_conn(db_path)?;
  conn
    .query_row(
      "SELECT id, repo_root, worktree_path, branch, base_branch, status,
                created_at, last_session_ended_at, auto_prune, custom_name, created_by
         FROM worktrees WHERE id = ?1",
      params![worktree_id],
      decode_worktree_row,
    )
    .optional()
    .ok()
    .flatten()
}

pub fn load_worktrees_by_repo(db_path: &PathBuf, repo_root: &str) -> Vec<WorktreeRow> {
  let Some(conn) = open_readonly_conn(db_path) else {
    return Vec::new();
  };
  let mut stmt = match conn.prepare(
    "SELECT id, repo_root, worktree_path, branch, base_branch, status,
                created_at, last_session_ended_at, auto_prune, custom_name, created_by
         FROM worktrees WHERE repo_root = ?1 AND status != 'removed'",
  ) {
    Ok(statement) => statement,
    Err(_) => return Vec::new(),
  };
  stmt
    .query_map(params![repo_root], decode_worktree_row)
    .ok()
    .map(|rows| rows.filter_map(|row| row.ok()).collect())
    .unwrap_or_default()
}

pub fn load_all_worktrees(db_path: &PathBuf) -> Vec<WorktreeRow> {
  let Some(conn) = open_readonly_conn(db_path) else {
    return Vec::new();
  };
  let mut stmt = match conn.prepare(
    "SELECT id, repo_root, worktree_path, branch, base_branch, status,
                created_at, last_session_ended_at, auto_prune, custom_name, created_by
         FROM worktrees WHERE status != 'removed'",
  ) {
    Ok(statement) => statement,
    Err(_) => return Vec::new(),
  };
  stmt
    .query_map([], decode_worktree_row)
    .ok()
    .map(|rows| rows.filter_map(|row| row.ok()).collect())
    .unwrap_or_default()
}

pub fn load_worktree_session_stats(
  db_path: &PathBuf,
  repo_root: Option<&str>,
) -> HashMap<String, WorktreeSessionStats> {
  let Some(conn) = open_readonly_conn(db_path) else {
    return HashMap::new();
  };

  if let Some(repo_root) = repo_root {
    load_worktree_session_stats_with_params(
      &conn,
      "SELECT w.id,
              COUNT(s.id) AS total_session_count,
              SUM(
                CASE
                  WHEN s.status = 'active' AND COALESCE(s.lifecycle_state, 'open') != 'ended' THEN 1
                  ELSE 0
                END
              ) AS active_session_count,
              MAX(s.ended_at) AS last_session_ended_at
         FROM worktrees w
         LEFT JOIN sessions s ON (
              (COALESCE(s.worktree_id, '') != '' AND s.worktree_id = w.id)
              OR
              (COALESCE(s.worktree_id, '') = '' AND s.project_path = w.worktree_path)
         )
        WHERE w.status != 'removed'
          AND w.repo_root = ?1
        GROUP BY w.id",
      params![repo_root],
    )
  } else {
    load_worktree_session_stats_with_params(
      &conn,
      "SELECT w.id,
              COUNT(s.id) AS total_session_count,
              SUM(
                CASE
                  WHEN s.status = 'active' AND COALESCE(s.lifecycle_state, 'open') != 'ended' THEN 1
                  ELSE 0
                END
              ) AS active_session_count,
              MAX(s.ended_at) AS last_session_ended_at
         FROM worktrees w
         LEFT JOIN sessions s ON (
              (COALESCE(s.worktree_id, '') != '' AND s.worktree_id = w.id)
              OR
              (COALESCE(s.worktree_id, '') = '' AND s.project_path = w.worktree_path)
         )
        WHERE w.status != 'removed'
        GROUP BY w.id",
      [],
    )
  }
}

fn load_worktree_session_stats_with_params<P>(
  conn: &Connection,
  sql: &str,
  params: P,
) -> HashMap<String, WorktreeSessionStats>
where
  P: rusqlite::Params,
{
  let mut stmt = match conn.prepare(sql) {
    Ok(statement) => statement,
    Err(_) => return HashMap::new(),
  };

  stmt
    .query_map(params, |row| {
      let total_session_count: i64 = row.get(1)?;
      let active_session_count: i64 = row.get::<_, Option<i64>>(2)?.unwrap_or(0);
      Ok((
        row.get::<_, String>(0)?,
        WorktreeSessionStats {
          active_session_count: u32::try_from(active_session_count).unwrap_or(u32::MAX),
          total_session_count: u32::try_from(total_session_count).unwrap_or(u32::MAX),
          last_session_ended_at: row.get(3)?,
        },
      ))
    })
    .ok()
    .map(|rows| rows.filter_map(|row| row.ok()).collect())
    .unwrap_or_default()
}

pub fn load_removed_worktree_paths(db_path: &PathBuf) -> HashSet<String> {
  let Some(conn) = open_readonly_conn(db_path) else {
    return HashSet::new();
  };
  let mut stmt = match conn.prepare("SELECT worktree_path FROM worktrees WHERE status = 'removed'")
  {
    Ok(statement) => statement,
    Err(_) => return HashSet::new(),
  };
  stmt
    .query_map([], |row| row.get::<_, String>(0))
    .ok()
    .map(|rows| rows.filter_map(|row| row.ok()).collect())
    .unwrap_or_default()
}

fn open_readonly_conn(db_path: &PathBuf) -> Option<Connection> {
  if !db_path.exists() {
    return None;
  }
  let conn = Connection::open(db_path).ok()?;
  conn
    .execute_batch(
      "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;",
    )
    .ok()?;
  Some(conn)
}

fn decode_worktree_row(row: &rusqlite::Row<'_>) -> Result<WorktreeRow, rusqlite::Error> {
  Ok(WorktreeRow {
    id: row.get(0)?,
    repo_root: row.get(1)?,
    worktree_path: row.get(2)?,
    branch: row.get(3)?,
    base_branch: row.get(4)?,
    status: row.get(5)?,
    created_at: row.get(6)?,
    last_session_ended_at: row.get(7)?,
    auto_prune: row.get::<_, i64>(8)? != 0,
    custom_name: row.get(9)?,
    created_by: row.get(10)?,
  })
}

#[cfg(test)]
#[path = "worktrees_tests.rs"]
mod tests;
