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
    pub repo_root: String,
    pub tracker_kind: String,
    pub provider: String,
    pub config_json: Option<String>,
    pub prompt_template: Option<String>,
    pub enabled: bool,
    pub paused: bool,
    pub last_parsed_at: Option<String>,
    pub parse_error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
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
            "SELECT id, repo_root, tracker_kind, provider, config_json, prompt_template,
                    enabled, paused, last_parsed_at, parse_error, created_at, updated_at
             FROM missions
             ORDER BY created_at DESC",
        )
        .context("prepare load_missions")?;

    let rows = stmt
        .query_map([], |row| {
            Ok(MissionRow {
                id: row.get(0)?,
                repo_root: row.get(1)?,
                tracker_kind: row.get(2)?,
                provider: row.get(3)?,
                config_json: row.get(4)?,
                prompt_template: row.get(5)?,
                enabled: row.get::<_, i64>(6)? != 0,
                paused: row.get::<_, i64>(7)? != 0,
                last_parsed_at: row.get(8)?,
                parse_error: row.get(9)?,
                created_at: row.get(10)?,
                updated_at: row.get(11)?,
            })
        })
        .context("query load_missions")?
        .filter_map(|r| r.ok())
        .collect();

    Ok(rows)
}

pub fn load_mission_by_id(conn: &Connection, id: &str) -> Result<Option<MissionRow>> {
    let row = conn
        .query_row(
            "SELECT id, repo_root, tracker_kind, provider, config_json, prompt_template,
                    enabled, paused, last_parsed_at, parse_error, created_at, updated_at
             FROM missions WHERE id = ?1",
            params![id],
            |row| {
                Ok(MissionRow {
                    id: row.get(0)?,
                    repo_root: row.get(1)?,
                    tracker_kind: row.get(2)?,
                    provider: row.get(3)?,
                    config_json: row.get(4)?,
                    prompt_template: row.get(5)?,
                    enabled: row.get::<_, i64>(6)? != 0,
                    paused: row.get::<_, i64>(7)? != 0,
                    last_parsed_at: row.get(8)?,
                    parse_error: row.get(9)?,
                    created_at: row.get(10)?,
                    updated_at: row.get(11)?,
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
