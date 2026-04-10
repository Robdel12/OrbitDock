use rusqlite::{params, Connection};

pub(super) fn persist_worktree_create(
  conn: &Connection,
  id: String,
  repo_root: String,
  worktree_path: String,
  branch: String,
  base_branch: Option<String>,
  created_by: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "INSERT INTO worktrees (id, repo_root, worktree_path, branch, base_branch, created_by)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(worktree_path) DO UPDATE SET
           status = 'active',
           branch = excluded.branch,
           base_branch = excluded.base_branch",
    params![
      id,
      repo_root,
      worktree_path,
      branch,
      base_branch,
      created_by
    ],
  )?;
  Ok(())
}

pub(super) fn persist_worktree_update_status(
  conn: &Connection,
  id: String,
  status: String,
  last_session_ended_at: Option<String>,
) -> Result<(), rusqlite::Error> {
  conn.execute(
    "UPDATE worktrees SET status = ?1, last_session_ended_at = COALESCE(?2, last_session_ended_at) WHERE id = ?3",
    params![status, last_session_ended_at, id],
  )?;
  Ok(())
}
