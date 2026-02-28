use std::sync::Arc;

use orbitdock_protocol::{WorktreeOrigin, WorktreeStatus, WorktreeSummary};

use crate::persistence::PersistCommand;
use crate::state::SessionRegistry;

pub async fn create_tracked_worktree(
    state: &Arc<SessionRegistry>,
    repo_path: &str,
    branch_name: &str,
    base_branch: Option<&str>,
    created_by: WorktreeOrigin,
) -> Result<WorktreeSummary, String> {
    let normalized_repo = repo_path.trim().trim_end_matches('/');
    let normalized_branch = branch_name.trim();
    if normalized_repo.is_empty() {
        return Err("Repository path is required".into());
    }
    if normalized_branch.is_empty() {
        return Err("Branch name is required".into());
    }

    let normalized_base = base_branch
        .map(str::trim)
        .filter(|base| !base.is_empty())
        .map(str::to_string);

    let worktree_path = format!(
        "{}/.orbitdock-worktrees/{}",
        normalized_repo, normalized_branch
    );

    crate::git::create_worktree(
        normalized_repo,
        &worktree_path,
        normalized_branch,
        normalized_base.as_deref(),
    )
    .await?;

    let worktree_id = orbitdock_protocol::new_id();
    let summary = WorktreeSummary {
        id: worktree_id.clone(),
        repo_root: normalized_repo.to_string(),
        worktree_path: worktree_path.clone(),
        branch: normalized_branch.to_string(),
        base_branch: normalized_base.clone(),
        status: WorktreeStatus::Active,
        active_session_count: 0,
        total_session_count: 0,
        created_at: crate::session_utils::chrono_now(),
        last_session_ended_at: None,
        disk_present: true,
        auto_prune: true,
        custom_name: None,
        created_by,
    };

    let _ = state
        .persist()
        .send(PersistCommand::WorktreeCreate {
            id: worktree_id,
            repo_root: normalized_repo.to_string(),
            worktree_path,
            branch: normalized_branch.to_string(),
            base_branch: normalized_base,
            created_by: created_by.as_str().into(),
        })
        .await;

    Ok(summary)
}
