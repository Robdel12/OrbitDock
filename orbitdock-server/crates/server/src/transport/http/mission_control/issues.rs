use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use rusqlite::params;
use tracing::info;

use crate::transport::http::errors::not_found;
use crate::{
  infrastructure::persistence::{load_mission_by_id, load_mission_issues},
  runtime::session_registry::SessionRegistry,
  transport::http::ApiResult,
};

use super::{build_detail_response, common::issue_row_to_item, db_read, MissionDetailResponse};

pub async fn list_mission_issues(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<Vec<orbitdock_protocol::MissionIssueItem>> {
  let mid = mission_id.clone();
  let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid)).await?;

  Ok(Json(
    issue_rows
      .into_iter()
      .map(|row| issue_row_to_item(row, &registry))
      .collect::<Vec<_>>(),
  ))
}

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

  if state == "running" || state == "claimed" || state == "provisioning" {
    if let Some(ref sid) = session_id {
      crate::runtime::session_mutations::end_session(&registry, sid).await;
    }
  }

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

  let mid3 = mission_id.clone();
  let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid3))
    .await?
    .ok_or_else(|| not_found("not_found", "Mission not found"))?;
  let mid4 = mission_id.clone();
  let issue_rows = db_read(&registry, move |conn| load_mission_issues(conn, &mid4)).await?;
  let orchestrator_running = registry.is_orchestrator_running();

  Ok(Json(
    build_detail_response(&registry, &mission, issue_rows, orchestrator_running, None).await,
  ))
}
