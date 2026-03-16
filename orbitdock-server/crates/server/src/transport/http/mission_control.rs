use std::path::Path as StdPath;
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::Json;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use tracing::info;

use orbitdock_protocol::{MissionIssueItem, MissionSummary, OrchestrationState, Provider};

use crate::domain::mission_control::config::{parse_workflow, MissionConfig};
use crate::domain::mission_control::template::default_workflow_template;
use crate::infrastructure::persistence::{
    load_mission_by_id, load_mission_issues, load_missions, MissionIssueRow, MissionRow,
    PersistCommand,
};
use crate::runtime::session_registry::SessionRegistry;

use super::errors::{bad_request, conflict, internal, not_found, ApiResult};

// ── Response types ───────────────────────────────────────────────────

#[derive(Serialize)]
pub struct MissionsListResponse {
    pub missions: Vec<MissionSummary>,
}

#[derive(Serialize)]
pub struct MissionDetailResponse {
    pub summary: MissionSummary,
    pub issues: Vec<MissionIssueItem>,
    pub settings: Option<MissionSettingsResponse>,
    pub workflow_exists: bool,
}

#[derive(Serialize)]
pub struct MissionSettingsResponse {
    pub provider: ProviderSettingsResponse,
    pub trigger: TriggerSettingsResponse,
    pub orchestration: OrchestrationSettingsResponse,
    pub prompt_template: String,
    pub tracker: String,
}

#[derive(Serialize)]
pub struct ProviderSettingsResponse {
    pub strategy: String,
    pub primary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary: Option<String>,
    pub max_concurrent: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_concurrent_primary: Option<u32>,
}

#[derive(Serialize)]
pub struct TriggerSettingsResponse {
    pub kind: String,
    pub interval: u64,
    pub filters: TriggerFiltersResponse,
}

#[derive(Serialize)]
pub struct TriggerFiltersResponse {
    pub labels: Vec<String>,
    pub states: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
}

#[derive(Serialize)]
pub struct OrchestrationSettingsResponse {
    pub max_retries: u32,
    pub stall_timeout: u64,
    pub base_branch: String,
}

// ── Request types ────────────────────────────────────────────────────

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

#[derive(Deserialize)]
pub struct UpdateMissionSettingsRequest {
    // Provider
    pub provider_strategy: Option<String>,
    pub primary_provider: Option<String>,
    pub secondary_provider: Option<Option<String>>,
    pub max_concurrent: Option<u32>,
    pub max_concurrent_primary: Option<Option<u32>>,
    // Trigger
    pub trigger_kind: Option<String>,
    pub poll_interval: Option<u64>,
    pub label_filter: Option<Vec<String>>,
    pub state_filter: Option<Vec<String>>,
    pub project_key: Option<Option<String>>,
    pub team_key: Option<Option<String>>,
    // Orchestration
    pub max_retries: Option<u32>,
    pub stall_timeout: Option<u64>,
    pub base_branch: Option<String>,
    // Prompt
    pub prompt_template: Option<String>,
    // Tracker
    pub tracker: Option<String>,
}

// ── Handlers ─────────────────────────────────────────────────────────

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

    let missions = rows
        .into_iter()
        .map(|r| mission_row_to_summary(&r))
        .collect();

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

    let primary_provider = parse_provider(&req.provider);

    let orchestrator_status = if crate::support::api_keys::resolve_linear_api_key().is_none() {
        Some("no_api_key".to_string())
    } else {
        Some("polling".to_string())
    };

    Ok(Json(MissionSummary {
        id,
        repo_root: req.repo_root,
        enabled: true,
        paused: false,
        tracker_kind: req.tracker_kind,
        provider: primary_provider,
        provider_strategy: "single".to_string(),
        primary_provider,
        secondary_provider: None,
        active_count: 0,
        queued_count: 0,
        completed_count: 0,
        failed_count: 0,
        parse_error: None,
        orchestrator_status,
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

    let workflow_exists = tokio::fs::metadata(StdPath::new(&mission.repo_root).join("WORKFLOW.md"))
        .await
        .is_ok();

    let summary = mission_row_to_summary_with_issues(&mission, &issue_rows);
    let issues = issue_rows.into_iter().map(issue_row_to_item).collect();

    // Build settings from config_json + prompt_template
    let settings = build_settings_response(&mission);

    Ok(Json(MissionDetailResponse {
        summary,
        issues,
        settings,
        workflow_exists,
    }))
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

/// POST /api/missions/:mission_id/issues/:issue_id/retry
pub async fn retry_mission_issue(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
) -> ApiResult<serde_json::Value> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();
    let iid = issue_id.clone();

    let issue_row = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        let mut stmt = conn.prepare(
            "SELECT id, orchestration_state, attempt FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
        )?;
        let row = stmt.query_row(params![mid, iid], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
            ))
        });
        match row {
            Ok(r) => Ok(Some(r)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(anyhow::anyhow!(e)),
        }
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let (row_id, state, attempt) = issue_row.ok_or_else(|| {
        not_found(
            "not_found",
            format!("Issue {issue_id} not found in mission {mission_id}"),
        )
    })?;

    if state != "failed" {
        return Err(super::errors::bad_request(
            "invalid_state",
            format!("Issue is in state '{state}', can only retry failed issues"),
        ));
    }

    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
            id: row_id,
            orchestration_state: "retry_queued".to_string(),
            session_id: None,
            attempt: Some(attempt + 1),
            last_error: Some(None),
            retry_due_at: None,
            started_at: Some(None),
            completed_at: Some(None),
        })
        .await;

    info!(
        component = "mission_control",
        event = "issue.retry_queued",
        mission_id = %mission_id,
        issue_id = %issue_id,
        attempt = attempt + 1,
        "Issue queued for retry"
    );

    Ok(Json(serde_json::json!({ "ok": true })))
}

