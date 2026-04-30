use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;

use orbitdock_protocol::RecentProject;
use rusqlite::Connection;

pub fn load_recent_projects_from_sessions(
  db_path: &PathBuf,
  hidden_paths: &HashSet<String>,
) -> Vec<RecentProject> {
  let Some(conn) = open_readonly_conn(db_path) else {
    return Vec::new();
  };

  let mut stmt = match conn.prepare(
    "SELECT project_path,
            COUNT(*) AS session_count,
            MAX(last_activity_at) AS last_active,
            MAX(COALESCE(is_worktree, 0)) AS is_worktree
       FROM sessions
      WHERE TRIM(project_path) != ''
        AND COALESCE(mission_id, '') = ''
      GROUP BY project_path",
  ) {
    Ok(statement) => statement,
    Err(_) => return Vec::new(),
  };

  let rows = match stmt.query_map([], |row| {
    let count: i64 = row.get(1)?;
    let is_worktree = row.get::<_, i64>(3)? != 0;
    Ok((
      RecentProject {
        path: row.get(0)?,
        session_count: u32::try_from(count).unwrap_or(u32::MAX),
        last_active: row.get(2)?,
      },
      is_worktree,
    ))
  }) {
    Ok(rows) => rows,
    Err(_) => return Vec::new(),
  };

  let mut projects: Vec<RecentProject> = rows
    .filter_map(|row| row.ok())
    .filter(|(project, _)| !hidden_paths.contains(&project.path))
    .filter(|(project, is_worktree)| {
      !should_hide_missing_worktree_path(&project.path, *is_worktree)
    })
    .map(|(project, _)| project)
    .collect();

  projects.sort_by(|a, b| {
    b.last_active
      .cmp(&a.last_active)
      .then_with(|| a.path.cmp(&b.path))
  });
  projects
}

fn should_hide_missing_worktree_path(path: &str, is_worktree: bool) -> bool {
  is_worktree && !Path::new(path).exists()
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
