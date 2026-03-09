use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_protocol::{ServerMessage, WorktreeOrigin, WorktreeStatus, WorktreeSummary};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::domain::sessions::registry::SessionRegistry;
use crate::infrastructure::persistence::PersistCommand;

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

pub async fn list_worktrees(
    Query(query): Query<WorktreesQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorktreesListResponse> {
    let worktree_revision = revision_now();
    let worktrees = if let Some(ref root) = query.repo_root {
        let db_rows =
            crate::infrastructure::persistence::load_worktrees_by_repo(state.db_path(), root);

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
            let mut summaries = Vec::with_capacity(db_rows.len());
            for row in db_rows {
                let disk_present =
                    crate::domain::git::repo::worktree_exists_on_disk(&row.worktree_path).await;
                summaries.push(WorktreeSummary {
                    id: row.id,
                    repo_root: row.repo_root,
                    worktree_path: row.worktree_path,
                    branch: row.branch,
                    base_branch: row.base_branch,
                    status: WorktreeStatus::from_str_opt(&row.status)
                        .unwrap_or(WorktreeStatus::Active),
                    active_session_count: 0,
                    total_session_count: 0,
                    created_at: String::new(),
                    last_session_ended_at: None,
                    disk_present,
                    auto_prune: true,
                    custom_name: None,
                    created_by: WorktreeOrigin::User,
                });
            }
            summaries
        }
    } else {
        Vec::new()
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
    match crate::domain::worktrees::service::create_tracked_worktree(
        &state,
        &body.repo_path,
        &body.branch_name,
        body.base_branch.as_deref(),
        WorktreeOrigin::User,
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
    let row =
        crate::infrastructure::persistence::load_worktree_by_id(state.db_path(), &worktree_id)
            .ok_or_else(|| {
                (
                    StatusCode::NOT_FOUND,
                    Json(ApiErrorResponse {
                        code: "not_found",
                        error: format!("worktree {worktree_id} not found"),
                    }),
                )
            })?;

    if !query.archive_only {
        if let Err(error) = crate::domain::git::repo::remove_worktree(
            &row.repo_root,
            &row.worktree_path,
            query.force,
        )
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

    if !query.archive_only && query.delete_branch {
        if let Err(error) =
            crate::domain::git::repo::delete_branch(&row.repo_root, &row.branch).await
        {
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
