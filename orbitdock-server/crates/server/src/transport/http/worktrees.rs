use std::path::PathBuf;
use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::{ServerMessage, WorktreeOrigin, WorktreeStatus, WorktreeSummary};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

use super::{revision_now, ApiErrorResponse, ApiResult};

#[derive(Debug, Serialize)]
pub struct WorktreesListResponse {
  pub repo_root: Option<String>,
  pub worktree_revision: u64,
  pub worktrees: Vec<WorktreeSummary>,
}

#[derive(Debug, Serialize)]
pub struct WorktreeCreatedResponse {
  pub repo_root: String,
  pub worktree_revision: u64,
  pub worktree: WorktreeSummary,
}

#[derive(Debug, Deserialize, Default)]
pub struct WorktreesQuery {
  #[serde(default)]
  pub repo_root: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateWorktreeRequest {
  pub repo_path: String,
  pub branch_name: String,
  #[serde(default)]
  pub base_branch: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DiscoverWorktreesRequest {
  pub repo_path: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct RemoveWorktreeQuery {
  #[serde(default)]
  pub force: bool,
  #[serde(default)]
  pub delete_branch: bool,
  #[serde(default)]
  pub delete_remote_branch: bool,
  #[serde(default)]
  pub archive_only: bool,
}

#[derive(Debug, Serialize)]
pub struct WorktreeRemovedResponse {
  pub repo_root: String,
  pub worktree_revision: u64,
  pub worktree_id: String,
  pub deleted: bool,
  pub ok: bool,
}

const STALE_WORKTREE_IDLE_DAYS: i64 = 14;

pub async fn list_worktrees(
  Query(query): Query<WorktreesQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorktreesListResponse> {
  let worktree_revision = revision_now();
  let worktrees = if let Some(ref root) = query.repo_root {
    let db_rows = crate::infrastructure::persistence::load_worktrees_by_repo(state.db_path(), root);

    if db_rows.is_empty() {
      match crate::domain::git::repo::discover_worktrees(root).await {
        Ok(discovered) => discovered
          .into_iter()
          .map(|worktree| WorktreeSummary {
            id: orbitdock_protocol::new_id(),
            repo_root: root.clone(),
            worktree_path: worktree.path,
            branch: worktree.branch.unwrap_or_else(|| "HEAD".to_string()),
            base_branch: None,
            status: WorktreeStatus::Active,
            active_session_count: 0,
            total_session_count: 0,
            created_at: String::new(),
            last_session_ended_at: None,
            disk_present: true,
            auto_prune: true,
            custom_name: None,
            created_by: WorktreeOrigin::Discovered,
          })
          .collect(),
        Err(_) => Vec::new(),
      }
    } else {
      tracked_worktree_summaries(state.db_path().clone(), db_rows, Some(root.as_str())).await
    }
  } else {
    let db_rows = crate::infrastructure::persistence::load_all_worktrees(state.db_path());
    tracked_worktree_summaries(state.db_path().clone(), db_rows, None).await
  };

  Ok(Json(WorktreesListResponse {
    repo_root: query.repo_root,
    worktree_revision,
    worktrees,
  }))
}

pub async fn discover_worktrees(
  Json(body): Json<DiscoverWorktreesRequest>,
) -> ApiResult<WorktreesListResponse> {
  let worktree_revision = revision_now();
  let worktrees = match crate::domain::git::repo::discover_worktrees(&body.repo_path).await {
    Ok(discovered) => discovered
      .into_iter()
      .map(|worktree| WorktreeSummary {
        id: orbitdock_protocol::new_id(),
        repo_root: body.repo_path.clone(),
        worktree_path: worktree.path,
        branch: worktree.branch.unwrap_or_else(|| "HEAD".to_string()),
        base_branch: None,
        status: WorktreeStatus::Active,
        active_session_count: 0,
        total_session_count: 0,
        created_at: String::new(),
        last_session_ended_at: None,
        disk_present: true,
        auto_prune: true,
        custom_name: None,
        created_by: WorktreeOrigin::Discovered,
      })
      .collect(),
    Err(_) => Vec::new(),
  };

  Ok(Json(WorktreesListResponse {
    repo_root: Some(body.repo_path),
    worktree_revision,
    worktrees,
  }))
}

pub async fn create_worktree(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<CreateWorktreeRequest>,
) -> ApiResult<WorktreeCreatedResponse> {
  let worktree_revision = revision_now();
  match crate::runtime::worktree_creation::create_tracked_worktree(
    &state,
    &body.repo_path,
    &body.branch_name,
    body.base_branch.as_deref(),
    WorktreeOrigin::User,
    None,
    false,
  )
  .await
  {
    Ok(summary) => {
      state.broadcast_to_list(ServerMessage::WorktreeCreated {
        request_id: String::new(),
        repo_root: summary.repo_root.clone(),
        worktree_revision,
        worktree: summary.clone(),
      });

      Ok(Json(WorktreeCreatedResponse {
        repo_root: summary.repo_root.clone(),
        worktree_revision,
        worktree: summary,
      }))
    }
    Err(error) => Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "create_failed",
        error,
      }),
    )),
  }
}

