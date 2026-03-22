//! Mission Control persistence: read queries.
//!
//! Write operations use PersistCommand variants dispatched through the
//! batched PersistenceWriter — this file provides synchronous read helpers.

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};

/// A mission row loaded from the database.
#[derive(Debug, Clone)]
#[allow(dead_code)]
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
    pub last_parsed_at: Option<String>,
    pub parse_error: Option<String>,
    pub mission_file_path: Option<String>,
    pub created_at: String,
    pub updated_at: String,
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

    /// Map a row whose SELECT list matches the 14-column missions schema.
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
            last_parsed_at: row.get(9)?,
            parse_error: row.get(10)?,
            mission_file_path: row.get(11)?,
            created_at: row.get(12)?,
            updated_at: row.get(13)?,
        })
    }
}

/// A mission issue row loaded from the database.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct MissionIssueRow {
    pub id: String,
    pub mission_id: String,
    pub issue_id: String,
    pub issue_identifier: String,
    pub issue_title: Option<String>,
    pub issue_state: Option<String>,
    pub orchestration_state: String,
    pub session_id: Option<String>,
    pub provider: Option<String>,
    pub attempt: u32,
    pub last_error: Option<String>,
    pub retry_due_at: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub url: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl MissionIssueRow {
    /// Map a row whose SELECT list matches the 17-column mission_issues schema.
    pub fn from_row(row: &rusqlite::Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            mission_id: row.get(1)?,
            issue_id: row.get(2)?,
            issue_identifier: row.get(3)?,
            issue_title: row.get(4)?,
            issue_state: row.get(5)?,
            orchestration_state: row.get(6)?,
            session_id: row.get(7)?,
            provider: row.get(8)?,
            attempt: row.get::<_, u32>(9)?,
            last_error: row.get(10)?,
            retry_due_at: row.get(11)?,
            started_at: row.get(12)?,
            completed_at: row.get(13)?,
            url: row.get(14)?,
            created_at: row.get(15)?,
            updated_at: row.get(16)?,
        })
    }
}

pub fn load_missions(conn: &Connection) -> Result<Vec<MissionRow>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, name, repo_root, tracker_kind, provider, config_json, prompt_template,
                    enabled, paused, last_parsed_at, parse_error, mission_file_path,
                    created_at, updated_at
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
                    m.prompt_template, m.enabled, m.paused, m.last_parsed_at, m.parse_error,
                    m.mission_file_path, m.created_at, m.updated_at,
                    COUNT(CASE WHEN mi.orchestration_state IN ('running','claimed') THEN 1 END),
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
            let active: u32 = row.get::<_, Option<u32>>(14)?.unwrap_or(0);
            let queued: u32 = row.get::<_, Option<u32>>(15)?.unwrap_or(0);
            let completed: u32 = row.get::<_, Option<u32>>(16)?.unwrap_or(0);
            let failed: u32 = row.get::<_, Option<u32>>(17)?.unwrap_or(0);
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
                    enabled, paused, last_parsed_at, parse_error, mission_file_path,
                    created_at, updated_at
             FROM missions WHERE id = ?1",
            params![id],
            MissionRow::from_row,
        )
        .optional()
        .context("query load_mission_by_id")?;

    Ok(row)
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
            "SELECT id, mission_id, issue_id, issue_identifier, issue_title, issue_state,
                    orchestration_state, session_id, provider, attempt, last_error,
                    retry_due_at, started_at, completed_at, url, created_at, updated_at
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

/// Load retry-ready issues: state = 'retry_queued', retry_due_at <= now, attempt <= max_retries.
pub fn load_retry_ready_issues(
    conn: &Connection,
    mission_id: &str,
    now: &str,
    max_retries: u32,
) -> Result<Vec<MissionIssueRow>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, mission_id, issue_id, issue_identifier, issue_title, issue_state,
                    orchestration_state, session_id, provider, attempt, last_error,
                    retry_due_at, started_at, completed_at, url, created_at, updated_at
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

