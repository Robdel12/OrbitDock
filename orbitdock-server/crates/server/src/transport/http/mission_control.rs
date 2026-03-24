use std::path::Path as StdPath;
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::Json;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use tracing::info;

use orbitdock_protocol::{MissionIssueItem, MissionSummary, OrchestrationState, Provider};

use crate::domain::mission_control::compute_orchestrator_status;
use crate::domain::mission_control::config::{
    generate_scaffold, migrate_workflow_content, parse_mission_file, try_parse_symphony_workflow,
    MissionConfig, MissionConfigUpdate,
};
use crate::domain::mission_control::template::default_mission_template;
use crate::infrastructure::persistence::{
    load_mission_by_id, load_mission_issues, load_missions_with_counts, MissionIssueRow,
    MissionRow, PersistCommand,
};
use crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id;
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
    pub mission_file_exists: bool,
    pub mission_file_path: Option<String>,
    /// True when a WORKFLOW.md with Symphony-compatible settings exists
    /// and can be migrated to MISSION.md.
    pub workflow_migration_available: bool,
}

#[derive(Serialize)]
pub struct MissionSettingsResponse {
    #[serde(flatten)]
    pub config: MissionConfig,
    pub prompt_template: String,
}

// ── Request types ────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct CreateMissionRequest {
    pub name: String,
    pub repo_root: String,
    #[serde(default = "default_tracker")]
    pub tracker_kind: String,
    #[serde(default = "default_provider")]
    pub provider: String,
}

fn default_tracker() -> String {
    "linear".to_string()
}

fn slugify_mission_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

fn default_provider() -> String {
    "claude".to_string()
}

#[derive(Deserialize)]
pub struct UpdateMissionRequest {
    pub name: Option<String>,
    pub enabled: Option<bool>,
    pub paused: Option<bool>,
    pub mission_file_path: Option<Option<String>>,
}

#[derive(Deserialize)]
pub struct UpdateMissionSettingsRequest {
    // Provider
    pub provider_strategy: Option<String>,
    pub primary_provider: Option<String>,
    pub secondary_provider: Option<Option<String>>,
    pub max_concurrent: Option<u32>,
    pub max_concurrent_primary: Option<Option<u32>>,
    // Agent — Claude
    pub agent_claude_model: Option<Option<String>>,
    pub agent_claude_effort: Option<Option<String>>,
    pub agent_claude_permission_mode: Option<Option<String>>,
    pub agent_claude_allowed_tools: Option<Vec<String>>,
    pub agent_claude_disallowed_tools: Option<Vec<String>>,
    pub agent_claude_allow_bypass_permissions: Option<bool>,
    // Agent — Codex
    pub agent_codex_model: Option<Option<String>>,
    pub agent_codex_effort: Option<Option<String>>,
    pub agent_codex_approval_policy: Option<Option<String>>,
    pub agent_codex_sandbox_mode: Option<Option<String>>,
    pub agent_codex_collaboration_mode: Option<Option<String>>,
    pub agent_codex_multi_agent: Option<Option<bool>>,
    pub agent_codex_personality: Option<Option<String>>,
    pub agent_codex_service_tier: Option<Option<String>>,
    pub agent_codex_developer_instructions: Option<Option<String>>,
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
    pub worktree_root_dir: Option<Option<String>>,
    pub state_on_dispatch: Option<String>,
    pub state_on_complete: Option<String>,
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
    let orchestrator_running = registry.is_orchestrator_running();
    let rows = db_read(&registry, load_missions_with_counts).await?;

    let missions = rows
        .into_iter()
        .map(|(r, (active, queued, completed, failed))| {
            summary_from_row(&r, active, queued, completed, failed, orchestrator_running)
        })
        .collect();

    Ok(Json(MissionsListResponse { missions }))
}

/// POST /api/missions
pub async fn create_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Json(req): Json<CreateMissionRequest>,
) -> ApiResult<MissionSummary> {
    // Validate that repo_root is a git repository
    let git_dir = StdPath::new(&req.repo_root).join(".git");
    if tokio::fs::metadata(&git_dir).await.is_err() {
        return Err(bad_request(
            "not_git_repo",
            format!("Directory is not a git repository: {}", req.repo_root),
        ));
    }

    let id = orbitdock_protocol::new_id();

    // Auto-generate a unique mission file path if this repo already has missions
    let repo_for_count = req.repo_root.clone();
    let existing_count = db_read(&registry, move |conn| {
        crate::infrastructure::persistence::mission_control::count_missions_by_repo_root(
            conn,
            &repo_for_count,
        )
    })
    .await?;

    let mission_file_path = if existing_count > 0 {
        let slug = slugify_mission_name(&req.name);
        Some(format!("MISSION-{slug}.md"))
    } else {
        Some("MISSION.md".to_string())
    };

    let _ = registry
        .persist()
        .send(PersistCommand::MissionCreate {
            id: id.clone(),
            name: req.name.clone(),
            repo_root: req.repo_root.clone(),
            tracker_kind: req.tracker_kind.clone(),
            provider: req.provider.clone(),
            config_json: None,
            prompt_template: None,
            mission_file_path: mission_file_path.clone(),
        })
        .await;

    info!(
        component = "mission_control",
        event = "mission.created",
        mission_id = %id,
        repo_root = %req.repo_root,
        "Mission created"
    );

    let primary_provider = req.provider.parse::<Provider>().map_err(|_| {
        bad_request(
            "invalid_provider",
            format!("Invalid provider: {}", req.provider),
        )
    })?;

    let orchestrator_status =
        if crate::support::api_keys::resolve_tracker_api_key(&req.tracker_kind).is_none() {
            Some("no_api_key".to_string())
        } else {
            Some("polling".to_string())
        };

    Ok(Json(MissionSummary {
        id,
        name: req.name,
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
        last_polled_at: None,
        poll_interval: None,
        mission_file_path,
    }))
}

