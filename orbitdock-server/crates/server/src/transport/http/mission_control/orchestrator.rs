use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use serde::Deserialize;
use tracing::info;

use crate::{
  infrastructure::persistence::{load_mission_by_id, load_mission_issues, PersistCommand},
  runtime::session_registry::SessionRegistry,
  transport::http::errors::{bad_request, conflict, internal, not_found},
  transport::http::ApiResult,
};

use super::{build_detail_response, db_read, flush_persistence, MissionDetailResponse};

use crate::domain::mission_control::config::parse_mission_file;

#[derive(Deserialize)]
pub struct ManualDispatchRequest {
  /// Issue identifier (e.g. "VIZ-240" for Linear, "owner/repo#42" for GitHub)
  pub issue_identifier: String,
  /// Optional provider override (defaults to mission's primary)
  pub provider: Option<String>,
}

/// POST /api/missions/:id/start-orchestrator
pub async fn start_mission_orchestrator_endpoint(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<serde_json::Value> {
  let mid = mission_id.clone();
  let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  let tracker =
    crate::support::api_keys::build_tracker_for_mission(&mission.id, &mission.tracker_kind)
      .map_err(|e| bad_request("no_api_key", e.to_string()))?;

  if !registry.try_start_orchestrator() {
    return Err(conflict(
      "already_running",
      "Orchestrator is already running",
    ));
  }

  let reg = registry.clone();
  tokio::spawn(async move {
    crate::runtime::mission_orchestrator::start_mission_orchestrator(reg.clone(), tracker).await;
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

  // 2. Build tracker for this mission (mission-scoped key resolution)
  let tracker =
    crate::support::api_keys::build_tracker_for_mission(&mission.id, &mission.tracker_kind)
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
  flush_persistence(&registry).await?;

  // 6. Spawn dispatch (reuse the tracker built in step 2)

  let reg = registry.clone();
  let mid_dispatch = mission.id.clone();
  let ctx = crate::runtime::mission_dispatch::DispatchContext {
    repo_root: mission.repo_root.clone(),
    prompt_template: workflow.prompt_template.clone(),
    base_branch: workflow.config.orchestration.base_branch.clone(),
    agent_config: workflow.config.agent.clone(),
    workspace_config: workflow.config.workspace.clone(),
    worktree_root_dir: workflow.config.orchestration.worktree_root_dir.clone(),
    state_on_dispatch: workflow.config.orchestration.state_on_dispatch.clone(),
    tracker,
  };

  tokio::spawn(async move {
    let result = crate::runtime::mission_dispatch::dispatch_issue(
      &reg,
      &mid_dispatch,
      &issue,
      &provider_str,
      &ctx,
      1,
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

    reg.publish_mission_invalidation(&mid_dispatch);
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
  )
  .await;
  Ok(Json(response))
}

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
