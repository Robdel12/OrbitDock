use orbitdock_protocol::{WorktreeOrigin, WorktreeStatus, WorktreeSummary};
use tracing::{info, warn};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TrackedWorktreeRecord {
    pub id: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_branch: Option<String>,
    pub created_by: WorktreeOrigin,
}

#[derive(Debug, Clone)]
pub(crate) struct TrackedWorktreeCreation {
    pub summary: WorktreeSummary,
    pub record: TrackedWorktreeRecord,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PlannedTrackedWorktree {
    repo_root: String,
    branch: String,
    base_branch: Option<String>,
    worktree_path: String,
}

pub(crate) async fn create_tracked_worktree(
    repo_path: &str,
    branch_name: &str,
    base_branch: Option<&str>,
    created_by: WorktreeOrigin,
    worktree_root: Option<&str>,
    cleanup_existing: bool,
) -> Result<TrackedWorktreeCreation, String> {
    let planned = plan_tracked_worktree(repo_path, branch_name, base_branch, worktree_root)?;

    crate::domain::git::repo::create_worktree(
        &planned.repo_root,
        &planned.worktree_path,
        &planned.branch,
        planned.base_branch.as_deref(),
        cleanup_existing,
    )
    .await?;

    match crate::domain::worktrees::include_copy::copy_worktreeinclude(
        &planned.repo_root,
        &planned.worktree_path,
    )
    .await
    {
        Ok(copy_summary) => {
            if copy_summary.manifest_found {
                info!(
                    component = "worktree",
                    event = "worktree.include.copied",
                    repo_root = %planned.repo_root,
                    worktree_path = %planned.worktree_path,
                    matched_entries = copy_summary.matched_entries,
                    copied_entries = copy_summary.copied_entries,
                    skipped_entries = copy_summary.skipped_entries,
                    errored_entries = copy_summary.errored_entries,
                    "Applied .worktreeinclude copy pipeline"
                );
            }
        }
        Err(err) => {
            warn!(
                component = "worktree",
                event = "worktree.include.copy_failed",
                repo_root = %planned.repo_root,
                worktree_path = %planned.worktree_path,
                error = %err,
                "Failed to apply .worktreeinclude; continuing with worktree creation"
            );
        }
    }

    let worktree_id = orbitdock_protocol::new_id();
    let record = TrackedWorktreeRecord {
        id: worktree_id.clone(),
        repo_root: planned.repo_root.clone(),
        worktree_path: planned.worktree_path.clone(),
        branch: planned.branch.clone(),
        base_branch: planned.base_branch.clone(),
        created_by,
    };
    let summary = WorktreeSummary {
        id: record.id.clone(),
        repo_root: record.repo_root.clone(),
        worktree_path: record.worktree_path.clone(),
        branch: record.branch.clone(),
        base_branch: record.base_branch.clone(),
        status: WorktreeStatus::Active,
        active_session_count: 0,
        total_session_count: 0,
        created_at: crate::support::session_time::chrono_now(),
        last_session_ended_at: None,
        disk_present: true,
        auto_prune: true,
        custom_name: None,
        created_by,
    };

    Ok(TrackedWorktreeCreation { summary, record })
}

fn plan_tracked_worktree(
    repo_path: &str,
    branch_name: &str,
    base_branch: Option<&str>,
    worktree_root: Option<&str>,
) -> Result<PlannedTrackedWorktree, String> {
    let normalized_repo = repo_path.trim().trim_end_matches('/').to_string();
    let normalized_branch = branch_name.trim().to_string();
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

    let worktree_path = if let Some(root) = worktree_root.filter(|r| !r.trim().is_empty()) {
        format!(
            "{}/{}",
            root.trim().trim_end_matches('/'),
            normalized_branch
        )
    } else {
        format!(
            "{}/.orbitdock-worktrees/{}",
            normalized_repo, normalized_branch
        )
    };

    Ok(PlannedTrackedWorktree {
        repo_root: normalized_repo,
        branch: normalized_branch,
        base_branch: normalized_base,
        worktree_path,
    })
}

#[cfg(test)]
mod tests {
    use super::plan_tracked_worktree;

    #[test]
    fn plan_tracked_worktree_normalizes_inputs_and_builds_path() {
        let planned =
            plan_tracked_worktree(" /repo/path/ ", " feature/refactor ", Some(" main "), None)
                .expect("planned");

        assert_eq!(planned.repo_root, "/repo/path");
        assert_eq!(planned.branch, "feature/refactor");
        assert_eq!(planned.base_branch.as_deref(), Some("main"));
        assert_eq!(
            planned.worktree_path,
            "/repo/path/.orbitdock-worktrees/feature/refactor"
        );
    }

    #[test]
    fn plan_tracked_worktree_rejects_missing_required_fields() {
        assert_eq!(
            plan_tracked_worktree("   ", "feature", None, None).unwrap_err(),
            "Repository path is required"
        );
        assert_eq!(
            plan_tracked_worktree("/repo", "   ", None, None).unwrap_err(),
            "Branch name is required"
        );
    }

    #[test]
    fn plan_tracked_worktree_drops_empty_base_branch() {
        let planned =
            plan_tracked_worktree("/repo", "feature", Some("   "), None).expect("planned");
        assert_eq!(planned.base_branch, None);
    }
}