pub async fn remove_worktree(
  Path(worktree_id): Path<String>,
  Query(query): Query<RemoveWorktreeQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorktreeRemovedResponse> {
  let worktree_revision = revision_now();
  let row = crate::infrastructure::persistence::load_worktree_by_id(state.db_path(), &worktree_id)
    .ok_or_else(|| {
      (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("worktree {worktree_id} not found"),
        }),
      )
    })?;

  let disk_present = crate::domain::git::repo::worktree_exists_on_disk(&row.worktree_path).await;

  if !query.archive_only && disk_present {
    if let Err(error) =
      crate::domain::git::repo::remove_worktree(&row.repo_root, &row.worktree_path, query.force)
        .await
    {
      if !query.force {
        warn!(
            component = "worktree",
            event = "worktree.remove.failed",
            worktree_id = %worktree_id,
            repo_root = %row.repo_root,
            worktree_path = %row.worktree_path,
            error = %error,
            "Failed to remove worktree"
        );
        return Err((
          StatusCode::BAD_REQUEST,
          Json(ApiErrorResponse {
            code: "remove_failed",
            error,
          }),
        ));
      }

      warn!(
          component = "worktree",
          event = "worktree.remove.force_fallthrough",
          worktree_id = %worktree_id,
          error = %error,
          "git worktree remove failed in force mode, continuing"
      );
    }
  }

  if !query.archive_only && !disk_present {
    warn!(
      component = "worktree",
      event = "worktree.remove.missing_path",
      worktree_id = %worktree_id,
      repo_root = %row.repo_root,
      worktree_path = %row.worktree_path,
      "Worktree path is already missing on disk; skipping git worktree remove"
    );
  }

  if !query.archive_only && query.delete_branch {
    if let Err(error) = crate::domain::git::repo::delete_branch(&row.repo_root, &row.branch).await {
      warn!(
          component = "worktree",
          event = "worktree.delete_branch.failed",
          worktree_id = %worktree_id,
          repo_root = %row.repo_root,
          branch = %row.branch,
          error = %error,
          "Failed to delete branch after worktree removal"
      );
    }
  }

  if !query.archive_only && query.delete_remote_branch {
    if let Err(error) =
      crate::domain::git::repo::delete_remote_branch(&row.repo_root, &row.branch).await
    {
      warn!(
          component = "worktree",
          event = "worktree.delete_remote_branch.failed",
          worktree_id = %worktree_id,
          repo_root = %row.repo_root,
          branch = %row.branch,
          error = %error,
          "Failed to delete remote branch after worktree removal"
      );
    }
  }

  let _ = state
    .persist()
    .send(PersistCommand::WorktreeUpdateStatus {
      id: worktree_id.clone(),
      status: "removed".into(),
      last_session_ended_at: None,
    })
    .await;

  state.broadcast_to_list(ServerMessage::WorktreeRemoved {
    request_id: String::new(),
    repo_root: row.repo_root.clone(),
    worktree_revision,
    worktree_id: worktree_id.clone(),
  });

  Ok(Json(WorktreeRemovedResponse {
    repo_root: row.repo_root,
    worktree_revision,
    worktree_id,
    deleted: true,
    ok: true,
  }))
}

