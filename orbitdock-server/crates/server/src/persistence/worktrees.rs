use super::*;

#[derive(Debug, Clone)]
pub struct WorktreeRow {
    pub id: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_branch: Option<String>,
    pub status: String,
}

pub fn load_worktree_by_id(db_path: &PathBuf, worktree_id: &str) -> Option<WorktreeRow> {
    let conn = open_readonly_conn(db_path)?;
    conn.query_row(
        "SELECT id, repo_root, worktree_path, branch, base_branch, status FROM worktrees WHERE id = ?1",
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
        "SELECT id, repo_root, worktree_path, branch, base_branch, status FROM worktrees WHERE repo_root = ?1 AND status != 'removed'",
    ) {
        Ok(statement) => statement,
        Err(_) => return Vec::new(),
    };
    stmt.query_map(params![repo_root], decode_worktree_row)
        .ok()
        .map(|rows| rows.filter_map(|row| row.ok()).collect())
        .unwrap_or_default()
}

pub fn load_removed_worktree_paths(db_path: &PathBuf) -> HashSet<String> {
    let Some(conn) = open_readonly_conn(db_path) else {
        return HashSet::new();
    };
    let mut stmt =
        match conn.prepare("SELECT worktree_path FROM worktrees WHERE status = 'removed'") {
            Ok(statement) => statement,
            Err(_) => return HashSet::new(),
        };
    stmt.query_map([], |row| row.get::<_, String>(0))
        .ok()
        .map(|rows| rows.filter_map(|row| row.ok()).collect())
        .unwrap_or_default()
}

fn open_readonly_conn(db_path: &PathBuf) -> Option<Connection> {
    if !db_path.exists() {
        return None;
    }
    let conn = Connection::open(db_path).ok()?;
    conn.execute_batch(
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
    })
}