/// GET /api/missions/:id
pub async fn get_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionDetailResponse> {
    let mid = mission_id.clone();
    let (mission_row, issue_rows) = db_read(&registry, move |conn| {
        let mission = load_mission_by_id(conn, &mid)?;
        let issues = if mission.is_some() {
            load_mission_issues(conn, &mid)?
        } else {
            vec![]
        };
        Ok((mission, issues))
    })
    .await?;

    let mission = mission_row
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let orchestrator_running = registry.is_orchestrator_running();
    let response = build_detail_response(
        &registry,
        &mission,
        issue_rows,
        orchestrator_running,
        None,
        true,
    )
    .await;
    Ok(Json(response))
}

/// PUT /api/missions/:id
pub async fn update_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
    Json(req): Json<UpdateMissionRequest>,
) -> ApiResult<MissionDetailResponse> {
    // Read current mission state
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    // Apply changes in memory for the response (avoids async persist race)
    let mut updated = mission.clone();
    if let Some(name) = &req.name {
        updated.name = name.clone();
    }
    if let Some(enabled) = req.enabled {
        updated.enabled = enabled;
    }
    if let Some(paused) = req.paused {
        updated.paused = paused;
    }

    // Persist asynchronously
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            name: req.name,
            enabled: req.enabled,
            paused: req.paused,
            tracker_kind: None,
            config_json: None,
            prompt_template: None,
            parse_error: None,
            mission_file_path: req.mission_file_path,
        })
        .await;

    // Build response from the in-memory updated state
    let mid2 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid2)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let response = build_detail_response(
        &registry,
        &updated,
        issue_rows,
        orchestrator_running,
        None,
        false,
    )
    .await;
    Ok(Json(response))
}

/// DELETE /api/missions/:id
pub async fn delete_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionsListResponse> {
    let _ = registry
        .persist()
        .send(PersistCommand::MissionDelete {
            id: mission_id.clone(),
        })
        .await;

    // Return the updated missions list, excluding the just-deleted mission.
    // The persist is async so the DB may still include it — filter client-side.
    let orchestrator_running = registry.is_orchestrator_running();
    let rows = db_read(&registry, load_missions_with_counts).await?;
    let missions: Vec<MissionSummary> = rows
        .into_iter()
        .filter(|(row, _)| row.id != mission_id)
        .map(|(row, (active, queued, completed, failed))| {
            summary_from_row(
                &row,
                active,
                queued,
                completed,
                failed,
                orchestrator_running,
            )
        })
        .collect();

    Ok(Json(MissionsListResponse { missions }))
}

/// GET /api/missions/:id/issues
pub async fn list_mission_issues(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<Vec<MissionIssueItem>> {
    let mid = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid)).await?;

    let items: Vec<MissionIssueItem> = issue_rows
        .into_iter()
        .map(|row| issue_row_to_item(row, &registry))
        .collect();
    Ok(Json(items))
}

/// POST /api/missions/:mission_id/issues/:issue_id/retry
///
/// Re-queues an issue for dispatch. Works from any state:
/// - If running/claimed: ends the active session first
/// - Resets to "queued" with attempt reset to 0
/// - The orchestrator will pick it up on the next tick
pub async fn retry_mission_issue(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
) -> ApiResult<MissionDetailResponse> {
    let mid = mission_id.clone();
    let iid = issue_id.clone();

    let issue_row = db_read(&registry, move |conn| {
        let mut stmt = conn.prepare(
            "SELECT id, orchestration_state, attempt, session_id FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
        )?;
        let row = stmt.query_row(params![mid, iid], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        });
        match row {
            Ok(r) => Ok(Some(r)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(anyhow::anyhow!(e)),
        }
    })
    .await?;

    let (_row_id, state, _attempt, session_id) = issue_row.ok_or_else(|| {
        not_found(
            "not_found",
            format!("Issue {issue_id} not found in mission {mission_id}"),
        )
    })?;

    // End any active session before re-queuing
    if state == "running" || state == "claimed" {
        if let Some(ref sid) = session_id {
            crate::runtime::session_mutations::end_session(&registry, sid).await;
        }
    }

    // Reset to queued — synchronous write so the response is authoritative
    let db_path = registry.db_path().clone();
    let mid2 = mission_id.clone();
    let iid2 = issue_id.clone();
    let _ = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path).ok()?;
        use crate::infrastructure::persistence::mission_control::{
            update_mission_issue_state_sync, MissionIssueStateUpdate,
        };
        update_mission_issue_state_sync(
            &conn,
            &mid2,
            &iid2,
            &MissionIssueStateUpdate {
                orchestration_state: "queued",
                session_id: None,
                attempt: Some(0),
                last_error: Some(None),
                started_at: Some(None),
                completed_at: Some(None),
            },
        )
        .ok()
    })
    .await;

    info!(
        component = "mission_control",
        event = "issue.requeued",
        mission_id = %mission_id,
        issue_id = %issue_id,
        previous_state = %state,
        "Issue re-queued for dispatch"
    );

    // Return fresh detail
    let mid3 = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid3))
        .await?
        .ok_or_else(|| not_found("not_found", "Mission not found"))?;
    let mid4 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid4)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let response = build_detail_response(
        &registry,
        &mission,
        issue_rows,
        orchestrator_running,
        None,
        false,
    )
    .await;
    Ok(Json(response))
}

