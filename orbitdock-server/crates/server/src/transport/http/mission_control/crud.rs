use std::{path::Path as StdPath, sync::Arc};

use axum::{
  extract::{Path, State},
  Json,
};
use orbitdock_protocol::{MissionsSnapshot, Provider};
use tracing::info;

use crate::transport::http::errors::{bad_request, internal, not_found};
use crate::{
  infrastructure::persistence::{
    load_mission_by_id, load_mission_issues, load_missions_with_counts, PersistCommand,
  },
  runtime::session_registry::SessionRegistry,
  transport::http::ApiResult,
};

use super::{
  build_detail_response, db_read, flush_persistence, slugify_mission_name, summary_from_row,
  CreateMissionRequest, MissionDetailResponse, MissionsListResponse, UpdateMissionRequest,
};

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

pub async fn create_mission(
  State(registry): State<Arc<SessionRegistry>>,
  Json(req): Json<CreateMissionRequest>,
) -> ApiResult<orbitdock_protocol::MissionSummary> {
  let git_dir = StdPath::new(&req.repo_root).join(".git");
  if tokio::fs::metadata(&git_dir).await.is_err() {
    return Err(bad_request(
      "not_git_repo",
      format!("Directory is not a git repository: {}", req.repo_root),
    ));
  }

  let provider = req.provider.trim().to_ascii_lowercase();
  let primary_provider = match provider.as_str() {
    "claude" => Provider::Claude,
    "codex" => Provider::Codex,
    _ => {
      return Err(bad_request(
        "invalid_provider",
        format!("Invalid provider: {}", req.provider),
      ));
    }
  };

  let id = orbitdock_protocol::new_id();
  let repo_for_count = req.repo_root.clone();
  let existing_count = db_read(&registry, move |conn| {
    crate::infrastructure::persistence::mission_control::count_missions_by_repo_root(
      conn,
      &repo_for_count,
    )
  })
  .await?;

  let mission_file_path = if existing_count > 0 {
    Some(format!("MISSION-{}.md", slugify_mission_name(&req.name)))
  } else {
    Some("MISSION.md".to_string())
  };

  registry
    .persist()
    .send(PersistCommand::MissionCreate {
      id: id.clone(),
      name: req.name.clone(),
      repo_root: req.repo_root.clone(),
      tracker_kind: req.tracker_kind.clone(),
      provider: provider.clone(),
      config_json: None,
      prompt_template: None,
      mission_file_path: mission_file_path.clone(),
      tracker_api_key: None,
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;
  registry.publish_mission_invalidation(&id);

  info!(
    component = "mission_control",
    event = "mission.created",
    mission_id = %id,
    repo_root = %req.repo_root,
    "Mission created"
  );

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

  Ok(Json(orbitdock_protocol::MissionSummary {
    id,
    name: req.name,
    repo_root: req.repo_root,
    enabled: true,
    paused: false,
    tracker_kind: req.tracker_kind,
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
  Ok(Json(
    build_detail_response(&registry, &mission, issue_rows, orchestrator_running, None).await,
  ))
}

pub async fn update_mission(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
  Json(req): Json<UpdateMissionRequest>,
) -> ApiResult<MissionDetailResponse> {
  let mid = mission_id.clone();
  let _mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  registry
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
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;
  registry.publish_mission_invalidation(&mission_id);

  let mid2 = mission_id.clone();
  let persisted = db_read(&registry, move |conn| load_mission_by_id(conn, &mid2))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;
  let mid3 = mission_id.clone();
  let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid3)).await?;
  let orchestrator_running = registry.is_orchestrator_running();

  Ok(Json(
    build_detail_response(
      &registry,
      &persisted,
      issue_rows,
      orchestrator_running,
      None,
    )
    .await,
  ))
}

pub async fn delete_mission(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<MissionsListResponse> {
  registry
    .persist()
    .send(PersistCommand::MissionDelete {
      id: mission_id.clone(),
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;
  registry.publish_mission_invalidation(&mission_id);

  let orchestrator_running = registry.is_orchestrator_running();
  let rows = db_read(&registry, load_missions_with_counts).await?;
  let missions = rows
    .into_iter()
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
