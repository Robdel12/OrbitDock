//! Shared git utilities for resolving branch/repo info from a working directory.
//!
//! Pure classification functions (`classify_common_dir`, `parse_worktree_porcelain`)
//! are separated from async I/O so they can be unit-tested without a git repo.

use std::process::Stdio;
use tokio::process::Command;

// ---------------------------------------------------------------------------
// GitInfo — rich resolution result
// ---------------------------------------------------------------------------

/// Full git context for a working directory.
#[allow(dead_code)] // Used in Phase 6+ (hook_handler enrichment)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitInfo {
    /// The worktree's own root (`git rev-parse --show-toplevel`).
    pub toplevel: String,
    /// The canonical repo root (derived from `--git-common-dir`).
    /// For the main worktree this equals `toplevel`; for linked worktrees
    /// it points to the parent repo root.
    pub common_dir_root: String,
    /// Current branch, or `"HEAD"` if detached.
    pub branch: String,
    /// Short SHA (12 chars).
    pub sha: String,
    /// True when this path lives inside a linked worktree.
    pub is_worktree: bool,
}

/// Resolve just the git branch from a working directory (legacy helper).
pub async fn resolve_git_branch(path: &str) -> Option<String> {
    run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path).await
}

/// Resolve full git context for a path, or `None` if not inside a git repo.
#[allow(dead_code)] // Used in Phase 6+ (hook_handler enrichment)
pub async fn resolve_git_info(path: &str) -> Option<GitInfo> {
    let (toplevel, common_dir, branch, sha) = tokio::join!(
        run_git(&["rev-parse", "--show-toplevel"], path),
        run_git(&["rev-parse", "--git-common-dir"], path),
        run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path),
        run_git(&["rev-parse", "--short=12", "HEAD"], path),
    );

    let toplevel = toplevel?;
    let common_dir = common_dir?;
    let branch = branch.unwrap_or_else(|| "HEAD".to_string());
    let sha = sha.unwrap_or_default();

    let common_dir_root = classify_common_dir(&toplevel, &common_dir);
    let is_worktree = common_dir_root != toplevel;

    Some(GitInfo {
        toplevel,
        common_dir_root,
        branch,
        sha,
        is_worktree,
    })
}

// ---------------------------------------------------------------------------
// Pure classification
// ---------------------------------------------------------------------------

/// Derive the canonical repo root from `--show-toplevel` and `--git-common-dir`.
///
/// For the **main worktree**, `--git-common-dir` returns `.git` (relative) or
/// an absolute path ending in `.git`. The repo root is the parent of that `.git`.
///
/// For a **linked worktree**, `--git-common-dir` returns an absolute path like
/// `/repos/myproject/.git/worktrees/fix-auth`. The repo root is the ancestor
/// containing `.git` (i.e. strip `/worktrees/<name>` then go up one level).
///
/// If parsing fails, falls back to `toplevel`.
#[allow(dead_code)] // Used by resolve_git_info + unit tests
pub fn classify_common_dir(toplevel: &str, common_dir: &str) -> String {
    let trimmed = common_dir.trim().trim_end_matches('/');

    // Relative `.git` → this IS the main worktree
    if trimmed == ".git" {
        return toplevel.to_string();
    }

    // Absolute path — could be main or linked
    if trimmed.starts_with('/') {
        // Linked worktree: path contains `/worktrees/` segment
        // e.g. `/repos/project/.git/worktrees/fix-auth`
        if let Some(idx) = trimmed.find("/.git/worktrees/") {
            // Repo root is everything before `/.git/worktrees/`
            return trimmed[..idx].to_string();
        }

        // Main worktree with absolute common dir ending in `.git`
        // e.g. `/repos/project/.git`
        if let Some(stripped) = trimmed.strip_suffix("/.git") {
            return stripped.to_string();
        }

        // Bare `.git` at root (unlikely but handle gracefully)
        if trimmed == "/.git" {
            return "/".to_string();
        }
    }

    // Fallback
    toplevel.to_string()
}

