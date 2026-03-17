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
mod tests {
    use std::sync::Arc;

    use orbitdock_protocol::{WorktreeOrigin, WorktreeStatus};
    use tempfile::tempdir;
    use tokio::sync::mpsc;

    use crate::infrastructure::paths;
    use crate::infrastructure::persistence::PersistCommand;
    use crate::runtime::session_registry::SessionRegistry;

    use super::create_tracked_worktree;

    async fn init_repo_with_commit(repo: &str, file_name: &str) {
        crate::domain::git::repo::git_init(repo)
            .await
            .expect("git init");
        let output = tokio::process::Command::new("/usr/bin/git")
            .args(["config", "user.email", "test@test.com"])
            .current_dir(repo)
            .output()
            .await
            .expect("git config email");
        assert!(output.status.success(), "git config email failed");
        let output = tokio::process::Command::new("/usr/bin/git")
            .args(["config", "user.name", "Test"])
            .current_dir(repo)
            .output()
            .await
            .expect("git config name");
        assert!(output.status.success(), "git config name failed");
        std::fs::write(std::path::Path::new(repo).join(file_name), "hello").expect("write file");
        let output = tokio::process::Command::new("/usr/bin/git")
            .args(["add", "."])
            .current_dir(repo)
            .output()
            .await
            .expect("git add");
        assert!(output.status.success(), "git add failed");
        let output = tokio::process::Command::new("/usr/bin/git")
            .args(["commit", "-m", "init"])
            .current_dir(repo)
            .output()
            .await
            .expect("git commit");
        assert!(output.status.success(), "git commit failed");
    }

    #[tokio::test]
    async fn create_tracked_worktree_persists_created_record() {
        let temp = tempdir().expect("tempdir");
        let data_dir = temp.path().join("data");
        paths::init_data_dir(Some(&data_dir));

        let repo_dir = temp.path().join("repo");
        std::fs::create_dir_all(&repo_dir).expect("create repo dir");
        let repo = repo_dir.to_string_lossy().into_owned();
        init_repo_with_commit(&repo, "README.md").await;

        let (persist_tx, mut persist_rx) = mpsc::channel(8);
        let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

        let summary = create_tracked_worktree(
            &state,
            &repo,
            "feature/runtime-boundary",
            Some("HEAD"),
            WorktreeOrigin::User,
            None,
            false,
        )
        .await
        .expect("create tracked worktree");

        assert_eq!(summary.status, WorktreeStatus::Active);
        assert!(summary.disk_present);
        assert_eq!(summary.created_by, WorktreeOrigin::User);
        assert!(
            std::path::Path::new(&summary.worktree_path).exists(),
            "worktree should exist on disk"
        );

        let persisted = persist_rx.recv().await.expect("persist command");
        match persisted {
            PersistCommand::WorktreeCreate {
                id,
                repo_root,
                worktree_path,
                branch,
                base_branch,
                created_by,
            } => {
                assert_eq!(id, summary.id);
                assert_eq!(repo_root, summary.repo_root);
                assert_eq!(worktree_path, summary.worktree_path);
                assert_eq!(branch, summary.branch);
                assert_eq!(base_branch, Some("HEAD".to_string()));
                assert_eq!(created_by, "user");
            }
            other => panic!("unexpected persist command: {other:?}"),
        }
    }
}