/// POST /api/missions/:mission_id/issues/:issue_id/transition
///
/// Admin state transition endpoint. Validates the transition against the
/// state machine, applies appropriate side effects, and returns fresh state.
pub async fn transition_mission_issue(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
    Json(body): Json<TransitionRequest>,
) -> ApiResult<MissionDetailResponse> {
    let target = OrchestrationState::from_db_str(&body.target_state).ok_or_else(|| {
        bad_request(
            "invalid_state",
            format!("Unknown orchestration state: {}", body.target_state),
        )
    })?;

    let mid = mission_id.clone();
    let iid = issue_id.clone();

    let issue_row = db_read(&registry, move |conn| {
        let mut stmt = conn.prepare(
            "SELECT id, orchestration_state, session_id FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
        )?;
        let row = stmt.query_row(params![mid, iid], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        });
        match row {
            Ok(r) => Ok(Some(r)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(anyhow::anyhow!(e)),
        }
    })
    .await?;

    let (_row_id, current_state_str, session_id) = issue_row.ok_or_else(|| {
        not_found(
            "not_found",
            format!("Issue {issue_id} not found in mission {mission_id}"),
        )
    })?;

    let current_state =
        OrchestrationState::from_db_str(&current_state_str).unwrap_or(OrchestrationState::Queued);

    if !current_state.can_transition_to(&target) {
        return Err(bad_request(
            "invalid_transition",
            format!(
                "Cannot transition from {} to {}",
                current_state_str, body.target_state
            ),
        ));
    }

    // End any active session when leaving an active state
    if current_state == OrchestrationState::Running || current_state == OrchestrationState::Claimed
    {
        if let Some(ref sid) = session_id {
            crate::runtime::session_mutations::end_session(&registry, sid).await;
        }
    }

    // Build the state update based on target
    let now = chrono::Utc::now().to_rfc3339();
    let reason = body.reason.clone();
    let db_path = registry.db_path().clone();
    let mid2 = mission_id.clone();
    let iid2 = issue_id.clone();
    let target_str = target.as_db_str().to_string();

    let _ = tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path).ok()?;
        use crate::infrastructure::persistence::mission_control::{
            update_mission_issue_state_sync, MissionIssueStateUpdate,
        };

        let update = match target {
            OrchestrationState::Queued => MissionIssueStateUpdate {
                orchestration_state: &target_str,
                session_id: None,
                attempt: Some(0),
                last_error: Some(None),
                started_at: Some(None),
                completed_at: Some(None),
            },
            OrchestrationState::Completed => MissionIssueStateUpdate {
                orchestration_state: &target_str,
                session_id: None,
                attempt: None,
                last_error: Some(None),
                started_at: None,
                completed_at: Some(Some(&now)),
            },
            OrchestrationState::Failed => MissionIssueStateUpdate {
                orchestration_state: &target_str,
                session_id: None,
                attempt: None,
                last_error: Some(Some(reason.as_deref().unwrap_or("Manually stopped"))),
                started_at: None,
                completed_at: Some(Some(&now)),
            },
            OrchestrationState::Blocked => MissionIssueStateUpdate {
                orchestration_state: &target_str,
                session_id: None,
                attempt: None,
                last_error: Some(Some(reason.as_deref().unwrap_or("Manually blocked"))),
                started_at: None,
                completed_at: Some(Some(&now)),
            },
            // claimed, running, retry_queued — not valid admin targets
            _ => return None,
        };

        update_mission_issue_state_sync(&conn, &mid2, &iid2, &update).ok()
    })
    .await;

    info!(
        component = "mission_control",
        event = "issue.admin_transition",
        mission_id = %mission_id,
        issue_id = %issue_id,
        from = %current_state_str,
        to = %body.target_state,
        reason = ?body.reason,
        "Admin state transition applied"
    );

    // Broadcast updated state
    broadcast_mission_delta_by_id(&registry, &mission_id).await;

    // When re-queuing an issue, trigger an immediate orchestrator tick so it gets picked up now
    if target == OrchestrationState::Queued {
        registry.trigger_mission(mission_id.clone()).await;
    }

    // Return fresh detail
    let mid3 = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid3))
        .await?
        .ok_or_else(|| not_found("not_found", "Mission not found"))?;
    let mid4 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid4)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let response = build_detail_response(
        &registry,
        &mission,
        issue_rows,
        orchestrator_running,
        None,
        false,
    )
    .await;
    Ok(Json(response))
}

/// POST /api/missions/:id/scaffold
///
/// Writes a default MISSION.md template to the mission's repo_root.
/// Returns 409 if the file already exists.
pub async fn scaffold_mission_file(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionDetailResponse> {
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let mission_file_path = mission.resolved_mission_path();

    // Don't overwrite an existing MISSION.md
    if tokio::fs::metadata(&mission_file_path).await.is_ok() {
        return Err(conflict(
            "mission_file_exists",
            "MISSION.md already exists in this repository",
        ));
    }

    // Generate scaffold via domain logic
    let (file_content, config, prompt_template) =
        generate_scaffold(&mission.provider, &mission.tracker_kind).map_err(|e| {
            internal(
                "scaffold_error",
                format!("Failed to generate scaffold: {e}"),
            )
        })?;

    // Write to disk
    tokio::fs::write(&mission_file_path, &file_content)
        .await
        .map_err(|e| internal("write_error", format!("Failed to write MISSION.md: {e}")))?;

    info!(
        component = "mission_control",
        event = "mission_file.scaffolded",
        mission_id = %mission_id,
        repo_root = %mission.repo_root,
        "Scaffolded MISSION.md"
    );

    // Persist to DB
    let config_json = serde_json::to_string(&config).unwrap_or_default();
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            name: None,
            enabled: None,
            paused: None,
            tracker_kind: None,
            config_json: Some(config_json),
            prompt_template: Some(prompt_template.clone()),
            parse_error: Some(None),
            mission_file_path: None,
        })
        .await;

    // Build response matching get_mission format
    let mid2 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid2)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let settings = MissionSettingsResponse {
        config,
        prompt_template,
    };
    let response = build_detail_response(
        &registry,
        &mission,
        issue_rows,
        orchestrator_running,
        Some(settings),
        false,
    )
    .await;
    Ok(Json(response))
}

