use std::{path::Path as StdPath, sync::Arc};

use crate::{
  domain::mission_control::{
    compute_orchestrator_status,
    config::{try_parse_symphony_workflow, MissionConfig},
  },
  infrastructure::persistence::{
    load_mission_by_id, load_mission_issues, MissionIssueRow, MissionRow, PersistCommand,
  },
  runtime::session_registry::SessionRegistry,
  transport::http::errors::{internal, not_found, ApiError},
};
use orbitdock_protocol::{
  MissionCleanupPrompt, MissionIssueItem, MissionSummary, OrchestrationState, Provider,
};

use super::{MissionDetailResponse, MissionSettingsResponse};

fn build_settings_response(mission: &MissionRow) -> Option<MissionSettingsResponse> {
  let config_json = mission.config_json.as_ref()?;
  let config: MissionConfig = serde_json::from_str(config_json).ok()?;
  let prompt_template = mission.prompt_template.clone().unwrap_or_default();
  Some(MissionSettingsResponse {
    config,
    prompt_template,
  })
}

pub(crate) async fn build_detail_response(
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

pub(crate) async fn load_detail_response(
  registry: &Arc<SessionRegistry>,
  mission_id: &str,
  settings_override: Option<MissionSettingsResponse>,
  check_workflow_migration: bool,
) -> Result<MissionDetailResponse, ApiError> {
  let mission_id = mission_id.to_string();
  let mission_lookup_id = mission_id.clone();
  let mission = db_read(registry, move |conn| {
    load_mission_by_id(conn, &mission_lookup_id)
  })
  .await?
  .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;
  let issue_lookup_id = mission_id.clone();
  let issue_rows = db_read(registry, move |conn| {
    load_mission_issues(conn, &issue_lookup_id)
  })
  .await?;
  let orchestrator_running = registry.is_orchestrator_running();

  Ok(
    build_detail_response(
      registry,
      &mission,
      issue_rows,
      orchestrator_running,
      settings_override,
      check_workflow_migration,
    )
    .await,
  )
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

pub(crate) fn summary_from_row(
  row: &MissionRow,
  active: u32,
  queued: u32,
  completed: u32,
  failed: u32,
  orchestrator_running: bool,
) -> MissionSummary {
  let orchestrator_status = compute_orchestrator_status(row, orchestrator_running);

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

pub(crate) async fn db_read<T, F>(registry: &Arc<SessionRegistry>, f: F) -> Result<T, ApiError>
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

pub(crate) async fn flush_persistence(registry: &Arc<SessionRegistry>) -> Result<(), ApiError> {
  let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
  registry
    .persist()
    .send(PersistCommand::Flush { ack: ack_tx })
    .await
    .map_err(|e| {
      internal(
        "persist_flush_send_failed",
        format!("flush send failed: {e}"),
      )
    })?;
  ack_rx
    .await
    .map_err(|e| internal("persist_flush_ack_failed", format!("flush ack failed: {e}")))?;
  Ok(())
}

pub(crate) fn issue_row_to_item(
  row: MissionIssueRow,
  registry: &SessionRegistry,
) -> MissionIssueItem {
  let orchestration_state =
    OrchestrationState::from_db_str(&row.orchestration_state).unwrap_or(OrchestrationState::Queued);

  let allowed_transitions = orchestration_state.allowed_transitions();
  let provider: Provider = row
    .provider
    .as_deref()
    .unwrap_or("claude")
    .parse()
    .unwrap_or(Provider::Claude);

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
