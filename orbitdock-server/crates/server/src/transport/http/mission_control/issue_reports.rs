use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use orbitdock_protocol::OrchestrationState;

use crate::{
  infrastructure::persistence::{load_mission_by_id, load_mission_issues, PersistCommand},
  runtime::session_registry::SessionRegistry,
  transport::http::{
    errors::{bad_request, not_found},
    ApiResult,
  },
};

use super::{
  build_detail_response, db_read, flush_persistence, load_detail_response, MissionDetailResponse,
};

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
) -> ApiResult<MissionDetailResponse> {
  let _ = registry
    .persist()
    .send(PersistCommand::MissionIssueSetPrUrl {
      mission_id: mission_id.clone(),
      issue_id: issue_id.clone(),
      pr_url: body.pr_url.clone(),
    })
    .await;
  flush_persistence(&registry).await?;

  registry.publish_mission_invalidation(&mission_id);

  Ok(Json(
    load_detail_response(&registry, &mission_id, None, false).await?,
  ))
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

  // Notify mission detail + list surfaces to refresh via HTTP.
  registry.publish_mission_invalidation(&mission_id);

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
) -> ApiResult<MissionDetailResponse> {
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
      workspace_id: None,
      attempt: None,
      last_error: Some(Some(reason.clone())),
      retry_due_at: None,
      started_at: None,
      completed_at: Some(Some(now)),
    })
    .await;
  flush_persistence(&registry).await?;

  registry.publish_mission_invalidation(&mid);

  info!(
      component = "mission_control",
      event = "issue.blocked",
      mission_id = %mid,
      issue_id = %iid,
      reason = %reason,
      "Agent reported issue blocked"
  );

  Ok(Json(
    load_detail_response(&registry, &mid, None, false).await?,
  ))
}

/// POST /api/missions/:mission_id/issues/:issue_id/complete
///
/// Called by mission tools when the agent has successfully moved the tracker
/// issue into a terminal state like "Done".
pub async fn report_issue_completed(
  State(registry): State<Arc<SessionRegistry>>,
  Path((mission_id, issue_id)): Path<(String, String)>,
  Json(body): Json<ReportCompletedRequest>,
) -> ApiResult<MissionDetailResponse> {
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
      conn
        .query_row(
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
  let workspace_id: Option<String> = {
    let db_path = registry.db_path().clone();
    let mid2 = mid.clone();
    let iid2 = iid.clone();
    tokio::task::spawn_blocking(move || {
      let conn = rusqlite::Connection::open(&db_path).ok()?;
      conn
        .query_row(
          "SELECT workspace_id FROM mission_issues WHERE mission_id = ?1 AND issue_id = ?2",
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
      workspace_id: None,
      attempt: None,
      last_error: Some(None),
      retry_due_at: Some(None),
      started_at: None,
      completed_at: Some(Some(now)),
    })
    .await;
  flush_persistence(&registry).await?;

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

  if let Some(ref workspace_id) = workspace_id {
    if let Err(error) = crate::runtime::workspace_dispatch::daytona::destroy_daytona_workspace(
      registry.clone(),
      workspace_id,
    )
    .await
    {
      warn!(
        component = "mission_control",
        event = "issue.complete.workspace_destroy_failed",
        mission_id = %mid,
        issue_id = %iid,
        workspace_id = %workspace_id,
        error = %error,
        "Failed to destroy remote workspace after completion"
      );
    }
  }

  registry.publish_mission_invalidation(&mid);

  info!(
      component = "mission_control",
      event = "issue.completed",
      mission_id = %mid,
      issue_id = %iid,
      tracker_state = ?body.tracker_state,
      session_ended = session_id.is_some(),
      "Agent reported issue completed"
  );

  Ok(Json(
    load_detail_response(&registry, &mid, None, false).await?,
  ))
}