async fn tracked_worktree_summaries(
  db_path: PathBuf,
  rows: Vec<crate::infrastructure::persistence::WorktreeRow>,
  repo_root: Option<&str>,
) -> Vec<WorktreeSummary> {
  let session_stats =
    crate::infrastructure::persistence::load_worktree_session_stats(&db_path, repo_root);
  let mut summaries = Vec::with_capacity(rows.len());

  for row in rows {
    let disk_present = crate::domain::git::repo::worktree_exists_on_disk(&row.worktree_path).await;
    let stats = session_stats.get(&row.id).cloned().unwrap_or_default();
    let last_session_ended_at = latest_timestamp(
      row.last_session_ended_at.clone(),
      stats.last_session_ended_at.clone(),
    );
    let status = derive_worktree_status(
      &row.status,
      disk_present,
      stats.active_session_count,
      last_session_ended_at.as_deref(),
      row.auto_prune,
      chrono::Utc::now(),
    );

    summaries.push(WorktreeSummary {
      id: row.id,
      repo_root: row.repo_root,
      worktree_path: row.worktree_path,
      branch: row.branch,
      base_branch: row.base_branch,
      status,
      active_session_count: stats.active_session_count,
      total_session_count: stats.total_session_count,
      created_at: row.created_at,
      last_session_ended_at,
      disk_present,
      auto_prune: row.auto_prune,
      custom_name: row.custom_name,
      created_by: row
        .created_by
        .as_deref()
        .and_then(WorktreeOrigin::from_str_opt)
        .unwrap_or(WorktreeOrigin::User),
    });
  }

  summaries
}

fn derive_worktree_status(
  persisted_status: &str,
  disk_present: bool,
  active_session_count: u32,
  last_session_ended_at: Option<&str>,
  auto_prune: bool,
  now: chrono::DateTime<chrono::Utc>,
) -> WorktreeStatus {
  let persisted = WorktreeStatus::from_str_opt(persisted_status).unwrap_or(WorktreeStatus::Active);
  if persisted == WorktreeStatus::Removed || persisted == WorktreeStatus::Removing {
    return persisted;
  }
  if active_session_count > 0 {
    return WorktreeStatus::Active;
  }
  if !disk_present {
    return WorktreeStatus::Orphaned;
  }
  if auto_prune && is_stale_worktree(last_session_ended_at, now) {
    return WorktreeStatus::Stale;
  }
  WorktreeStatus::Active
}

fn is_stale_worktree(
  last_session_ended_at: Option<&str>,
  now: chrono::DateTime<chrono::Utc>,
) -> bool {
  let Some(timestamp) = last_session_ended_at else {
    return false;
  };
  let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(timestamp) else {
    return false;
  };
  parsed.with_timezone(&chrono::Utc) <= now - chrono::Duration::days(STALE_WORKTREE_IDLE_DAYS)
}

fn latest_timestamp(left: Option<String>, right: Option<String>) -> Option<String> {
  match (left, right) {
    (Some(left), Some(right)) => {
      let left_parsed = chrono::DateTime::parse_from_rfc3339(&left).ok();
      let right_parsed = chrono::DateTime::parse_from_rfc3339(&right).ok();
      match (left_parsed, right_parsed) {
        (Some(left_dt), Some(right_dt)) => {
          if right_dt > left_dt {
            Some(right)
          } else {
            Some(left)
          }
        }
        (Some(_), None) => Some(left),
        (None, Some(_)) => Some(right),
        (None, None) => Some(if right > left { right } else { left }),
      }
    }
    (Some(left), None) => Some(left),
    (None, Some(right)) => Some(right),
    (None, None) => None,
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn derive_worktree_status_marks_missing_disk_as_orphaned() {
    let status = derive_worktree_status(
      "active",
      false,
      0,
      Some("2026-04-01T00:00:00Z"),
      true,
      chrono::DateTime::parse_from_rfc3339("2026-04-28T00:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc),
    );
    assert_eq!(status, WorktreeStatus::Orphaned);
  }

  #[test]
  fn derive_worktree_status_marks_idle_worktrees_as_stale() {
    let status = derive_worktree_status(
      "active",
      true,
      0,
      Some("2026-04-01T00:00:00Z"),
      true,
      chrono::DateTime::parse_from_rfc3339("2026-04-28T00:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc),
    );
    assert_eq!(status, WorktreeStatus::Stale);
  }

  #[test]
  fn derive_worktree_status_keeps_active_sessions_active() {
    let status = derive_worktree_status(
      "active",
      true,
      1,
      Some("2026-04-01T00:00:00Z"),
      true,
      chrono::DateTime::parse_from_rfc3339("2026-04-28T00:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc),
    );
    assert_eq!(status, WorktreeStatus::Active);
  }
}