// ── Workflow migration endpoint ──────────────────────────────────────

/// POST /api/missions/:id/migrate-workflow
///
/// Reads an existing WORKFLOW.md (Symphony format), extracts settings,
/// and writes a MISSION.md with the converted config.
pub async fn migrate_workflow_to_mission(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<MissionDetailResponse> {
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let mission_path = mission.resolved_mission_path();
    if tokio::fs::metadata(&mission_path).await.is_ok() {
        return Err(conflict(
            "mission_file_exists",
            "MISSION.md already exists in this repository",
        ));
    }

    let workflow_path = StdPath::new(&mission.repo_root).join("WORKFLOW.md");
    let workflow_content = tokio::fs::read_to_string(&workflow_path)
        .await
        .map_err(|_| not_found("no_workflow", "No WORKFLOW.md found to migrate"))?;

    // Convert via domain logic
    let (file_content, config, prompt_template) =
        migrate_workflow_content(&workflow_content, &mission.provider)
            .map_err(|e| bad_request("no_symphony_config", format!("{e}")))?;

    // Write to disk
    tokio::fs::write(&mission_path, &file_content)
        .await
        .map_err(|e| internal("write_error", format!("Failed to write MISSION.md: {e}")))?;

    // Persist to DB
    let config_json = serde_json::to_string(&config).unwrap_or_default();
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            name: None,
            enabled: None,
            paused: None,
            tracker_kind: None,
            config_json: Some(config_json),
            prompt_template: Some(prompt_template.clone()),
            parse_error: Some(None),
            mission_file_path: None,
        })
        .await;

    info!(
        component = "mission_control",
        event = "workflow.migrated",
        mission_id = %mission_id,
        "Migrated WORKFLOW.md → MISSION.md"
    );

    // Return fresh detail
    let mid2 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid2)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let settings = MissionSettingsResponse {
        config,
        prompt_template,
    };
    let response = build_detail_response(
        &registry,
        &mission,
        issue_rows,
        orchestrator_running,
        Some(settings),
        false,
    )
    .await;
    Ok(Json(response))
}

// ── Default template endpoint ────────────────────────────────────────

#[derive(Serialize)]
pub struct DefaultTemplateResponse {
    pub template: String,
}

