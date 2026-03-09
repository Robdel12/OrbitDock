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

    if normalize_repo_root(inputs.target_repo_root) != normalize_repo_root(inputs.source_repo_root)
    {
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
mod tests {
    use super::{
        normalize_repo_root, select_source_repo_root, validate_existing_worktree_selection,
        validate_new_worktree_branch_name, ExistingWorktreeValidationInputs,
    };

    #[test]
    fn branch_validation_trims_and_rejects_empty_values() {
        assert_eq!(
            validate_new_worktree_branch_name("  feature/refactor  ").unwrap(),
            "feature/refactor"
        );

        let error = validate_new_worktree_branch_name("   ").unwrap_err();
        assert_eq!(error.code, "worktree_create_invalid_input");
        assert_eq!(error.message, "Branch name is required");
    }

    #[test]
    fn source_repo_root_prefers_stored_then_git_then_project_path() {
        assert_eq!(
            select_source_repo_root(
                Some("/repo/.git/worktrees/demo/../.."),
                Some("/fallback"),
                "/project"
            ),
            "/repo/.git/worktrees/demo/../.."
                .trim()
                .trim_end_matches('/')
                .to_string()
        );
        assert_eq!(
            select_source_repo_root(None, Some("/fallback/"), "/project/"),
            "/fallback".to_string()
        );
        assert_eq!(
            select_source_repo_root(None, None, "/project/"),
            "/project".to_string()
        );
    }

    #[test]
    fn existing_worktree_validation_matches_user_visible_failures() {
        assert_eq!(
            validate_existing_worktree_selection(ExistingWorktreeValidationInputs {
                source_repo_root: "/repo",
                target_repo_root: "/repo/",
                target_status: "active",
                target_path_exists: true,
            }),
            Ok(())
        );

        let removed = validate_existing_worktree_selection(ExistingWorktreeValidationInputs {
            source_repo_root: "/repo",
            target_repo_root: "/repo",
            target_status: "removed",
            target_path_exists: true,
        })
        .unwrap_err();
        assert_eq!(removed.code, "worktree_not_found");

        let mismatch = validate_existing_worktree_selection(ExistingWorktreeValidationInputs {
            source_repo_root: "/repo-a",
            target_repo_root: "/repo-b",
            target_status: "active",
            target_path_exists: true,
        })
        .unwrap_err();
        assert_eq!(mismatch.code, "worktree_repo_mismatch");

        let missing = validate_existing_worktree_selection(ExistingWorktreeValidationInputs {
            source_repo_root: "/repo",
            target_repo_root: "/repo",
            target_status: "active",
            target_path_exists: false,
        })
        .unwrap_err();
        assert_eq!(missing.code, "worktree_missing");
    }

    #[test]
    fn normalize_repo_root_trims_trailing_slashes() {
        assert_eq!(
            normalize_repo_root(" /repo/path/ "),
            "/repo/path".to_string()
        );
    }
}