/// POST /api/missions/:id/scaffold-workflow
///
/// Writes a default WORKFLOW.md template to the mission's repo_root.
/// Returns 409 if the file already exists.
pub async fn scaffold_mission_workflow(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionDetailResponse> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();

    let mission = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_by_id(&conn, &mid)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let workflow_path = StdPath::new(&mission.repo_root).join("WORKFLOW.md");

    // Don't overwrite an existing WORKFLOW.md
    if tokio::fs::metadata(&workflow_path).await.is_ok() {
        return Err(conflict(
            "workflow_exists",
            "WORKFLOW.md already exists in this repository",
        ));
    }

    // Generate and write the template
    let template_content = default_workflow_template(&mission.provider);
    tokio::fs::write(&workflow_path, &template_content)
        .await
        .map_err(|e| internal("write_error", format!("Failed to write WORKFLOW.md: {e}")))?;

    info!(
        component = "mission_control",
        event = "workflow.scaffolded",
        mission_id = %mission_id,
        repo_root = %mission.repo_root,
        "Scaffolded WORKFLOW.md"
    );

    // Parse the template immediately and persist
    let parsed = parse_workflow(&template_content).map_err(|e| {
        internal(
            "parse_error",
            format!("Failed to parse scaffolded template: {e}"),
        )
    })?;

    let config_json = serde_json::to_string(&parsed.config).unwrap_or_default();
    let prompt_template = parsed.prompt_template.clone();

    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            enabled: None,
            paused: None,
            config_json: Some(config_json.clone()),
            prompt_template: Some(prompt_template.clone()),
            parse_error: Some(None),
        })
        .await;

    // Build response matching get_mission format
    let db_path = registry.db_path().clone();
    let mid2 = mission_id.clone();
    let issue_rows = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_issues(&conn, &mid2)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let summary = mission_row_to_summary_with_issues(&mission, &issue_rows);
    let issues = issue_rows.into_iter().map(issue_row_to_item).collect();

    let settings = config_to_settings_response(&parsed.config, &prompt_template);

    Ok(Json(MissionDetailResponse {
        summary,
        issues,
        settings: Some(settings),
        workflow_exists: true,
    }))
}

// ── Linear API key endpoints ─────────────────────────────────────────

#[derive(Serialize)]
pub struct LinearKeyStatusResponse {
    pub configured: bool,
}

#[derive(Deserialize)]
pub struct SetLinearKeyRequest {
    pub key: String,
}

/// GET /api/server/linear-key
pub async fn check_linear_key() -> Json<LinearKeyStatusResponse> {
    Json(LinearKeyStatusResponse {
        configured: crate::support::api_keys::resolve_linear_api_key().is_some(),
    })
}

/// POST /api/server/linear-key
pub async fn set_linear_key(
    State(registry): State<Arc<SessionRegistry>>,
    Json(body): Json<SetLinearKeyRequest>,
) -> ApiResult<LinearKeyStatusResponse> {
    info!(
        component = "mission_control",
        event = "api.linear_key.set",
        "Linear API key set via REST"
    );

    let _ = registry
        .persist()
        .send(PersistCommand::SetConfig {
            key: "linear_api_key".into(),
            value: body.key,
        })
        .await;

    Ok(Json(LinearKeyStatusResponse { configured: true }))
}