/// GET /api/missions/:id/default-template
pub async fn get_default_template(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<DefaultTemplateResponse> {
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let full_template = default_mission_template(&mission.provider, &mission.tracker_kind);
    let template_body = parse_mission_file(&full_template)
        .map(|def| def.prompt_template)
        .unwrap_or_default();

    Ok(Json(DefaultTemplateResponse {
        template: template_body,
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

// ── GitHub API key endpoints ────────────────────────────────────────

#[derive(Serialize)]
pub struct GitHubKeyStatusResponse {
    pub configured: bool,
}

#[derive(Deserialize)]
pub struct SetGitHubKeyRequest {
    pub key: String,
}

/// GET /api/server/github-key
pub async fn check_github_key() -> Json<GitHubKeyStatusResponse> {
    Json(GitHubKeyStatusResponse {
        configured: crate::support::api_keys::resolve_github_api_key().is_some(),
    })
}

/// POST /api/server/github-key
pub async fn set_github_key(
    State(registry): State<Arc<SessionRegistry>>,
    Json(body): Json<SetGitHubKeyRequest>,
) -> ApiResult<GitHubKeyStatusResponse> {
    info!(
        component = "mission_control",
        event = "api.github_key.set",
        "GitHub token set via REST"
    );

    let _ = registry
        .persist()
        .send(PersistCommand::SetConfig {
            key: "github_api_key".into(),
            value: body.key,
        })
        .await;

    Ok(Json(GitHubKeyStatusResponse { configured: true }))
}

/// DELETE /api/server/github-key
pub async fn delete_github_key(
    State(registry): State<Arc<SessionRegistry>>,
) -> ApiResult<GitHubKeyStatusResponse> {
    info!(
        component = "mission_control",
        event = "api.github_key.deleted",
        "GitHub token deleted via REST"
    );

    let _ = registry
        .persist()
        .send(PersistCommand::SetConfig {
            key: "github_api_key".into(),
            value: String::new(),
        })
        .await;

    Ok(Json(GitHubKeyStatusResponse { configured: false }))
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

    let github_key = crate::support::api_keys::resolve_github_api_key();
    let github_source = if github_key.is_some() {
        if std::env::var("GITHUB_TOKEN")
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
            configured: github_key.is_some(),
            source: github_source,
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
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    let tracker_kind = mission.tracker_kind.clone();
    let tracker = crate::support::api_keys::build_tracker(&tracker_kind)
        .map_err(|e| bad_request("no_api_key", e.to_string()))?;

    if !registry.try_start_orchestrator() {
        return Err(conflict(
            "already_running",
            "Orchestrator is already running",
        ));
    }

    let reg = registry.clone();
    tokio::spawn(async move {
        crate::runtime::mission_orchestrator::start_mission_orchestrator(reg.clone(), tracker)
            .await;
        // If the loop ever exits, release the guard
        reg.stop_orchestrator();
    });

    info!(
        component = "mission_control",
        event = "orchestrator.started_via_api",
        mission_id = %mission.id,
        "Orchestrator started via API"
    );

    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── Manual dispatch endpoint ─────────────────────────────────────────

#[derive(Deserialize)]
pub struct ManualDispatchRequest {
    /// Issue identifier (e.g. "VIZ-240" for Linear, "owner/repo#42" for GitHub)
    pub issue_identifier: String,
    /// Optional provider override (defaults to mission's primary)
    pub provider: Option<String>,
}

/// POST /api/missions/:id/dispatch
///
/// Manually dispatch a specific issue from the tracker to a mission.
pub async fn dispatch_mission_issue(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
    Json(req): Json<ManualDispatchRequest>,
) -> ApiResult<MissionDetailResponse> {
    // 1. Load mission
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    // 2. Build tracker for this mission's kind
    let tracker = crate::support::api_keys::build_tracker(&mission.tracker_kind)
        .map_err(|e| bad_request("no_api_key", e.to_string()))?;

    // 3. Parse MISSION.md
    let mission_file_path = mission.resolved_mission_path();
    let mission_content = tokio::fs::read_to_string(&mission_file_path)
        .await
        .map_err(|e| bad_request("mission_file", format!("Cannot read MISSION.md: {e}")))?;
    let workflow = parse_mission_file(&mission_content)
        .map_err(|e| bad_request("parse_error", format!("MISSION.md parse error: {e}")))?;

    // 4. Fetch issue from tracker
    let issue = tracker
        .fetch_issue_by_identifier(&req.issue_identifier)
        .await
        .map_err(|e| internal("tracker_error", format!("Tracker query failed: {e}")))?
        .ok_or_else(|| {
            not_found(
                "issue_not_found",
                format!("Issue {} not found", req.issue_identifier),
            )
        })?;

    // 5. Upsert into mission_issues
    let issue_row_id = orbitdock_protocol::new_id();
    let provider_str = req
        .provider
        .unwrap_or_else(|| workflow.config.provider.primary.clone());
    registry
        .persist()
        .send(PersistCommand::MissionIssueUpsert {
            id: issue_row_id,
            mission_id: mission.id.clone(),
            issue_id: issue.id.clone(),
            issue_identifier: issue.identifier.clone(),
            issue_title: Some(issue.title.clone()),
            issue_state: Some(issue.state.clone()),
            orchestration_state: "queued".to_string(),
            provider: Some(provider_str.clone()),
            url: issue.url.clone(),
        })
        .await
        .map_err(|e| internal("persist_error", format!("Failed to upsert issue: {e}")))?;

    // 6. Spawn dispatch (reuse the tracker built in step 2)

    let reg = registry.clone();
    let mid_dispatch = mission.id.clone();
    let ctx = crate::runtime::mission_dispatch::DispatchContext {
        repo_root: mission.repo_root.clone(),
        prompt_template: workflow.prompt_template.clone(),
        base_branch: workflow.config.orchestration.base_branch.clone(),
        agent_config: workflow.config.agent.clone(),
        worktree_root_dir: workflow.config.orchestration.worktree_root_dir.clone(),
        state_on_dispatch: workflow.config.orchestration.state_on_dispatch.clone(),
    };

    tokio::spawn(async move {
        let result = crate::runtime::mission_dispatch::dispatch_issue(
            &reg,
            &mid_dispatch,
            &issue,
            &provider_str,
            &ctx,
            1,
            &tracker,
        )
        .await;

        if let Err(ref err) = result {
            tracing::error!(
                component = "mission_control",
                event = "dispatch.manual_failed",
                mission_id = %mid_dispatch,
                error = %err,
                "Manual dispatch failed"
            );
        }

        crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id(&reg, &mid_dispatch)
            .await;
    });

    info!(
        component = "mission_control",
        event = "dispatch.manual_started",
        mission_id = %mission.id,
        issue_identifier = %req.issue_identifier,
        "Manual dispatch started"
    );

    // 7. Return fresh detail
    let mid3 = mission.id.clone();
    let mid4 = mission.id.clone();
    let mission_row = db_read(&registry, move |conn| load_mission_by_id(conn, &mid3))
        .await?
        .ok_or_else(|| not_found("not_found", "Mission not found"))?;
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid4)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let response = build_detail_response(
        &registry,
        &mission_row,
        issue_rows,
        orchestrator_running,
        None,
        false,
    )
    .await;
    Ok(Json(response))
}

// ── Manual trigger endpoint ──────────────────────────────────────────

/// POST /api/missions/:id/trigger
///
/// Force an immediate poll for a mission, bypassing the interval gate.
pub async fn trigger_mission_poll(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<serde_json::Value> {
    // Validate mission exists
    let mid = mission_id.clone();
    let _mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    if !registry.is_orchestrator_running() {
        return Err(bad_request(
            "orchestrator_not_running",
            "Orchestrator is not running",
        ));
    }

    registry.trigger_mission(mission_id).await;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── Settings write-back endpoint ─────────────────────────────────────

/// PUT /api/missions/:id/settings
///
/// Partial update: reads current MISSION.md, merges changes, writes back.
pub async fn update_mission_settings(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
    Json(req): Json<UpdateMissionSettingsRequest>,
) -> ApiResult<MissionDetailResponse> {
    let mid = mission_id.clone();
    let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
        .await?
        .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

    // Read + parse current MISSION.md (or use defaults)
    let mission_file_path = mission.resolved_mission_path();
    let existing_file_content = tokio::fs::read_to_string(&mission_file_path).await.ok();
    let (mut config, mut prompt_tmpl) = if let Some(ref content) = existing_file_content {
        match parse_mission_file(content) {
            Ok(w) => (w.config, w.prompt_template),
            Err(_) => (MissionConfig::default(), String::new()),
        }
    } else {
        (MissionConfig::default(), String::new())
    };

    // Capture tracker update before moving req fields
    let tracker_kind_update = req.tracker.clone();

    // Merge request fields into config
    config.apply_update(MissionConfigUpdate {
        provider_strategy: req.provider_strategy,
        primary_provider: req.primary_provider,
        secondary_provider: req.secondary_provider,
        max_concurrent: req.max_concurrent,
        max_concurrent_primary: req.max_concurrent_primary,
        agent_claude_model: req.agent_claude_model,
        agent_claude_effort: req.agent_claude_effort,
        agent_claude_permission_mode: req.agent_claude_permission_mode,
        agent_claude_allowed_tools: req.agent_claude_allowed_tools,
        agent_claude_disallowed_tools: req.agent_claude_disallowed_tools,
        agent_claude_allow_bypass_permissions: req.agent_claude_allow_bypass_permissions,
        agent_codex_model: req.agent_codex_model,
        agent_codex_effort: req.agent_codex_effort,
        agent_codex_approval_policy: req.agent_codex_approval_policy,
        agent_codex_sandbox_mode: req.agent_codex_sandbox_mode,
        agent_codex_collaboration_mode: req.agent_codex_collaboration_mode,
        agent_codex_multi_agent: req.agent_codex_multi_agent,
        agent_codex_personality: req.agent_codex_personality,
        agent_codex_service_tier: req.agent_codex_service_tier,
        agent_codex_developer_instructions: req.agent_codex_developer_instructions,
        trigger_kind: req.trigger_kind,
        poll_interval: req.poll_interval,
        label_filter: req.label_filter,
        state_filter: req.state_filter,
        project_key: req.project_key,
        team_key: req.team_key,
        max_retries: req.max_retries,
        stall_timeout: req.stall_timeout,
        base_branch: req.base_branch,
        worktree_root_dir: req.worktree_root_dir,
        state_on_dispatch: req.state_on_dispatch,
        state_on_complete: req.state_on_complete,
        tracker: req.tracker,
    });

    // Prompt
    if let Some(v) = req.prompt_template {
        prompt_tmpl = v;
    }

    // Serialize back to MISSION.md
    let mission_content =
        crate::domain::mission_control::config::serialize_mission_file_preserving(
            &config,
            &prompt_tmpl,
            existing_file_content.as_deref(),
        )
        .map_err(|e| {
            internal(
                "serialize_error",
                format!("Failed to serialize config: {e}"),
            )
        })?;

    tokio::fs::write(&mission_file_path, &mission_content)
        .await
        .map_err(|e| internal("write_error", format!("Failed to write MISSION.md: {e}")))?;

    // Persist to DB — keep tracker_kind in lockstep with config.tracker
    let config_json = serde_json::to_string(&config).unwrap_or_default();
    let _ = registry
        .persist()
        .send(PersistCommand::MissionUpdate {
            id: mission_id.clone(),
            name: None,
            enabled: None,
            paused: None,
            tracker_kind: tracker_kind_update.clone(),
            config_json: Some(config_json.clone()),
            prompt_template: Some(prompt_tmpl.clone()),
            parse_error: Some(None),
            mission_file_path: None,
        })
        .await;

    // Update in-memory mission so the response reflects the new tracker_kind
    let mut updated_mission = mission.clone();
    if let Some(ref tk) = tracker_kind_update {
        updated_mission.tracker_kind = tk.clone();
    }

    info!(
        component = "mission_control",
        event = "settings.updated",
        mission_id = %mission_id,
        "Mission settings updated via API"
    );

    // Return fresh detail response
    let mid2 = mission_id.clone();
    let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid2)).await?;
    let orchestrator_running = registry.is_orchestrator_running();
    let settings = MissionSettingsResponse {
        config,
        prompt_template: prompt_tmpl,
    };
    let response = build_detail_response(
        &registry,
        &updated_mission,
        issue_rows,
        orchestrator_running,
        Some(settings),
        false,
    )
    .await;
    Ok(Json(response))
}

// ── Mission issue PR linking ─────────────────────────────────────────

#[derive(Deserialize)]
pub struct SetPrUrlRequest {
    pub pr_url: String,
}

/// POST /api/missions/:mission_id/issues/:issue_id/pr
///
/// Called by the MCP mission tools when an agent links a PR via `mission_link_pr`.
/// Stores the PR URL on the mission issue for display in the UI.
pub async fn set_issue_pr_url(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
    Json(body): Json<SetPrUrlRequest>,
) -> ApiResult<serde_json::Value> {
    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueSetPrUrl {
            mission_id: mission_id.clone(),
            issue_id: issue_id.clone(),
            pr_url: body.pr_url.clone(),
        })
        .await;

    broadcast_mission_delta_by_id(&registry, &mission_id).await;

    Ok(Json(serde_json::json!({ "ok": true })))
}

// ── Mission worktree listing ─────────────────────────────────────────

#[derive(Serialize)]
pub struct MissionWorktreeItem {
    pub id: String,
    pub branch: String,
    pub worktree_path: String,
    pub disk_present: bool,
    pub orchestration_state: OrchestrationState,
    pub issue_identifier: String,
    pub issue_title: String,
}

/// GET /api/missions/:mission_id/worktrees
///
/// Returns all worktrees associated with a mission's issues (via sessions).
pub async fn list_mission_worktrees(
    State(registry): State<Arc<SessionRegistry>>,
    Path(mission_id): Path<String>,
) -> ApiResult<serde_json::Value> {
    let rows = db_read(&registry, move |conn| {
        let mut stmt = conn.prepare(
            "SELECT DISTINCT
                w.id, w.branch, w.worktree_path, w.status,
                mi.orchestration_state, mi.issue_identifier, mi.issue_title
            FROM mission_issues mi
            JOIN sessions s ON s.id = mi.session_id
            JOIN worktrees w ON (
                (s.worktree_id IS NOT NULL AND s.worktree_id != '' AND w.id = s.worktree_id)
                OR
                (COALESCE(s.worktree_id, '') = '' AND w.worktree_path = s.project_path)
            )
            WHERE mi.mission_id = ?1
              AND w.status != 'removed'
            ORDER BY mi.created_at ASC",
        )?;
        let items = stmt
            .query_map(params![mission_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            })?
            .filter_map(|r| r.ok())
            .collect::<Vec<_>>();
        Ok(items)
    })
    .await?;

    let mut worktrees = Vec::with_capacity(rows.len());
    for (id, branch, path, _status, orch_state, identifier, title) in rows {
        let disk_present = crate::domain::git::repo::worktree_exists_on_disk(&path).await;
        let orchestration_state =
            OrchestrationState::from_db_str(&orch_state).unwrap_or(OrchestrationState::Queued);
        worktrees.push(MissionWorktreeItem {
            id,
            branch,
            worktree_path: path,
            disk_present,
            orchestration_state,
            issue_identifier: identifier,
            issue_title: title.unwrap_or_default(),
        });
    }

    Ok(Json(serde_json::json!({ "worktrees": worktrees })))
}

// ── Mission issue state transitions ──────────────────────────────────

#[derive(Deserialize)]
pub struct TransitionRequest {
    pub target_state: String,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Deserialize)]
pub struct ReportBlockedRequest {
    pub reason: String,
}

#[derive(Deserialize)]
pub struct ReportCompletedRequest {
    pub tracker_state: Option<String>,
}

/// POST /api/missions/:mission_id/issues/:issue_id/blocked
///
/// Called by mission tools (MCP server or dynamic tool handler) when the
/// agent signals it cannot continue.
pub async fn report_issue_blocked(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
    Json(body): Json<ReportBlockedRequest>,
) -> ApiResult<serde_json::Value> {
    let mid = mission_id.clone();
    let iid = issue_id.clone();
    let reason = body.reason.clone();
    let now = chrono::Utc::now().to_rfc3339();

    // Update orchestration state to blocked
    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
            mission_id: mid.clone(),
            issue_id: iid.clone(),
            orchestration_state: "blocked".to_string(),
            session_id: None,
            attempt: None,
            last_error: Some(Some(reason.clone())),
            retry_due_at: None,
            started_at: None,
            completed_at: Some(Some(now)),
        })
        .await;

    info!(
        component = "mission_control",
        event = "issue.blocked",
        mission_id = %mid,
        issue_id = %iid,
        reason = %reason,
        "Agent reported issue blocked"
    );

    Ok(Json(serde_json::json!({ "blocked": true })))
}

/// POST /api/missions/:mission_id/issues/:issue_id/complete
///
/// Called by mission tools when the agent has successfully moved the tracker
/// issue into a terminal state like "Done".
pub async fn report_issue_completed(
    State(registry): State<Arc<SessionRegistry>>,
    Path((mission_id, issue_id)): Path<(String, String)>,
    Json(body): Json<ReportCompletedRequest>,
) -> ApiResult<serde_json::Value> {
    let mid = mission_id.clone();
    let iid = issue_id.clone();
    let now = chrono::Utc::now().to_rfc3339();

    // Look up the session_id for this issue before marking it completed
    let session_id: Option<String> = {
        let db_path = registry.db_path().clone();
        let mid2 = mid.clone();
        let iid2 = iid.clone();
        tokio::task::spawn_blocking(move || {
            let conn = rusqlite::Connection::open(&db_path).ok()?;
            conn.query_row(
                "SELECT session_id FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
                params![mid2, iid2],
                |row| row.get::<_, Option<String>>(0),
            )
            .ok()
            .flatten()
        })
        .await
        .ok()
        .flatten()
    };

    let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
            mission_id: mid.clone(),
            issue_id: iid.clone(),
            orchestration_state: "completed".to_string(),
            session_id: None,
            attempt: None,
            last_error: Some(None),
            retry_due_at: Some(None),
            started_at: None,
            completed_at: Some(Some(now)),
        })
        .await;

    // End the agent session now that its issue is done
    if let Some(ref sid) = session_id {
        crate::runtime::session_mutations::end_session(&registry, sid).await;
        info!(
            component = "mission_control",
            event = "session.auto_ended",
            mission_id = %mid,
            issue_id = %iid,
            session_id = %sid,
            "Ended agent session after issue completed"
        );
    }

    crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id(&registry, &mid).await;

    info!(
        component = "mission_control",
        event = "issue.completed",
        mission_id = %mid,
        issue_id = %iid,
        tracker_state = ?body.tracker_state,
        session_ended = session_id.is_some(),
        "Agent reported issue completed"
    );

    Ok(Json(serde_json::json!({ "completed": true })))
}