// ---------------------------------------------------------------------------
// Worktree discovery — porcelain parser
// ---------------------------------------------------------------------------

/// A worktree discovered via `git worktree list --porcelain`.
#[allow(dead_code)] // Used in Phase 9 (WebSocket handlers)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredWorktree {
    pub path: String,
    pub head_sha: String,
    pub branch: Option<String>,
    pub is_detached: bool,
    pub is_bare: bool,
}

/// Parse the output of `git worktree list --porcelain` into structured entries.
///
/// Porcelain format:
/// ```text
/// worktree /path/to/main
/// HEAD abc123...
/// branch refs/heads/main
///
/// worktree /path/to/linked
/// HEAD def456...
/// branch refs/heads/feature
///
/// ```
#[allow(dead_code)] // Used by discover_worktrees + unit tests
pub fn parse_worktree_porcelain(output: &str) -> Vec<DiscoveredWorktree> {
    let mut results = Vec::new();
    let mut current_path: Option<String> = None;
    let mut current_sha = String::new();
    let mut current_branch: Option<String> = None;
    let mut is_detached = false;
    let mut is_bare = false;

    for line in output.lines() {
        if line.is_empty() {
            // End of entry
            if let Some(path) = current_path.take() {
                results.push(DiscoveredWorktree {
                    path,
                    head_sha: std::mem::take(&mut current_sha),
                    branch: current_branch.take(),
                    is_detached,
                    is_bare,
                });
            }
            is_detached = false;
            is_bare = false;
            continue;
        }

        if let Some(rest) = line.strip_prefix("worktree ") {
            current_path = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("HEAD ") {
            current_sha = rest.to_string();
        } else if let Some(rest) = line.strip_prefix("branch ") {
            // refs/heads/main → main
            let branch_name = rest.strip_prefix("refs/heads/").unwrap_or(rest).to_string();
            current_branch = Some(branch_name);
        } else if line == "detached" {
            is_detached = true;
        } else if line == "bare" {
            is_bare = true;
        }
    }

    // Handle trailing entry without final blank line
    if let Some(path) = current_path.take() {
        results.push(DiscoveredWorktree {
            path,
            head_sha: current_sha,
            branch: current_branch,
            is_detached,
            is_bare,
        });
    }

    results
}

// ---------------------------------------------------------------------------
// Worktree lifecycle — async git operations
// ---------------------------------------------------------------------------

/// Discover all worktrees for a repository.
#[allow(dead_code)] // Used in Phase 9 (WebSocket handlers)
pub async fn discover_worktrees(repo_path: &str) -> Result<Vec<DiscoveredWorktree>, String> {
    let output = run_git(&["worktree", "list", "--porcelain"], repo_path)
        .await
        .unwrap_or_default();
    Ok(parse_worktree_porcelain(&output))
}

/// Create a new git worktree with a new branch.
///
/// Returns the branch name on success.
#[allow(dead_code)] // Used in Phase 9 (WebSocket handlers)
pub async fn create_worktree(
    repo_path: &str,
    worktree_path: &str,
    branch: &str,
    base_ref: Option<&str>,
) -> Result<String, String> {
    let mut args = vec!["worktree", "add", "-b", branch, worktree_path];
    if let Some(base) = base_ref {
        args.push(base);
    }
    run_git_checked(&args, repo_path).await?;
    Ok(branch.to_string())
}

/// Remove a git worktree.
#[allow(dead_code)] // Used in Phase 9 (WebSocket handlers)
pub async fn remove_worktree(
    repo_path: &str,
    worktree_path: &str,
    force: bool,
) -> Result<(), String> {
    let mut args = vec!["worktree", "remove", worktree_path];
    if force {
        args.push("--force");
    }
    run_git_checked(&args, repo_path).await
}

/// Check if a worktree path exists on disk.
#[allow(dead_code)] // Used in Phase 8 (health check cycle)
pub async fn worktree_exists_on_disk(path: &str) -> bool {
    tokio::fs::metadata(path).await.is_ok()
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run a git command and return an error with stderr on failure.
#[allow(dead_code)] // Used by create_worktree/remove_worktree
async fn run_git_checked(args: &[&str], cwd: &str) -> Result<(), String> {
    let output = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("git spawn failed: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "git {} failed: {}",
            args.first().unwrap_or(&""),
            stderr.trim()
        ));
    }

    Ok(())
}