/// DELETE /api/server/linear-key
pub async fn delete_linear_key(
    State(registry): State<Arc<SessionRegistry>>,
) -> ApiResult<LinearKeyStatusResponse> {
    info!(
        component = "mission_control",
        event = "api.linear_key.deleted",
        "Linear API key deleted via REST"
    );

    let _ = registry
        .persist()
        .send(PersistCommand::SetConfig {
            key: "linear_api_key".into(),
            value: String::new(),
        })
        .await;

    Ok(Json(LinearKeyStatusResponse { configured: false }))
}

// ── Tracker keys endpoint ────────────────────────────────────────────

#[derive(Serialize)]
pub struct TrackerKeysResponse {
    pub linear: TrackerKeyInfo,
    pub github: TrackerKeyInfo,
}

#[derive(Serialize)]
pub struct TrackerKeyInfo {
    pub configured: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

/// GET /api/server/tracker-keys
pub async fn get_tracker_keys() -> Json<TrackerKeysResponse> {
    let linear_key = crate::support::api_keys::resolve_linear_api_key();
    let linear_source = if linear_key.is_some() {
        if std::env::var("LINEAR_API_KEY")
            .map(|k| !k.is_empty())
            .unwrap_or(false)
        {
            Some("env".to_string())
        } else {
            Some("settings".to_string())
        }
    } else {
        None
    };

    Json(TrackerKeysResponse {
        linear: TrackerKeyInfo {
            configured: linear_key.is_some(),
            source: linear_source,
        },
        github: TrackerKeyInfo {
            configured: false,
            source: None,
        },
    })
}

// ── Mission defaults endpoints ───────────────────────────────────────

#[derive(Serialize, Deserialize)]
pub struct MissionDefaultsResponse {
    pub provider_strategy: String,
    pub primary_provider: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary_provider: Option<String>,
}

/// GET /api/server/mission-defaults
pub async fn get_mission_defaults() -> Json<MissionDefaultsResponse> {
    let strategy =
        crate::infrastructure::persistence::load_config_value("mission_default_strategy")
            .unwrap_or_else(|| "single".to_string());
    let primary = crate::infrastructure::persistence::load_config_value("mission_default_primary")
        .unwrap_or_else(|| "claude".to_string());
    let secondary =
        crate::infrastructure::persistence::load_config_value("mission_default_secondary");

    Json(MissionDefaultsResponse {
        provider_strategy: strategy,
        primary_provider: primary,
        secondary_provider: secondary,
    })
}

#[derive(Deserialize)]
pub struct UpdateMissionDefaultsRequest {
    pub provider_strategy: Option<String>,
    pub primary_provider: Option<String>,
    pub secondary_provider: Option<Option<String>>,
}

/// PUT /api/server/mission-defaults
pub async fn update_mission_defaults(
    State(registry): State<Arc<SessionRegistry>>,
    Json(req): Json<UpdateMissionDefaultsRequest>,
) -> ApiResult<MissionDefaultsResponse> {
    if let Some(v) = &req.provider_strategy {
        let _ = registry
            .persist()
            .send(PersistCommand::SetConfig {
                key: "mission_default_strategy".into(),
                value: v.clone(),
            })
            .await;
    }
    if let Some(v) = &req.primary_provider {
        let _ = registry
            .persist()
            .send(PersistCommand::SetConfig {
                key: "mission_default_primary".into(),
                value: v.clone(),
            })
            .await;
    }
    if let Some(v) = &req.secondary_provider {
        let _ = registry
            .persist()
            .send(PersistCommand::SetConfig {
                key: "mission_default_secondary".into(),
                value: v.clone().unwrap_or_default(),
            })
            .await;
    }

    // Return current state
    let strategy = req
        .provider_strategy
        .or_else(|| {
            crate::infrastructure::persistence::load_config_value("mission_default_strategy")
        })
        .unwrap_or_else(|| "single".to_string());
    let primary = req
        .primary_provider
        .or_else(|| {
            crate::infrastructure::persistence::load_config_value("mission_default_primary")
        })
        .unwrap_or_else(|| "claude".to_string());
    let secondary = match req.secondary_provider {
        Some(v) => v,
        None => crate::infrastructure::persistence::load_config_value("mission_default_secondary"),
    };

    Ok(Json(MissionDefaultsResponse {
        provider_strategy: strategy,
        primary_provider: primary,
        secondary_provider: secondary,
    }))
}

// ── Start orchestrator endpoint ──────────────────────────────────────

/// POST /api/missions/:id/start-orchestrator
pub async fn start_mission_orchestrator_endpoint(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<serde_json::Value> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();
    let mission = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_by_id(&conn, &mid)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let api_key = crate::support::api_keys::resolve_linear_api_key()
        .ok_or_else(|| bad_request("no_api_key", "Linear API key not configured. Set it via POST /api/server/linear-key or LINEAR_API_KEY env var.".to_string()))?;

    let reg = registry.clone();
    tokio::spawn(async move {
        let tracker: std::sync::Arc<dyn crate::domain::mission_control::tracker::Tracker> =
            std::sync::Arc::new(crate::infrastructure::linear::client::LinearClient::new(
                api_key,
            ));
        crate::runtime::mission_orchestrator::start_mission_orchestrator(reg, tracker).await;
    });

    info!(
        component = "mission_control",
        event = "orchestrator.started_via_api",
        mission_id = %mission.id,
        "Orchestrator started via API"
    );

    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── Settings write-back endpoint ─────────────────────────────────────

/// PUT /api/missions/:id/settings
///
/// Partial update: reads current WORKFLOW.md, merges changes, writes back.
pub async fn update_mission_settings(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
    Json(req): Json<UpdateMissionSettingsRequest>,
) -> ApiResult<MissionDetailResponse> {
    let db_path = registry.db_path().clone();
    let mid = mission_id.clone();

    let mission = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_by_id(&conn, &mid)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    // Read + parse current WORKFLOW.md (or use defaults)
    let workflow_path = StdPath::new(&mission.repo_root).join("WORKFLOW.md");
    let (mut config, mut prompt_tmpl) =
        if let Ok(content) = tokio::fs::read_to_string(&workflow_path).await {
            match parse_workflow(&content) {
                Ok(w) => (w.config, w.prompt_template),
                Err(_) => (MissionConfig::default(), String::new()),
            }
        } else {
            (MissionConfig::default(), String::new())
        };

    // Merge request fields — Provider
    if let Some(v) = req.provider_strategy {
        config.provider.strategy = v;
    }
    if let Some(v) = req.primary_provider {
        config.provider.primary = v;
    }
    if let Some(v) = req.secondary_provider {
        config.provider.secondary = v;
    }
    if let Some(v) = req.max_concurrent {
        config.provider.max_concurrent = v;
    }
    if let Some(v) = req.max_concurrent_primary {
        config.provider.max_concurrent_primary = v;
    }

    // Trigger
    if let Some(v) = req.trigger_kind {
        config.trigger.kind = v;
    }
    if let Some(v) = req.poll_interval {
        config.trigger.interval = v;
    }
    if let Some(v) = req.label_filter {
        config.trigger.filters.labels = v;
    }
    if let Some(v) = req.state_filter {
        config.trigger.filters.states = v;
    }
    if let Some(v) = req.project_key {
        config.trigger.filters.project = v;
    }
    if let Some(v) = req.team_key {
        config.trigger.filters.team = v;
    }

    // Orchestration
    if let Some(v) = req.max_retries {
        config.orchestration.max_retries = v;
    }
    if let Some(v) = req.stall_timeout {
        config.orchestration.stall_timeout = v;
    }
    if let Some(v) = req.base_branch {
        config.orchestration.base_branch = v;
    }

    // Tracker
    if let Some(v) = req.tracker {
        config.tracker = v;
    }

    // Prompt
    if let Some(v) = req.prompt_template {
        prompt_tmpl = v;
    }

    // Serialize back to WORKFLOW.md
    let workflow_content =
        crate::domain::mission_control::config::serialize_workflow(&config, &prompt_tmpl).map_err(
            |e| {
                internal(
                    "serialize_error",
                    format!("Failed to serialize config: {e}"),
                )
            },
        )?;

    tokio::fs::write(&workflow_path, &workflow_content)
        .await
        .map_err(|e| internal("write_error", format!("Failed to write WORKFLOW.md: {e}")))?;

    // Persist to DB
    let config_json = serde_json::to_string(&config).unwrap_or_default();
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            enabled: None,
            paused: None,
            config_json: Some(config_json.clone()),
            prompt_template: Some(prompt_tmpl.clone()),
            parse_error: Some(None),
        })
        .await;

