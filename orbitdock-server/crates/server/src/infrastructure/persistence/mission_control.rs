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
        .query_map([], |row| {
            Ok(MissionRow {
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
        })
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
            let mission = MissionRow {
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
            };
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
            |row| {
                Ok(MissionRow {
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
            },
        )
        .optional()
        .context("query load_mission_by_id")?;

    Ok(row)
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
        .query_map(params![mission_id], |row| {
            Ok(MissionIssueRow {
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
        })
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
            Ok(MissionIssueRow {
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
        })
        .context("query load_retry_ready_issues")?
        .filter_map(|r| r.ok())
        .collect();

    Ok(rows)
}

/// Synchronously update a mission issue's orchestration state.
/// Used by dispatch paths that need the write to be visible before broadcasting.
pub fn update_mission_issue_state_sync(
    conn: &Connection,
    mission_id: &str,
    issue_id: &str,
    orchestration_state: &str,
    session_id: Option<&str>,
    attempt: Option<u32>,
    last_error: Option<Option<&str>>,
    started_at: Option<Option<&str>>,
    completed_at: Option<Option<&str>>,
) -> Result<()> {
    conn.execute(
        "UPDATE mission_issues SET orchestration_state = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE mission_id = ?2 AND issue_id = ?3",
        params![orchestration_state, mission_id, issue_id],
    ).context("update orchestration_state")?;

    if let Some(sid) = session_id {
        conn.execute(
            "UPDATE mission_issues SET session_id = ?1 WHERE mission_id = ?2 AND issue_id = ?3",
            params![sid, mission_id, issue_id],
        ).context("update session_id")?;
    }
    if let Some(a) = attempt {
        conn.execute(
            "UPDATE mission_issues SET attempt = ?1 WHERE mission_id = ?2 AND issue_id = ?3",
            params![a, mission_id, issue_id],
        ).context("update attempt")?;
    }
    if let Some(err) = last_error {
        conn.execute(
            "UPDATE mission_issues SET last_error = ?1 WHERE mission_id = ?2 AND issue_id = ?3",
            params![err, mission_id, issue_id],
        ).context("update last_error")?;
    }
    if let Some(sa) = started_at {
        conn.execute(
            "UPDATE mission_issues SET started_at = ?1 WHERE mission_id = ?2 AND issue_id = ?3",
            params![sa, mission_id, issue_id],
        ).context("update started_at")?;
    }
    if let Some(ca) = completed_at {
        conn.execute(
            "UPDATE mission_issues SET completed_at = ?1 WHERE mission_id = ?2 AND issue_id = ?3",
            params![ca, mission_id, issue_id],
        ).context("update completed_at")?;
    }
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
        .query_map([], |row| {
            Ok(MissionIssueRow {
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
        })
        .context("query load_all_active_mission_issues")?
        .filter_map(|r| r.ok())
        .collect();

    Ok(rows)
}