// ── Internal helpers ─────────────────────────────────────────────────

fn build_settings_response(mission: &MissionRow) -> Option<MissionSettingsResponse> {
    let config_json = mission.config_json.as_ref()?;
    let config: MissionConfig = serde_json::from_str(config_json).ok()?;
    let prompt_template = mission.prompt_template.clone().unwrap_or_default();
    Some(MissionSettingsResponse {
        config,
        prompt_template,
    })
}

/// Build a full MissionDetailResponse from a mission row + issue rows.
///
/// If `settings_override` is provided, it is used directly and
/// `mission_file_exists` is forced to `true`. Otherwise settings
/// are derived from the row's `config_json` / `prompt_template`.
///
/// Set `check_workflow_migration` to `true` only for the detail GET
/// endpoint — all mutation responses skip the check.
async fn build_detail_response(
    registry: &SessionRegistry,
    mission: &MissionRow,
    issue_rows: Vec<MissionIssueRow>,
    orchestrator_running: bool,
    settings_override: Option<MissionSettingsResponse>,
    check_workflow_migration: bool,
) -> MissionDetailResponse {
    let summary = mission_row_to_summary_with_issues(mission, &issue_rows, orchestrator_running);
    let issues = issue_rows
        .into_iter()
        .map(|row| issue_row_to_item(row, registry))
        .collect();

    let (settings, mission_file_exists) = if let Some(s) = settings_override {
        (Some(s), true)
    } else {
        let exists = tokio::fs::metadata(mission.resolved_mission_path())
            .await
            .is_ok();
        (build_settings_response(mission), exists)
    };

    let workflow_migration_available = if check_workflow_migration && !mission_file_exists {
        if let Ok(content) =
            tokio::fs::read_to_string(StdPath::new(&mission.repo_root).join("WORKFLOW.md")).await
        {
            try_parse_symphony_workflow(&content).is_some()
        } else {
            false
        }
    } else {
        false
    };

    MissionDetailResponse {
        summary,
        issues,
        settings,
        mission_file_exists,
        mission_file_path: mission.mission_file_path.clone(),
        workflow_migration_available,
    }
}