    info!(
        component = "mission_control",
        event = "settings.updated",
        mission_id = %mission_id,
        "Mission settings updated via API"
    );

    // Return fresh detail response
    let db_path = registry.db_path().clone();
    let mid2 = mission_id.clone();
    let issue_rows = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        load_mission_issues(&conn, &mid2)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))?;

    let summary = mission_row_to_summary_with_issues(&mission, &issue_rows);
    let issues = issue_rows.into_iter().map(issue_row_to_item).collect();
    let settings = config_to_settings_response(&config, &prompt_tmpl);

    Ok(Json(MissionDetailResponse {
        summary,
        issues,
        settings: Some(settings),
        workflow_exists: true,
    }))
}

// ── Internal helpers ─────────────────────────────────────────────────

fn parse_provider(s: &str) -> Provider {
    match s {
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    }
}

fn config_to_settings_response(
    config: &MissionConfig,
    prompt_template: &str,
) -> MissionSettingsResponse {
    MissionSettingsResponse {
        provider: ProviderSettingsResponse {
            strategy: config.provider.strategy.clone(),
            primary: config.provider.primary.clone(),
            secondary: config.provider.secondary.clone(),
            max_concurrent: config.provider.max_concurrent,
            max_concurrent_primary: config.provider.max_concurrent_primary,
        },
        trigger: TriggerSettingsResponse {
            kind: config.trigger.kind.clone(),
            interval: config.trigger.interval,
            filters: TriggerFiltersResponse {
                labels: config.trigger.filters.labels.clone(),
                states: config.trigger.filters.states.clone(),
                project: config.trigger.filters.project.clone(),
                team: config.trigger.filters.team.clone(),
            },
        },
        orchestration: OrchestrationSettingsResponse {
            max_retries: config.orchestration.max_retries,
            stall_timeout: config.orchestration.stall_timeout,
            base_branch: config.orchestration.base_branch.clone(),
        },
        prompt_template: prompt_template.to_string(),
        tracker: config.tracker.clone(),
    }
}

