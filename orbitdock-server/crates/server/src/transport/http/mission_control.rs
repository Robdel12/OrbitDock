use std::sync::Arc;

use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};
use tracing::info;

use orbitdock_protocol::{MissionIssueItem, MissionSummary, OrchestrationState, Provider};

use crate::infrastructure::persistence::{
    load_mission_by_id, load_mission_issues, load_missions, MissionIssueRow, MissionRow,
    PersistCommand,
};
use crate::runtime::session_registry::SessionRegistry;

use super::errors::{internal, not_found, ApiResult};

#[derive(Serialize)]
pub struct MissionsListResponse {
    pub missions: Vec<MissionSummary>,
}

#[derive(Serialize)]
pub struct MissionDetailResponse {
    pub summary: MissionSummary,
    pub issues: Vec<MissionIssueItem>,
}

#[derive(Deserialize)]
pub struct CreateMissionRequest {
    pub repo_root: String,
    #[serde(default = "default_tracker")]
    pub tracker_kind: String,
    #[serde(default = "default_provider")]
    pub provider: String,
}

fn default_tracker() -> String {
    "linear".to_string()
}

fn default_provider() -> String {
    "claude".to_string()
}

#[derive(Deserialize)]
pub struct UpdateMissionRequest {
    pub enabled: Option<bool>,
    pub paused: Option<bool>,
}

/// GET /api/missions
pub async fn list_missions(
    State(registry): State<Arc<SessionRegistry>>,
) -> ApiResult<MissionsListResponse> {
    let db_path = registry.db_path().clone();
    let rows = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_missions(&conn)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let missions = rows.into_iter().map(|r| mission_row_to_summary(&r)).collect();

    Ok(Json(MissionsListResponse { missions }))
}

/// POST /api/missions
pub async fn create_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Json(req): Json<CreateMissionRequest>,
) -> ApiResult<MissionSummary> {
    let id = orbitdock_protocol::new_id();

    let _ = registry
        .persist()
        .send(PersistCommand::MissionCreate {
            id: id.clone(),
            repo_root: req.repo_root.clone(),
            tracker_kind: req.tracker_kind.clone(),
            provider: req.provider.clone(),
            config_json: None,
            prompt_template: None,
        })
        .await;

    info!(
        component = "mission_control",
        event = "mission.created",
        mission_id = %id,
        repo_root = %req.repo_root,
        "Mission created"
    );

    let provider = match req.provider.as_str() {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    };

    Ok(Json(MissionSummary {
        id,
        repo_root: req.repo_root,
        enabled: true,
        paused: false,
        tracker_kind: req.tracker_kind,
        provider,
        active_count: 0,
        queued_count: 0,
        completed_count: 0,
        failed_count: 0,
        parse_error: None,
    }))
}

/// GET /api/missions/:id
pub async fn get_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionDetailResponse> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();

    let (mission_row, issue_rows) = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        let mission = load_mission_by_id(&conn, &mid)?;
        let issues = if mission.is_some() {
            load_mission_issues(&conn, &mid)?
        } else {
            vec![]
        };
        Ok::<_, anyhow::Error>((mission, issues))
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let mission = mission_row
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let summary = mission_row_to_summary_with_issues(&mission, &issue_rows);
    let issues = issue_rows.into_iter().map(issue_row_to_item).collect();

    Ok(Json(MissionDetailResponse { summary, issues }))
}

/// PUT /api/missions/:id
pub async fn update_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
    Json(req): Json<UpdateMissionRequest>,
) -> ApiResult<serde_json::Value> {
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            enabled: req.enabled,
            paused: req.paused,
            config_json: None,
            prompt_template: None,
            parse_error: None,
        })
        .await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

/// DELETE /api/missions/:id
pub async fn delete_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<serde_json::Value> {
    let _ = registry
        .persist()
        .send(PersistCommand::MissionDelete {
            id: mission_id.clone(),
        })
        .await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

/// GET /api/missions/:id/issues
pub async fn list_mission_issues(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<Vec<MissionIssueItem>> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();

    let issue_rows = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_issues(&conn, &mid)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let items: Vec<MissionIssueItem> = issue_rows.into_iter().map(issue_row_to_item).collect();
    Ok(Json(items))
}

fn mission_row_to_summary(row: &MissionRow) -> MissionSummary {
    let provider = match row.provider.as_str() {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    };

    MissionSummary {
        id: row.id.clone(),
        repo_root: row.repo_root.clone(),
        enabled: row.enabled,
        paused: row.paused,
        tracker_kind: row.tracker_kind.clone(),
        provider,
        active_count: 0,
        queued_count: 0,
        completed_count: 0,
        failed_count: 0,
        parse_error: row.parse_error.clone(),
    }
}

fn mission_row_to_summary_with_issues(
    row: &MissionRow,
    issue_rows: &[MissionIssueRow],
) -> MissionSummary {
    let provider = match row.provider.as_str() {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    };

    let mut active_count = 0u32;
    let mut queued_count = 0u32;
    let mut completed_count = 0u32;
    let mut failed_count = 0u32;

    for issue in issue_rows {
        match issue.orchestration_state.as_str() {
            "running" | "claimed" => active_count += 1,
            "queued" | "retry_queued" => queued_count += 1,
            "completed" => completed_count += 1,
            "failed" => failed_count += 1,
            _ => queued_count += 1,
        }
    }

    MissionSummary {
        id: row.id.clone(),
        repo_root: row.repo_root.clone(),
        enabled: row.enabled,
        paused: row.paused,
        tracker_kind: row.tracker_kind.clone(),
        provider,
        active_count,
        queued_count,
        completed_count,
        failed_count,
        parse_error: row.parse_error.clone(),
    }
}

fn issue_row_to_item(row: MissionIssueRow) -> MissionIssueItem {
    let orchestration_state = match row.orchestration_state.as_str() {
        "queued" => OrchestrationState::Queued,
        "claimed" => OrchestrationState::Claimed,
        "running" => OrchestrationState::Running,
        "retry_queued" => OrchestrationState::RetryQueued,
        "completed" => OrchestrationState::Completed,
        "failed" => OrchestrationState::Failed,
        _ => OrchestrationState::Queued,
    };

    let provider = match row.provider.as_deref() {
        Some("codex") => Provider::Codex,
        _ => Provider::Claude,
    };

    MissionIssueItem {
        issue_id: row.issue_id,
        identifier: row.issue_identifier,
        title: row.issue_title.unwrap_or_default(),
        tracker_state: row.issue_state.unwrap_or_default(),
        orchestration_state,
        session_id: row.session_id,
        provider,
        attempt: row.attempt,
        error: row.last_error,
        url: None,
        last_activity: None,
    }
}