/// Build MissionSummary from row, pulling provider strategy from config_json if available.
fn summary_from_row(
    row: &MissionRow,
    active: u32,
    queued: u32,
    completed: u32,
    failed: u32,
    orchestrator_running: bool,
) -> MissionSummary {
    let orchestrator_status = compute_orchestrator_status(row, orchestrator_running);

    // Pull provider details from parsed config (source of truth), fall back to row
    let (primary_provider, strategy, secondary) = if let Some(ref json) = row.config_json {
        if let Ok(config) = serde_json::from_str::<MissionConfig>(json) {
            (
                config
                    .provider
                    .primary
                    .parse::<Provider>()
                    .or_else(|_| row.provider.parse::<Provider>())
                    .unwrap_or(Provider::Claude),
                config.provider.strategy.clone(),
                config
                    .provider
                    .secondary
                    .as_ref()
                    .and_then(|s| s.parse::<Provider>().ok()),
            )
        } else {
            (
                row.provider.parse::<Provider>().unwrap_or(Provider::Claude),
                "single".to_string(),
                None,
            )
        }
    } else {
        (
            row.provider.parse::<Provider>().unwrap_or(Provider::Claude),
            "single".to_string(),
            None,
        )
    };

    MissionSummary {
        id: row.id.clone(),
        name: row.name.clone(),
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
        last_polled_at: None,
        poll_interval: None,
        mission_file_path: row.mission_file_path.clone(),
    }
}