fn build_settings_response(mission: &MissionRow) -> Option<MissionSettingsResponse> {
    let config_json = mission.config_json.as_ref()?;
    let config: MissionConfig = serde_json::from_str(config_json).ok()?;
    let prompt_template = mission.prompt_template.clone().unwrap_or_default();
    Some(config_to_settings_response(&config, &prompt_template))
}

fn compute_orchestrator_status(row: &MissionRow) -> Option<String> {
    if !row.enabled {
        return Some("disabled".to_string());
    }
    if row.paused {
        return Some("paused".to_string());
    }
    if row.parse_error.is_some() {
        return Some("config_error".to_string());
    }
    if crate::support::api_keys::resolve_linear_api_key().is_none() {
        return Some("no_api_key".to_string());
    }
    Some("polling".to_string())
}

/// Build MissionSummary from row, pulling provider strategy from config_json if available.
fn summary_from_row(
    row: &MissionRow,
    active: u32,
    queued: u32,
    completed: u32,
    failed: u32,
) -> MissionSummary {
    let primary_provider = parse_provider(&row.provider);
    let orchestrator_status = compute_orchestrator_status(row);

    // Try to pull strategy from parsed config
    let (strategy, secondary) = if let Some(ref json) = row.config_json {
        if let Ok(config) = serde_json::from_str::<MissionConfig>(json) {
            (
                config.provider.strategy.clone(),
                config
                    .provider
                    .secondary
                    .as_ref()
                    .map(|s| parse_provider(s)),
            )
        } else {
            ("single".to_string(), None)
        }
    } else {
        ("single".to_string(), None)
    };

    MissionSummary {
        id: row.id.clone(),
        repo_root: row.repo_root.clone(),
        enabled: row.enabled,
        paused: row.paused,
        tracker_kind: row.tracker_kind.clone(),
        provider: primary_provider,
        provider_strategy: strategy,
        primary_provider,
        secondary_provider: secondary,
        active_count: active,
        queued_count: queued,
        completed_count: completed,
        failed_count: failed,
        parse_error: row.parse_error.clone(),
        orchestrator_status,
    }
}

fn mission_row_to_summary(row: &MissionRow) -> MissionSummary {
    summary_from_row(row, 0, 0, 0, 0)
}

fn mission_row_to_summary_with_issues(
    row: &MissionRow,
    issue_rows: &[MissionIssueRow],
) -> MissionSummary {
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

    summary_from_row(
        row,
        active_count,
        queued_count,
        completed_count,
        failed_count,
    )
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
        url: row.url,
        last_activity: None,
    }
}
