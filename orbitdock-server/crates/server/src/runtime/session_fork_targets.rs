use std::path::PathBuf;
use std::sync::Arc;

use orbitdock_protocol::{WorktreeOrigin, WorktreeSummary};

use crate::domain::sessions::session::SessionSnapshot;
use crate::infrastructure::persistence::load_worktree_by_id;
use crate::runtime::session_registry::SessionRegistry;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForkTargetError {
  pub code: &'static str,
  pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExistingWorktreeValidationInputs<'a> {
  pub source_repo_root: &'a str,
  pub target_repo_root: &'a str,
  pub target_status: &'a str,
  pub target_path_exists: bool,
}

pub(crate) fn validate_new_worktree_branch_name(
  branch_name: &str,
) -> Result<String, ForkTargetError> {
  let trimmed_branch = branch_name.trim();
  if trimmed_branch.is_empty() {
    return Err(ForkTargetError {
      code: "worktree_create_invalid_input",
      message: "Branch name is required".to_string(),
    });
  }

  Ok(trimmed_branch.to_string())
}

pub(crate) fn normalize_repo_root(path: &str) -> String {
  path.trim().trim_end_matches('/').to_string()
}

pub(crate) fn select_source_repo_root(
  stored_repo_root: Option<&str>,
  git_common_root: Option<&str>,
  project_path: &str,
) -> String {
  stored_repo_root
    .map(normalize_repo_root)
    .filter(|root| !root.is_empty())
    .or_else(|| {
      git_common_root
        .map(normalize_repo_root)
        .filter(|root| !root.is_empty())
    })
    .unwrap_or_else(|| normalize_repo_root(project_path))
}

pub(crate) fn validate_existing_worktree_selection(
  inputs: ExistingWorktreeValidationInputs<'_>,
) -> Result<(), ForkTargetError> {
  if inputs.target_status == "removed" {
    return Err(ForkTargetError {
      code: "worktree_not_found",
      message: "Selected worktree has been removed".to_string(),
    });
  }

  if normalize_repo_root(inputs.target_repo_root) != normalize_repo_root(inputs.source_repo_root) {
    return Err(ForkTargetError {
      code: "worktree_repo_mismatch",
      message: "Selected worktree belongs to a different repository".to_string(),
    });
  }

  if !inputs.target_path_exists {
    return Err(ForkTargetError {
      code: "worktree_missing",
      message: "Selected worktree no longer exists on disk".to_string(),
    });
  }

  Ok(())
}

pub(crate) async fn resolve_source_repo_root(snapshot: &SessionSnapshot) -> String {
  let git_common_root = crate::domain::git::repo::resolve_git_info(&snapshot.project_path)
    .await
    .map(|git_info| git_info.common_dir_root);

  select_source_repo_root(
    snapshot.repository_root.as_deref(),
    git_common_root.as_deref(),
    &snapshot.project_path,
  )
}

pub(crate) async fn create_fork_target_worktree(
  state: &Arc<SessionRegistry>,
  source_snapshot: &SessionSnapshot,
  branch_name: &str,
  base_branch: Option<&str>,
) -> Result<WorktreeSummary, ForkTargetError> {
  let trimmed_branch = validate_new_worktree_branch_name(branch_name)?;
  let repo_root = resolve_source_repo_root(source_snapshot).await;

  crate::runtime::worktree_creation::create_tracked_worktree(
    state,
    &repo_root,
    &trimmed_branch,
    base_branch,
    WorktreeOrigin::User,
    None,
    false,
  )
  .await
  .map_err(|error| ForkTargetError {
    code: "worktree_create_failed",
    message: error,
  })
}

pub(crate) async fn resolve_existing_fork_worktree_path(
  db_path: &PathBuf,
  source_snapshot: &SessionSnapshot,
  worktree_id: &str,
) -> Result<String, ForkTargetError> {
  let Some(target_worktree) = load_worktree_by_id(db_path, worktree_id) else {
    return Err(ForkTargetError {
      code: "worktree_not_found",
      message: format!("Worktree {} not found", worktree_id),
    });
  };

  let source_repo_root = resolve_source_repo_root(source_snapshot).await;
  let target_path_exists =
    crate::domain::git::repo::worktree_exists_on_disk(&target_worktree.worktree_path).await;

  validate_existing_worktree_selection(ExistingWorktreeValidationInputs {
    source_repo_root: &source_repo_root,
    target_repo_root: &target_worktree.repo_root,
    target_status: &target_worktree.status,
    target_path_exists,
  })?;

  Ok(target_worktree.worktree_path)
}

#[cfg(test)]
#[path = "session_fork_targets_tests.rs"]
mod session_fork_targets_tests;
