use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::Command;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorktreeIncludeCopySummary {
    pub manifest_found: bool,
    pub matched_entries: usize,
    pub copied_entries: usize,
    pub skipped_entries: usize,
}

/// Copy files from repo root into a newly created worktree using `.worktreeinclude`.
///
/// Semantics:
/// - `.worktreeinclude` uses gitignore-style patterns.
/// - Only paths that are BOTH git-ignored (`.gitignore` and standard excludes)
///   and matched by `.worktreeinclude` are copied.
/// - Tracked files are never copied because selection is based on `git ls-files -i -o`.
pub async fn copy_worktreeinclude(
    repo_root: &str,
    worktree_path: &str,
) -> Result<WorktreeIncludeCopySummary, String> {
    let mut summary = WorktreeIncludeCopySummary::default();

    let repo_root_path = PathBuf::from(repo_root);
    let worktree_path_buf = PathBuf::from(worktree_path);
    let include_path = repo_root_path.join(".worktreeinclude");

    match tokio::fs::symlink_metadata(&include_path).await {
        Ok(metadata) => {
            if metadata.is_dir() {
                return Err(format!(
                    ".worktreeinclude must be a file (or symlink to a file): {}",
                    include_path.display()
                ));
            }
            summary.manifest_found = true;
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(summary),
        Err(err) => {
            return Err(format!(
                "Failed to read .worktreeinclude metadata at {}: {err}",
                include_path.display()
            ));
        }
    }

    let git_ignored = list_ignored_paths(repo_root, None).await?;
    let include_matched = list_ignored_paths(repo_root, Some(&include_path)).await?;

    let selected: BTreeSet<String> = include_matched
        .intersection(&git_ignored)
        .cloned()
        .collect();
    let pruned = prune_descendant_paths(selected);

    summary.matched_entries = pruned.len();

    let copy_result = tokio::task::spawn_blocking(move || {
        copy_selected_paths_blocking(&repo_root_path, &worktree_path_buf, &pruned)
    })
    .await
    .map_err(|err| format!("copy_worktreeinclude task failed: {err}"))??;

    summary.copied_entries = copy_result.copied_entries;
    summary.skipped_entries = copy_result.skipped_entries;

    Ok(summary)
}

async fn list_ignored_paths(
    repo_root: &str,
    exclude_from: Option<&Path>,
) -> Result<BTreeSet<String>, String> {
    let mut cmd = Command::new("/usr/bin/git");
    cmd.arg("ls-files")
        .arg("-i")
        .arg("-o")
        .arg("--directory")
        .arg("-z")
        .stdin(Stdio::null())
        .current_dir(repo_root);

    if let Some(path) = exclude_from {
        cmd.arg(format!("--exclude-from={}", path.display()));
    } else {
        cmd.arg("--exclude-standard");
    }

    let output = cmd
        .output()
        .await
        .map_err(|err| format!("Failed to run git ls-files: {err}"))?;

    if !output.status.success() {
        return Err(format!(
            "git ls-files failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    let mut paths = BTreeSet::new();
    for raw in output.stdout.split(|byte| *byte == 0) {
        if raw.is_empty() {
            continue;
        }
        let as_text = String::from_utf8_lossy(raw);
        if let Some(normalized) = normalize_relative_path(as_text.trim()) {
            paths.insert(normalized);
        }
    }

    Ok(paths)
}

fn normalize_relative_path(input: &str) -> Option<String> {
    let trimmed = input.trim().trim_start_matches("./").trim_end_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    Some(trimmed.to_string())
}

fn prune_descendant_paths(paths: BTreeSet<String>) -> Vec<String> {
    let mut selected: Vec<String> = Vec::new();

    for path in paths {
        if path == ".git"
            || path.starts_with(".git/")
            || path == ".orbitdock-worktrees"
            || path.starts_with(".orbitdock-worktrees/")
        {
            continue;
        }

        let mut has_ancestor = false;
        for ancestor in &selected {
            if path == *ancestor || path.starts_with(&format!("{ancestor}/")) {
                has_ancestor = true;
                break;
            }
        }

        if !has_ancestor {
            selected.push(path);
        }
    }

    selected
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct CopyResult {
    copied_entries: usize,
    skipped_entries: usize,
}

fn copy_selected_paths_blocking(
    repo_root: &Path,
    worktree_path: &Path,
    selected_paths: &[String],
) -> Result<CopyResult, String> {
    let mut result = CopyResult::default();

    for rel in selected_paths {
        let source = repo_root.join(rel);
        let destination = worktree_path.join(rel);

        if !source.exists() {
            result.skipped_entries += 1;
            continue;
        }

        if destination.exists() {
            // Fresh worktrees typically do not contain ignored files; skipping protects
            // any pre-existing local state if this is ever reused on a non-fresh path.
            result.skipped_entries += 1;
            continue;
        }

        copy_path_recursive(&source, &destination)?;
        result.copied_entries += 1;
    }

    Ok(result)
}

fn copy_path_recursive(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(source)
        .map_err(|err| format!("Failed to stat {}: {err}", source.display()))?;

    let file_type = metadata.file_type();

    if file_type.is_symlink() {
        copy_symlink(source, destination)
    } else if file_type.is_dir() {
        std::fs::create_dir_all(destination)
            .map_err(|err| format!("Failed to create dir {}: {err}", destination.display()))?;

        let entries = std::fs::read_dir(source)
            .map_err(|err| format!("Failed to read dir {}: {err}", source.display()))?;

        for entry_result in entries {
            let entry = entry_result
                .map_err(|err| format!("Failed to read entry in {}: {err}", source.display()))?;
            let child_source = entry.path();
            let child_destination = destination.join(entry.file_name());
            copy_path_recursive(&child_source, &child_destination)?;
        }

        Ok(())
    } else if file_type.is_file() {
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| format!("Failed to create dir {}: {err}", parent.display()))?;
        }

        std::fs::copy(source, destination).map_err(|err| {
            format!(
                "Failed to copy {} -> {}: {err}",
                source.display(),
                destination.display()
            )
        })?;

        Ok(())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn copy_symlink(source: &Path, destination: &Path) -> Result<(), String> {
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| format!("Failed to create dir {}: {err}", parent.display()))?;
    }

    let target = std::fs::read_link(source)
        .map_err(|err| format!("Failed to read symlink {}: {err}", source.display()))?;
    std::os::unix::fs::symlink(&target, destination).map_err(|err| {
        format!(
            "Failed to create symlink {} -> {}: {err}",
            destination.display(),
            target.display()
        )
    })?;

    Ok(())
}

#[cfg(not(unix))]
fn copy_symlink(source: &Path, destination: &Path) -> Result<(), String> {
    // Fallback for non-Unix targets: dereference and copy file contents when possible.
    let target_metadata = std::fs::metadata(source)
        .map_err(|err| format!("Failed to follow symlink {}: {err}", source.display()))?;
    if target_metadata.is_dir() {
        copy_path_recursive(
            &std::fs::canonicalize(source).map_err(|err| {
                format!("Failed to canonicalize symlink {}: {err}", source.display())
            })?,
            destination,
        )
    } else {
        copy_path_recursive(
            &std::fs::canonicalize(source).map_err(|err| {
                format!("Failed to canonicalize symlink {}: {err}", source.display())
            })?,
            destination,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use tempfile::TempDir;

    fn run_git_checked(args: &[&str], cwd: &Path) {
        let output = std::process::Command::new("/usr/bin/git")
            .args(args)
            .current_dir(cwd)
            .output()
            .expect("git command should start");

        if !output.status.success() {
            panic!(
                "git {:?} failed: {}",
                args,
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    fn setup_repo() -> (TempDir, PathBuf) {
        let temp = TempDir::new().expect("temp dir");
        let repo = temp.path().join("repo");
        std::fs::create_dir_all(&repo).expect("create repo");

        run_git_checked(&["init"], &repo);
        run_git_checked(&["config", "user.name", "Test User"], &repo);
        run_git_checked(&["config", "user.email", "test@example.com"], &repo);

        std::fs::write(repo.join("README.md"), "initial\n").expect("write readme");
        run_git_checked(&["add", "README.md"], &repo);
        run_git_checked(&["commit", "-m", "initial"], &repo);

        (temp, repo)
    }

    async fn create_worktree(repo: &Path, branch: &str) -> PathBuf {
        let worktree = repo
            .join(".orbitdock-worktrees")
            .join(branch)
            .to_string_lossy()
            .to_string();

        crate::git::create_worktree(
            repo.to_string_lossy().as_ref(),
            &worktree,
            branch,
            Some("HEAD"),
        )
        .await
        .expect("create worktree");

        PathBuf::from(worktree)
    }

    #[tokio::test]
    async fn no_manifest_is_noop() {
        let (_tmp, repo) = setup_repo();
        let worktree = create_worktree(&repo, "feature-no-manifest").await;

        let summary = copy_worktreeinclude(
            repo.to_string_lossy().as_ref(),
            worktree.to_string_lossy().as_ref(),
        )
        .await
        .expect("copy should succeed");

        assert!(!summary.manifest_found);
        assert_eq!(summary.matched_entries, 0);
        assert_eq!(summary.copied_entries, 0);
    }

    #[tokio::test]
    async fn copies_only_intersection_of_worktreeinclude_and_gitignore() {
        let (_tmp, repo) = setup_repo();

        std::fs::write(
            repo.join(".gitignore"),
            "node_modules/\n.env.local\ncache/\n",
        )
        .expect("write gitignore");
        std::fs::write(
            repo.join(".worktreeinclude"),
            "node_modules/\n.env.local\nnot-ignored.txt\n",
        )
        .expect("write include");

        std::fs::create_dir_all(repo.join("node_modules/pkg")).expect("create node_modules");
        std::fs::write(
            repo.join("node_modules/pkg/index.js"),
            "module.exports = {};\n",
        )
        .expect("write node module");
        std::fs::write(repo.join(".env.local"), "API_KEY=local\n").expect("write env");
        std::fs::write(repo.join("not-ignored.txt"), "do not copy\n")
            .expect("write non-ignored file");

        let worktree = create_worktree(&repo, "feature-intersection").await;

        let summary = copy_worktreeinclude(
            repo.to_string_lossy().as_ref(),
            worktree.to_string_lossy().as_ref(),
        )
        .await
        .expect("copy should succeed");

        assert!(summary.manifest_found);
        assert_eq!(summary.matched_entries, 2);
        assert!(worktree.join("node_modules/pkg/index.js").exists());
        assert!(worktree.join(".env.local").exists());
        assert!(!worktree.join("not-ignored.txt").exists());
    }

    #[tokio::test]
    async fn tracked_files_are_not_copied_even_if_patterns_match() {
        let (_tmp, repo) = setup_repo();

        std::fs::write(repo.join(".gitignore"), "tracked.env\n").expect("write gitignore");
        std::fs::write(repo.join(".worktreeinclude"), "tracked.env\n").expect("write include");

        std::fs::write(repo.join("tracked.env"), "committed\n").expect("write tracked file");
        run_git_checked(&["add", "-f", "tracked.env", ".gitignore"], &repo);
        run_git_checked(&["commit", "-m", "track ignored file"], &repo);

        // Simulate local mutation in source repo that must NOT be mirrored.
        std::fs::write(repo.join("tracked.env"), "local-mutation\n").expect("mutate tracked file");

        let worktree = create_worktree(&repo, "feature-tracked-protection").await;

        let summary = copy_worktreeinclude(
            repo.to_string_lossy().as_ref(),
            worktree.to_string_lossy().as_ref(),
        )
        .await
        .expect("copy should succeed");

        assert_eq!(summary.matched_entries, 0);
        let worktree_contents = std::fs::read_to_string(worktree.join("tracked.env"))
            .expect("tracked file should exist from checkout");
        assert_eq!(worktree_contents, "committed\n");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlinked_worktreeinclude_is_supported() {
        let (_tmp, repo) = setup_repo();

        std::fs::write(repo.join(".gitignore"), ".env.local\n").expect("write gitignore");
        std::fs::write(repo.join(".wtpatterns"), ".env.local\n").expect("write patterns");
        std::os::unix::fs::symlink(".wtpatterns", repo.join(".worktreeinclude"))
            .expect("create symlink");
        std::fs::write(repo.join(".env.local"), "SYMLINK_TEST=1\n").expect("write env");

        let worktree = create_worktree(&repo, "feature-symlink-manifest").await;

        let summary = copy_worktreeinclude(
            repo.to_string_lossy().as_ref(),
            worktree.to_string_lossy().as_ref(),
        )
        .await
        .expect("copy should succeed");

        assert!(summary.manifest_found);
        assert!(worktree.join(".env.local").exists());
    }
}
