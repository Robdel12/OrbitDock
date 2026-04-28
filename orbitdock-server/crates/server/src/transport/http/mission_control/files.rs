use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use tracing::info;

use crate::domain::mission_control::config::{
  generate_scaffold, parse_mission_file, MissionConfig, MissionConfigUpdate,
};
use crate::infrastructure::persistence::{load_mission_by_id, load_mission_issues, PersistCommand};
use crate::runtime::session_registry::SessionRegistry;

use super::super::errors::{conflict, internal, not_found, ApiResult};
use super::{
  build_detail_response, db_read, flush_persistence, MissionDetailResponse,
  MissionSettingsResponse, UpdateMissionSettingsRequest,
};

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
  if tokio::fs::metadata(&mission_file_path).await.is_ok() {
    return Err(conflict(
      "mission_file_exists",
      "MISSION.md already exists in this repository",
    ));
  }

  let (file_content, config, prompt_template) =
    generate_scaffold(&mission.provider, &mission.tracker_kind).map_err(|error| {
      internal(
        "scaffold_error",
        format!("Failed to generate scaffold: {error}"),
      )
    })?;

  tokio::fs::write(&mission_file_path, &file_content)
    .await
    .map_err(|error| {
      internal(
        "write_error",
        format!("Failed to write MISSION.md: {error}"),
      )
    })?;

  info!(
    component = "mission_control",
    event = "mission_file.scaffolded",
    mission_id = %mission_id,
    repo_root = %mission.repo_root,
    "Scaffolded MISSION.md"
  );

  let config_json = serde_json::to_string(&config).unwrap_or_default();
  registry
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
  let persisted_mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid2))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;
  let mid3 = mission_id.clone();
  let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid3)).await?;
  let orchestrator_running = registry.is_orchestrator_running();
  let settings = MissionSettingsResponse {
    config,
    prompt_template,
  };
  let response = build_detail_response(
    &registry,
    &persisted_mission,
    issue_rows,
    orchestrator_running,
    Some(settings),
  )
  .await;
  Ok(Json(response))
}

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

  let mission_file_path = mission.resolved_mission_path();
  let existing_file_content = tokio::fs::read_to_string(&mission_file_path).await.ok();
  let (mut config, mut prompt_tmpl) = if let Some(ref content) = existing_file_content {
    match parse_mission_file(content) {
      Ok(workflow) => (workflow.config, workflow.prompt_template),
      Err(_) => (MissionConfig::default(), String::new()),
    }
  } else {
    (MissionConfig::default(), String::new())
  };

  let tracker_kind_update = req.tracker.clone();

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

  if let Some(prompt_template) = req.prompt_template {
    prompt_tmpl = prompt_template;
  }

  let mission_content = crate::domain::mission_control::config::serialize_mission_file_preserving(
    &config,
    &prompt_tmpl,
    existing_file_content.as_deref(),
  )
  .map_err(|error| {
    internal(
      "serialize_error",
      format!("Failed to serialize config: {error}"),
    )
  })?;

  tokio::fs::write(&mission_file_path, &mission_content)
    .await
    .map_err(|error| {
      internal(
        "write_error",
        format!("Failed to write MISSION.md: {error}"),
      )
    })?;

  let config_json = serde_json::to_string(&config).unwrap_or_default();
  registry
    .persist()
    .send(PersistCommand::MissionUpdate {
      id: mission_id.clone(),
      name: None,
      enabled: None,
      paused: None,
      tracker_kind: tracker_kind_update.clone(),
      config_json: Some(config_json),
      prompt_template: Some(prompt_tmpl.clone()),
      parse_error: Some(None),
      mission_file_path: None,
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

  info!(
    component = "mission_control",
    event = "settings.updated",
    mission_id = %mission_id,
    "Mission settings updated via API"
  );

  let mid2 = mission_id.clone();
  let persisted_mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid2))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;
  let mid3 = mission_id.clone();
  let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid3)).await?;
  let orchestrator_running = registry.is_orchestrator_running();
  let settings = MissionSettingsResponse {
    config,
    prompt_template: prompt_tmpl,
  };
  let response = build_detail_response(
    &registry,
    &persisted_mission,
    issue_rows,
    orchestrator_running,
    Some(settings),
  )
  .await;
  Ok(Json(response))
}