/// Fields to update on a mission issue's orchestration state.
/// `None` means "don't touch this field"; `Some(None)` (for nullable fields) means "set to NULL".
pub struct MissionIssueStateUpdate<'a> {
    pub orchestration_state: &'a str,
    pub session_id: Option<&'a str>,
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
    conn.execute(&sql, params.as_slice())
        .context("update mission_issue_state")?;

    Ok(())
}

#[allow(dead_code)]
pub fn load_all_active_mission_issues(conn: &Connection) -> Result<Vec<MissionIssueRow>> {
    let mut stmt = conn
        .prepare(
            "SELECT mi.id, mi.mission_id, mi.issue_id, mi.issue_identifier, mi.issue_title,
                    mi.issue_state, mi.orchestration_state, mi.session_id, mi.provider,
                    mi.attempt, mi.last_error, mi.retry_due_at, mi.started_at,
                    mi.completed_at, mi.url, mi.created_at, mi.updated_at
             FROM mission_issues mi
             JOIN missions m ON m.id = mi.mission_id
             WHERE m.enabled = 1
               AND mi.orchestration_state NOT IN ('completed', 'failed')
             ORDER BY mi.created_at ASC",
        )
        .context("prepare load_all_active_mission_issues")?;

    let rows = stmt
        .query_map([], MissionIssueRow::from_row)
        .context("query load_all_active_mission_issues")?
        .filter_map(|r| r.ok())
        .collect();

    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrastructure::migration_runner::run_migrations;

    fn setup_test_db() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        run_migrations(&mut conn).unwrap();
        conn
    }

    fn insert_mission(conn: &Connection, id: &str, name: &str, created_at: &str) {
        conn.execute(
            "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused, created_at, updated_at)
             VALUES (?1, ?2, '/tmp/repo', 'linear', 'claude', 1, 0, ?3, ?3)",
            params![id, name, created_at],
        )
        .unwrap();
    }

    fn insert_issue(
        conn: &Connection,
        id: &str,
        mission_id: &str,
        issue_id: &str,
        orchestration_state: &str,
        created_at: &str,
    ) {
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?6)",
            params![
                id,
                mission_id,
                issue_id,
                format!("ISSUE-{issue_id}"),
                orchestration_state,
                created_at,
            ],
        )
        .unwrap();
    }

    // ── load_missions ─────────────────────────────────────────────────

    #[test]
    fn load_missions_returns_descending_created_at_order() {
        let conn = setup_test_db();
        insert_mission(&conn, "m-old", "Old", "2026-01-01T00:00:00.000Z");
        insert_mission(&conn, "m-mid", "Mid", "2026-02-01T00:00:00.000Z");
        insert_mission(&conn, "m-new", "New", "2026-03-01T00:00:00.000Z");

        let missions = load_missions(&conn).unwrap();
        let ids: Vec<&str> = missions.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["m-new", "m-mid", "m-old"]);
    }

    #[test]
    fn load_missions_returns_empty_for_no_rows() {
        let conn = setup_test_db();
        let missions = load_missions(&conn).unwrap();
        assert!(missions.is_empty());
    }

    // ── load_missions_with_counts ─────────────────────────────────────

    #[test]
    fn load_missions_with_counts_aggregates_issue_states() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "Mission One", "2026-03-01T00:00:00.000Z");

        // active: running + claimed = 2
        insert_issue(
            &conn,
            "i1",
            "m1",
            "iss-1",
            "running",
            "2026-03-01T00:01:00.000Z",
        );
        insert_issue(
            &conn,
            "i2",
            "m1",
            "iss-2",
            "claimed",
            "2026-03-01T00:02:00.000Z",
        );
        // queued: queued + retry_queued = 2
        insert_issue(
            &conn,
            "i3",
            "m1",
            "iss-3",
            "queued",
            "2026-03-01T00:03:00.000Z",
        );
        insert_issue(
            &conn,
            "i4",
            "m1",
            "iss-4",
            "retry_queued",
            "2026-03-01T00:04:00.000Z",
        );
        // completed = 1
        insert_issue(
            &conn,
            "i5",
            "m1",
            "iss-5",
            "completed",
            "2026-03-01T00:05:00.000Z",
        );
        // failed = 1
        insert_issue(
            &conn,
            "i6",
            "m1",
            "iss-6",
            "failed",
            "2026-03-01T00:06:00.000Z",
        );

        let results = load_missions_with_counts(&conn).unwrap();
        assert_eq!(results.len(), 1);

        let (mission, (active, queued, completed, failed)) = &results[0];
        assert_eq!(mission.id, "m1");
        assert_eq!(*active, 2);
        assert_eq!(*queued, 2);
        assert_eq!(*completed, 1);
        assert_eq!(*failed, 1);
    }

    #[test]
    fn load_missions_with_counts_returns_zeros_when_no_issues() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "Empty", "2026-03-01T00:00:00.000Z");

        let results = load_missions_with_counts(&conn).unwrap();
        assert_eq!(results.len(), 1);
        let (_, (active, queued, completed, failed)) = &results[0];
        assert_eq!((*active, *queued, *completed, *failed), (0, 0, 0, 0));
    }

    // ── load_mission_by_id ────────────────────────────────────────────

    #[test]
    fn load_mission_by_id_returns_matching_row() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "Found", "2026-03-01T00:00:00.000Z");

        let row = load_mission_by_id(&conn, "m1").unwrap();
        assert!(row.is_some());
        assert_eq!(row.unwrap().name, "Found");
    }

    #[test]
    fn load_mission_by_id_returns_none_for_missing() {
        let conn = setup_test_db();
        let row = load_mission_by_id(&conn, "nonexistent").unwrap();
        assert!(row.is_none());
    }

    // ── load_mission_issues ───────────────────────────────────────────

    #[test]
    fn load_mission_issues_returns_only_matching_mission() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");
        insert_mission(&conn, "m2", "Two", "2026-03-01T00:00:00.000Z");

        insert_issue(
            &conn,
            "i1",
            "m1",
            "iss-1",
            "queued",
            "2026-03-01T00:01:00.000Z",
        );
        insert_issue(
            &conn,
            "i2",
            "m1",
            "iss-2",
            "running",
            "2026-03-01T00:02:00.000Z",
        );
        insert_issue(
            &conn,
            "i3",
            "m2",
            "iss-3",
            "queued",
            "2026-03-01T00:03:00.000Z",
        );

        let issues = load_mission_issues(&conn, "m1").unwrap();
        assert_eq!(issues.len(), 2);
        assert!(issues.iter().all(|i| i.mission_id == "m1"));
    }

    #[test]
    fn load_mission_issues_returns_ascending_created_at() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

        insert_issue(
            &conn,
            "i-late",
            "m1",
            "iss-2",
            "queued",
            "2026-03-02T00:00:00.000Z",
        );
        insert_issue(
            &conn,
            "i-early",
            "m1",
            "iss-1",
            "queued",
            "2026-03-01T00:00:00.000Z",
        );

        let issues = load_mission_issues(&conn, "m1").unwrap();
        let ids: Vec<&str> = issues.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["i-early", "i-late"]);
    }

    // ── load_retry_ready_issues ───────────────────────────────────────

    #[test]
    fn load_retry_ready_issues_only_returns_eligible_rows() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

        // Eligible: retry_queued, retry_due_at in the past, attempt <= max
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i1', 'm1', 'iss-1', 'ISSUE-1', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Not eligible: retry_due_at in the future
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i2', 'm1', 'iss-2', 'ISSUE-2', 'retry_queued', 1, '2099-01-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Not eligible: wrong state (queued, not retry_queued)
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i3', 'm1', 'iss-3', 'ISSUE-3', 'queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Not eligible: attempt exceeds max_retries
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i4', 'm1', 'iss-4', 'ISSUE-4', 'retry_queued', 5, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Not eligible: retry_due_at is NULL
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, created_at, updated_at)
             VALUES ('i5', 'm1', 'iss-5', 'ISSUE-5', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        let now = "2026-03-15T00:00:00.000Z";
        let max_retries = 3;

        let ready = load_retry_ready_issues(&conn, "m1", now, max_retries).unwrap();
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].id, "i1");
    }

    #[test]
    fn load_retry_ready_issues_orders_by_retry_due_at_asc() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i-later', 'm1', 'iss-2', 'ISSUE-2', 'retry_queued', 1, '2026-03-02T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, retry_due_at, created_at, updated_at)
             VALUES ('i-earlier', 'm1', 'iss-1', 'ISSUE-1', 'retry_queued', 1, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        let ready = load_retry_ready_issues(&conn, "m1", "2026-03-15T00:00:00.000Z", 3).unwrap();
        let ids: Vec<&str> = ready.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["i-earlier", "i-later"]);
    }

    // ── update_mission_issue_state_sync ───────────────────────────────

    #[test]
    fn update_state_sync_changes_orchestration_state() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");
        insert_issue(
            &conn,
            "i1",
            "m1",
            "iss-1",
            "queued",
            "2026-03-01T00:00:00.000Z",
        );

        update_mission_issue_state_sync(
            &conn,
            "m1",
            "iss-1",
            &MissionIssueStateUpdate {
                orchestration_state: "running",
                session_id: Some("session-abc"),
                attempt: Some(1),
                last_error: None,
                started_at: Some(Some("2026-03-01T01:00:00.000Z")),
                completed_at: None,
            },
        )
        .unwrap();

        let row: (String, Option<String>, u32, Option<String>) = conn
            .query_row(
                "SELECT orchestration_state, session_id, attempt, started_at FROM mission_issues WHERE issue_id = 'iss-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();

        assert_eq!(row.0, "running");
        assert_eq!(row.1.as_deref(), Some("session-abc"));
        assert_eq!(row.2, 1);
        assert_eq!(row.3.as_deref(), Some("2026-03-01T01:00:00.000Z"));
    }

    #[test]
    fn update_state_sync_sets_completed_at_and_last_error() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");
        insert_issue(
            &conn,
            "i1",
            "m1",
            "iss-1",
            "running",
            "2026-03-01T00:00:00.000Z",
        );

        update_mission_issue_state_sync(
            &conn,
            "m1",
            "iss-1",
            &MissionIssueStateUpdate {
                orchestration_state: "failed",
                session_id: None,
                attempt: None,
                last_error: Some(Some("something went wrong")),
                started_at: None,
                completed_at: Some(Some("2026-03-01T02:00:00.000Z")),
            },
        )
        .unwrap();

        let row: (String, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT orchestration_state, last_error, completed_at FROM mission_issues WHERE issue_id = 'iss-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();

        assert_eq!(row.0, "failed");
        assert_eq!(row.1.as_deref(), Some("something went wrong"));
        assert_eq!(row.2.as_deref(), Some("2026-03-01T02:00:00.000Z"));
    }

    #[test]
    fn update_state_sync_can_clear_nullable_fields() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

        // Start with a last_error set
        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt, last_error, created_at, updated_at)
             VALUES ('i1', 'm1', 'iss-1', 'ISSUE-1', 'failed', 1, 'old error', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Clear last_error by passing Some(None)
        update_mission_issue_state_sync(
            &conn,
            "m1",
            "iss-1",
            &MissionIssueStateUpdate {
                orchestration_state: "retry_queued",
                session_id: None,
                attempt: None,
                last_error: Some(None), // clear last_error
                started_at: None,
                completed_at: None,
            },
        )
        .unwrap();

        let error: Option<String> = conn
            .query_row(
                "SELECT last_error FROM mission_issues WHERE issue_id = 'iss-1'",
                [],
                |r| r.get(0),
            )
            .unwrap();

        assert!(error.is_none());
    }

    #[test]
    fn update_state_sync_leaves_unspecified_fields_unchanged() {
        let conn = setup_test_db();
        insert_mission(&conn, "m1", "One", "2026-03-01T00:00:00.000Z");

        conn.execute(
            "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, session_id, attempt, last_error, started_at, created_at, updated_at)
             VALUES ('i1', 'm1', 'iss-1', 'ISSUE-1', 'running', 'sess-old', 2, 'prev error', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Only update orchestration_state — all optional params are None (meaning "don't touch")
        update_mission_issue_state_sync(
            &conn,
            "m1",
            "iss-1",
            &MissionIssueStateUpdate {
                orchestration_state: "completed",
                session_id: None,
                attempt: None,
                last_error: None,
                started_at: None,
                completed_at: None,
            },
        )
        .unwrap();

        let row: (String, Option<String>, u32, Option<String>) = conn
            .query_row(
                "SELECT orchestration_state, session_id, attempt, last_error FROM mission_issues WHERE issue_id = 'iss-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();

        assert_eq!(row.0, "completed");
        assert_eq!(row.1.as_deref(), Some("sess-old")); // untouched
        assert_eq!(row.2, 2); // untouched
        assert_eq!(row.3.as_deref(), Some("prev error")); // untouched
    }

    // ── load_all_active_mission_issues ────────────────────────────────

    #[test]
    fn load_all_active_mission_issues_excludes_terminal_and_disabled() {
        let conn = setup_test_db();
        insert_mission(&conn, "m-enabled", "Enabled", "2026-03-01T00:00:00.000Z");

        // Disabled mission
        conn.execute(
            "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused, created_at, updated_at)
             VALUES ('m-disabled', 'Disabled', '/tmp/repo', 'linear', 'claude', 0, 0, '2026-03-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z')",
            [],
        ).unwrap();

        // Active issues from enabled mission — should be included
        insert_issue(
            &conn,
            "i1",
            "m-enabled",
            "iss-1",
            "running",
            "2026-03-01T00:01:00.000Z",
        );
        insert_issue(
            &conn,
            "i2",
            "m-enabled",
            "iss-2",
            "queued",
            "2026-03-01T00:02:00.000Z",
        );

        // Terminal issues from enabled mission — should be excluded
        insert_issue(
            &conn,
            "i3",
            "m-enabled",
            "iss-3",
            "completed",
            "2026-03-01T00:03:00.000Z",
        );
        insert_issue(
            &conn,
            "i4",
            "m-enabled",
            "iss-4",
            "failed",
            "2026-03-01T00:04:00.000Z",
        );

        // Active issue from disabled mission — should be excluded
        insert_issue(
            &conn,
            "i5",
            "m-disabled",
            "iss-5",
            "running",
            "2026-03-01T00:05:00.000Z",
        );

        let issues = load_all_active_mission_issues(&conn).unwrap();
        let ids: Vec<&str> = issues.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["i1", "i2"]);
    }

    // ── MissionRow helpers ────────────────────────────────────────────

    #[test]
    fn resolved_mission_path_defaults_to_mission_md() {
        let row = MissionRow {
            id: "m1".into(),
            name: "Test".into(),
            repo_root: "/home/user/project".into(),
            tracker_kind: "linear".into(),
            provider: "claude".into(),
            config_json: None,
            prompt_template: None,
            enabled: true,
            paused: false,
            last_parsed_at: None,
            parse_error: None,
            mission_file_path: None,
            created_at: String::new(),
            updated_at: String::new(),
        };
        assert_eq!(
            row.resolved_mission_path(),
            std::path::PathBuf::from("/home/user/project/MISSION.md")
        );
    }

    #[test]
    fn resolved_mission_path_uses_custom_path() {
        let row = MissionRow {
            id: "m1".into(),
            name: "Test".into(),
            repo_root: "/home/user/project".into(),
            tracker_kind: "linear".into(),
            provider: "claude".into(),
            config_json: None,
            prompt_template: None,
            enabled: true,
            paused: false,
            last_parsed_at: None,
            parse_error: None,
            mission_file_path: Some("docs/CUSTOM.md".into()),
            created_at: String::new(),
            updated_at: String::new(),
        };
        assert_eq!(
            row.resolved_mission_path(),
            std::path::PathBuf::from("/home/user/project/docs/CUSTOM.md")
        );
    }

    #[test]
    fn resolved_mission_path_ignores_empty_string() {
        let row = MissionRow {
            id: "m1".into(),
            name: "Test".into(),
            repo_root: "/home/user/project".into(),
            tracker_kind: "linear".into(),
            provider: "claude".into(),
            config_json: None,
            prompt_template: None,
            enabled: true,
            paused: false,
            last_parsed_at: None,
            parse_error: None,
            mission_file_path: Some(String::new()),
            created_at: String::new(),
            updated_at: String::new(),
        };
        assert_eq!(
            row.resolved_mission_path(),
            std::path::PathBuf::from("/home/user/project/MISSION.md")
        );
    }
}