async fn run_git(args: &[&str], cwd: &str) -> Option<String> {
    let output = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- classify_common_dir (pure, no git) -----------------------------------

    #[test]
    fn classify_main_worktree_relative() {
        assert_eq!(
            classify_common_dir("/repos/project", ".git"),
            "/repos/project"
        );
    }

    #[test]
    fn classify_main_worktree_absolute() {
        assert_eq!(
            classify_common_dir("/repos/project", "/repos/project/.git"),
            "/repos/project"
        );
    }

    #[test]
    fn classify_linked_worktree() {
        assert_eq!(
            classify_common_dir(
                "/repos/project/.orbitdock-worktrees/fix-auth",
                "/repos/project/.git/worktrees/fix-auth"
            ),
            "/repos/project"
        );
    }

    #[test]
    fn classify_linked_worktree_nested_repo() {
        assert_eq!(
            classify_common_dir(
                "/home/user/dev/my-repo/wt/feature",
                "/home/user/dev/my-repo/.git/worktrees/feature"
            ),
            "/home/user/dev/my-repo"
        );
    }

    #[test]
    fn classify_trailing_slashes() {
        assert_eq!(
            classify_common_dir(
                "/repos/project/.orbitdock-worktrees/fix-auth",
                "/repos/project/.git/worktrees/fix-auth/"
            ),
            "/repos/project"
        );
    }

    #[test]
    fn classify_fallback_on_unknown_format() {
        assert_eq!(
            classify_common_dir("/repos/project", "something-weird"),
            "/repos/project"
        );
    }

    // -- parse_worktree_porcelain (pure, no git) ------------------------------

    #[test]
    fn parse_normal_worktrees() {
        let output = "\
worktree /repos/project
HEAD abc123def456
branch refs/heads/main

worktree /repos/project/.orbitdock-worktrees/feature
HEAD 789012345678
branch refs/heads/feature

";
        let result = parse_worktree_porcelain(output);
        assert_eq!(result.len(), 2);

        assert_eq!(result[0].path, "/repos/project");
        assert_eq!(result[0].head_sha, "abc123def456");
        assert_eq!(result[0].branch.as_deref(), Some("main"));
        assert!(!result[0].is_detached);
        assert!(!result[0].is_bare);

        assert_eq!(
            result[1].path,
            "/repos/project/.orbitdock-worktrees/feature"
        );
        assert_eq!(result[1].head_sha, "789012345678");
        assert_eq!(result[1].branch.as_deref(), Some("feature"));
    }

    #[test]
    fn parse_detached_head() {
        let output = "\
worktree /repos/project
HEAD abc123def456
detached

";
        let result = parse_worktree_porcelain(output);
        assert_eq!(result.len(), 1);
        assert!(result[0].is_detached);
        assert!(result[0].branch.is_none());
    }

    #[test]
    fn parse_bare_repo() {
        let output = "\
worktree /repos/project.git
HEAD abc123def456
bare

";
        let result = parse_worktree_porcelain(output);
        assert_eq!(result.len(), 1);
        assert!(result[0].is_bare);
    }

    #[test]
    fn parse_empty_output() {
        let result = parse_worktree_porcelain("");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_without_trailing_newline() {
        let output = "\
worktree /repos/project
HEAD abc123def456
branch refs/heads/main";
        let result = parse_worktree_porcelain(output);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, "/repos/project");
        assert_eq!(result[0].branch.as_deref(), Some("main"));
    }

    // -- Integration tests (require git) --------------------------------------

    #[tokio::test]
    async fn resolve_git_info_normal_repo() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().to_str().unwrap();

        // Init a repo and make a commit so HEAD exists
        run_git_checked(&["init", dir], dir).await.unwrap();
        run_git_checked(&["config", "user.email", "test@test.com"], dir)
            .await
            .unwrap();
        run_git_checked(&["config", "user.name", "Test"], dir)
            .await
            .unwrap();
        std::fs::write(tmp.path().join("README.md"), "hello").unwrap();
        run_git_checked(&["add", "."], dir).await.unwrap();
        run_git_checked(&["commit", "-m", "init"], dir)
            .await
            .unwrap();

        let info = resolve_git_info(dir).await.expect("should resolve");
        assert!(!info.is_worktree);
        assert_eq!(info.toplevel, info.common_dir_root);
        assert!(!info.sha.is_empty());
        // Branch should be main or master depending on git config
        assert!(info.branch == "main" || info.branch == "master");
    }

    #[tokio::test]
    async fn resolve_git_info_linked_worktree() {
        let tmp = tempfile::tempdir().unwrap();
        // Canonicalize to resolve macOS /var → /private/var symlink
        let base = tmp.path().canonicalize().unwrap();
        let repo_dir = base.join("repo");
        let wt_dir = base.join("worktree");
        let repo = repo_dir.to_str().unwrap();
        let wt = wt_dir.to_str().unwrap();

        // Init repo with a commit
        std::fs::create_dir_all(&repo_dir).unwrap();
        run_git_checked(&["init", repo], repo).await.unwrap();
        run_git_checked(&["config", "user.email", "test@test.com"], repo)
            .await
            .unwrap();
        run_git_checked(&["config", "user.name", "Test"], repo)
            .await
            .unwrap();
        std::fs::write(repo_dir.join("README.md"), "hello").unwrap();
        run_git_checked(&["add", "."], repo).await.unwrap();
        run_git_checked(&["commit", "-m", "init"], repo)
            .await
            .unwrap();

        // Create linked worktree
        run_git_checked(&["worktree", "add", "-b", "feature", wt], repo)
            .await
            .unwrap();

        let info = resolve_git_info(wt).await.expect("should resolve");
        assert!(info.is_worktree);
        assert_eq!(info.branch, "feature");
        // common_dir_root should point to the parent repo
        assert_eq!(info.common_dir_root, repo);
        assert_ne!(info.toplevel, info.common_dir_root);
    }

    #[tokio::test]
    async fn resolve_git_info_non_git_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().to_str().unwrap();
        let info = resolve_git_info(dir).await;
        assert!(info.is_none());
    }

    #[tokio::test]
    async fn create_and_remove_worktree() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_dir = tmp.path().join("repo");
        let wt_dir = tmp.path().join("wt-test");
        let repo = repo_dir.to_str().unwrap();
        let wt = wt_dir.to_str().unwrap();

        // Init repo
        std::fs::create_dir_all(&repo_dir).unwrap();
        run_git_checked(&["init", repo], repo).await.unwrap();
        run_git_checked(&["config", "user.email", "test@test.com"], repo)
            .await
            .unwrap();
        run_git_checked(&["config", "user.name", "Test"], repo)
            .await
            .unwrap();
        std::fs::write(repo_dir.join("README.md"), "hello").unwrap();
        run_git_checked(&["add", "."], repo).await.unwrap();
        run_git_checked(&["commit", "-m", "init"], repo)
            .await
            .unwrap();

        // Create worktree
        let branch = create_worktree(repo, wt, "test-branch", None)
            .await
            .unwrap();
        assert_eq!(branch, "test-branch");
        assert!(worktree_exists_on_disk(wt).await);

        // Discover should find it
        let wts = discover_worktrees(repo).await.unwrap();
        assert!(wts.len() >= 2); // main + linked

        // Remove it
        remove_worktree(repo, wt, false).await.unwrap();
        assert!(!worktree_exists_on_disk(wt).await);
    }
}
