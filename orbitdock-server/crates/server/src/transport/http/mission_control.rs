use std::path::Path as StdPath;
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::Json;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use orbitdock_protocol::{
  MissionCleanupPrompt, MissionIssueItem, MissionSummary, MissionsSnapshot, OrchestrationState,
  Provider,
};

use crate::domain::mission_control::compute_orchestrator_status;
use crate::domain::mission_control::config::{try_parse_symphony_workflow, MissionConfig};
use crate::infrastructure::persistence::{
  load_mission_by_id, load_mission_issues, load_missions_with_counts, MissionIssueRow, MissionRow,
  PersistCommand,
};
use crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id;
use crate::runtime::session_registry::SessionRegistry;

mod defaults;
mod files;
mod issue_reports;
mod orchestrator;
mod tracker_keys;

pub use defaults::{get_mission_defaults, update_mission_defaults};
pub use files::{
  get_default_template, migrate_workflow_to_mission, scaffold_mission_file, update_mission_settings,
};
pub use issue_reports::{
  list_mission_worktrees, report_issue_blocked, report_issue_completed, set_issue_pr_url,
  transition_mission_issue,
};
pub use orchestrator::{
  dispatch_mission_issue, start_mission_orchestrator_endpoint, trigger_mission_poll,
};
pub use tracker_keys::{
  adopt_global_tracker_key, check_github_key, check_linear_key, delete_github_key,
  delete_linear_key, delete_mission_tracker_key, get_mission_tracker_key, get_tracker_keys,
  set_github_key, set_linear_key, set_mission_tracker_key,
};

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
  pub cleanup_prompt: Option<MissionCleanupPrompt>,
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
  name
    .to_lowercase()
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
) -> ApiResult<MissionsSnapshot> {
  let orchestrator_running = registry.is_orchestrator_running();
  let rows = db_read(&registry, load_missions_with_counts).await?;

  let missions = rows
    .into_iter()
    .map(|(r, (active, queued, completed, failed))| {
      summary_from_row(&r, active, queued, completed, failed, orchestrator_running)
    })
    .collect();

  Ok(Json(MissionsSnapshot {
    revision: registry.current_missions_snapshot().revision,
    missions,
  }))
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
      tracker_api_key: None,
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
    if crate::support::api_keys::resolve_tracker_api_key_for_mission(&id, &req.tracker_kind)
      .is_none()
    {
      Some("no_api_key".to_string())
    } else {
      Some("polling".to_string())
    };

  let tracker_key_source =
    crate::support::api_keys::tracker_key_source_for_mission(&id, &req.tracker_kind)
      .map(|s| s.to_string());

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
    tracker_key_source,
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

  let mission =
    mission_row.ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

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
  if state == "running" || state == "claimed" || state == "provisioning" {
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
        workspace_id: None,
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

#[cfg(any())]
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
  if current_state == OrchestrationState::Running
    || current_state == OrchestrationState::Claimed
    || current_state == OrchestrationState::Provisioning
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
        workspace_id: None,
        attempt: Some(0),
        last_error: Some(None),
        started_at: Some(None),
        completed_at: Some(None),
      },
      OrchestrationState::Completed => MissionIssueStateUpdate {
        orchestration_state: &target_str,
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(None),
        started_at: None,
        completed_at: Some(Some(&now)),
      },
      OrchestrationState::Failed => MissionIssueStateUpdate {
        orchestration_state: &target_str,
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(Some(reason.as_deref().unwrap_or("Manually stopped"))),
        started_at: None,
        completed_at: Some(Some(&now)),
      },
      OrchestrationState::Provisioning => MissionIssueStateUpdate {
        orchestration_state: &target_str,
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(None),
        started_at: None,
        completed_at: Some(None),
      },
      OrchestrationState::Blocked => MissionIssueStateUpdate {
        orchestration_state: &target_str,
        session_id: None,
        workspace_id: None,
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
  registry: &Arc<SessionRegistry>,
  mission: &MissionRow,
  issue_rows: Vec<MissionIssueRow>,
  orchestrator_running: bool,
  settings_override: Option<MissionSettingsResponse>,
  check_workflow_migration: bool,
) -> MissionDetailResponse {
  let summary = mission_row_to_summary_with_issues(mission, &issue_rows, orchestrator_running);
  let cleanup_prompt = build_cleanup_prompt(registry, &mission.id).await;
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
    cleanup_prompt,
    settings,
    mission_file_exists,
    mission_file_path: mission.mission_file_path.clone(),
    workflow_migration_available,
  }
}

async fn build_cleanup_prompt(
  registry: &Arc<SessionRegistry>,
  mission_id: &str,
) -> Option<MissionCleanupPrompt> {
  let mid = mission_id.to_string();
  let candidates = db_read(registry, move |conn| {
    crate::infrastructure::persistence::load_mission_cleanup_candidates(conn, &mid)
  })
  .await
  .ok()?;

  if candidates.is_empty() {
    return None;
  }

  let mut lingering_worktree_count = 0u32;
  for candidate in candidates {
    if crate::domain::git::repo::worktree_exists_on_disk(&candidate.worktree_path).await {
      lingering_worktree_count += 1;
    }
  }

  if lingering_worktree_count == 0 {
    None
  } else {
    Some(MissionCleanupPrompt {
      lingering_worktree_count,
    })
  }
}

/// Build MissionSummary from row, pulling provider strategy from config_json if available.
pub(crate) fn summary_from_row(
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

  let tracker_key_source =
    crate::support::api_keys::tracker_key_source_for_mission(&row.id, &row.tracker_kind)
      .map(|s| s.to_string());

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
    tracker_key_source,
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
      "running" | "claimed" | "provisioning" => active_count += 1,
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
  let orchestration_state =
    OrchestrationState::from_db_str(&row.orchestration_state).unwrap_or(OrchestrationState::Queued);

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
  fn slugify_mission_name_normalizes_user_visible_inputs() {
    let cases = [
      ("My Mission", "my-mission"),
      ("OrbitDock (v2)", "orbitdock-v2"),
      ("  test  ", "test"),
      ("a---b", "a-b"),
      ("café project", "café-project"),
      ("simple", "simple"),
      ("", ""),
      ("OrbitDock GitHub", "orbitdock-github"),
      ("hello@world.com #1", "hello-world-com-1"),
      ("---!!!---", ""),
    ];
    for (input, expected) in cases {
      assert_eq!(slugify_mission_name(input), expected, "input: {input:?}");
    }
  }
}
