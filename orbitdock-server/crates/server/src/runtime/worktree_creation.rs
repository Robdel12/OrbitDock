use std::sync::Arc;

use orbitdock_protocol::{WorktreeOrigin, WorktreeSummary};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

pub(crate) async fn create_tracked_worktree(
  state: &Arc<SessionRegistry>,
  repo_path: &str,
  branch_name: &str,
  base_branch: Option<&str>,
  created_by: WorktreeOrigin,
  worktree_root: Option<&str>,
  cleanup_existing: bool,
) -> Result<WorktreeSummary, String> {
  let created = crate::domain::worktrees::service::create_tracked_worktree(
    repo_path,
    branch_name,
    base_branch,
    created_by,
    worktree_root,
    cleanup_existing,
  )
  .await?;

  let _ = state
    .persist()
    .send(PersistCommand::WorktreeCreate {
      id: created.record.id,
      repo_root: created.record.repo_root,
      worktree_path: created.record.worktree_path,
      branch: created.record.branch,
      base_branch: created.record.base_branch,
      created_by: created.record.created_by.as_str().into(),
    })
    .await;

  Ok(created.summary)
}

#[cfg(test)]
#[path = "worktree_creation_tests.rs"]
mod worktree_creation_tests;