fn mission_row_to_summary_with_issues(
    row: &MissionRow,
    issue_rows: &[MissionIssueRow],
    orchestrator_running: bool,
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
        orchestrator_running,
    )
}

async fn db_read<T, F>(registry: &Arc<SessionRegistry>, f: F) -> Result<T, super::errors::ApiError>
where
    T: Send + 'static,
    F: FnOnce(&rusqlite::Connection) -> anyhow::Result<T> + Send + 'static,
{
    let db_path = registry.db_path().clone();
    tokio::task::spawn_blocking(move || {
        let conn = rusqlite::Connection::open(&db_path)?;
        f(&conn)
    })
    .await
    .map_err(|e| internal("join_error", format!("join: {e}")))?
    .map_err(|e| internal("db_error", format!("db: {e}")))
}

fn issue_row_to_item(row: MissionIssueRow, registry: &SessionRegistry) -> MissionIssueItem {
    let orchestration_state = OrchestrationState::from_db_str(&row.orchestration_state)
        .unwrap_or(OrchestrationState::Queued);

    let allowed_transitions = orchestration_state.allowed_transitions();

    let provider: Provider = row
        .provider
        .as_deref()
        .unwrap_or("claude")
        .parse()
        .unwrap_or(Provider::Claude);

    // Enrich with live session data if available
    let (work_status, last_message, last_activity) = row
        .session_id
        .as_deref()
        .and_then(|sid| registry.get_session(sid))
        .map(|handle| {
            let snap = handle.snapshot();
            let ws = snap.work_status;
            let msg = snap.last_message.clone();
            let activity = snap.last_progress_at.clone();
            (Some(ws), msg, activity)
        })
        .unwrap_or((None, None, None));

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
        last_activity,
        started_at: row.started_at,
        completed_at: row.completed_at,
        allowed_transitions,
        work_status,
        last_message,
        pr_url: row.pr_url,
    }
}

#[cfg(test)]
mod tests {
    use super::slugify_mission_name;

    #[test]
    fn basic_space_separation() {
        assert_eq!(slugify_mission_name("My Mission"), "my-mission");
    }

    #[test]
    fn special_characters_stripped() {
        assert_eq!(slugify_mission_name("OrbitDock (v2)"), "orbitdock-v2");
    }

    #[test]
    fn leading_trailing_whitespace_trimmed() {
        assert_eq!(slugify_mission_name("  test  "), "test");
    }

    #[test]
    fn consecutive_special_chars_collapsed() {
        assert_eq!(slugify_mission_name("a---b"), "a-b");
    }

    #[test]
    fn unicode_alphanumeric_preserved() {
        assert_eq!(slugify_mission_name("café project"), "café-project");
    }

    #[test]
    fn single_word_unchanged() {
        assert_eq!(slugify_mission_name("simple"), "simple");
    }

    #[test]
    fn empty_string() {
        assert_eq!(slugify_mission_name(""), "");
    }

    #[test]
    fn real_world_mission_name() {
        assert_eq!(slugify_mission_name("OrbitDock GitHub"), "orbitdock-github");
    }

    #[test]
    fn mixed_special_characters() {
        assert_eq!(
            slugify_mission_name("hello@world.com #1"),
            "hello-world-com-1"
        );
    }

    #[test]
    fn all_special_characters() {
        assert_eq!(slugify_mission_name("---!!!---"), "");
    }
}
