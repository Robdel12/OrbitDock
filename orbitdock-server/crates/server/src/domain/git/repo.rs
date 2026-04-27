//! Shared git utilities for resolving branch/repo info from a working directory.
//!
//! Pure classification functions (`classify_common_dir`, `parse_worktree_porcelain`)
//! are separated from async I/O so they can be unit-tested without a git repo.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::process::Command;
use tokio::sync::Mutex as AsyncMutex;

static REPO_MUTATION_LOCKS: OnceLock<Mutex<HashMap<String, Arc<AsyncMutex<()>>>>> = OnceLock::new();

fn repo_mutation_locks() -> &'static Mutex<HashMap<String, Arc<AsyncMutex<()>>>> {
  REPO_MUTATION_LOCKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn repo_mutation_lock(repo_path: &str) -> Arc<AsyncMutex<()>> {
  let normalized = repo_path.trim().trim_end_matches('/').to_string();
  let mut locks = repo_mutation_locks().lock().expect("repo mutation locks");
  locks
    .entry(normalized)
    .or_insert_with(|| Arc::new(AsyncMutex::new(())))
    .clone()
}

// ---------------------------------------------------------------------------
// GitInfo — rich resolution result
// ---------------------------------------------------------------------------

/// Full git context for a working directory.
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

/// Resolve just the git branch from a working directory.
pub async fn resolve_git_branch(path: &str) -> Option<String> {
  run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path).await
}

/// Resolve the clone URL for `origin`, if configured.
pub async fn resolve_origin_url(path: &str) -> Option<String> {
  run_git(&["config", "--get", "remote.origin.url"], path).await
}

/// Resolve full git context for a path, or `None` if not inside a git repo.
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
pub async fn discover_worktrees(repo_path: &str) -> Result<Vec<DiscoveredWorktree>, String> {
  let output = run_git(&["worktree", "list", "--porcelain"], repo_path)
    .await
    .unwrap_or_default();
  Ok(parse_worktree_porcelain(&output))
}

/// Create a new git worktree with a new branch.
///
/// Returns the branch name on success.
pub async fn create_worktree(
  repo_path: &str,
  worktree_path: &str,
  branch: &str,
  base_ref: Option<&str>,
  cleanup_existing: bool,
) -> Result<String, String> {
  // `git worktree add <path> <remote/ref>` updates `.git/config` to write
  // upstream tracking metadata. Git uses a repository-global config lock for
  // that write, so concurrent worktree creation against the same repo can fail
  // with `could not lock config file .git/config`. Serialize those mutations
  // per repo while still allowing different repos to proceed in parallel.
  let repo_lock = repo_mutation_lock(repo_path);
  let _guard = repo_lock.lock().await;

  let mut args = vec!["worktree", "add", "-b", branch, worktree_path];
  if let Some(base) = base_ref {
    args.push(base);
  }
  match run_git_checked(&args, repo_path).await {
    Ok(()) => Ok(branch.to_string()),
    Err(e) if e.contains("already exists") && cleanup_existing => {
      // Clean up stale worktree + branch from a prior run, then retry
      let _ = remove_worktree(repo_path, worktree_path, true).await;
      let _ = run_git_checked(&["branch", "-D", branch], repo_path).await;

      let mut retry_args = vec!["worktree", "add", "-b", branch, worktree_path];
      if let Some(base) = base_ref {
        retry_args.push(base);
      }
      run_git_checked(&retry_args, repo_path).await?;
      Ok(branch.to_string())
    }
    Err(e) if e.contains("already exists") => Err(format!(
      "Branch '{branch}' already exists from a prior run. \
             Clean up with: git worktree remove {worktree_path} --force && git branch -D {branch}"
    )),
    Err(e) => Err(e),
  }
}

/// Remove a git worktree.
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

/// Delete a local git branch.
pub async fn delete_branch(repo_path: &str, branch: &str) -> Result<(), String> {
  run_git_checked(&["branch", "-d", branch], repo_path).await
}

/// Delete a remote branch from `origin`.
pub async fn delete_remote_branch(repo_path: &str, branch: &str) -> Result<(), String> {
  run_git_checked(&["push", "origin", "--delete", branch], repo_path).await
}

/// Fetch the latest refs from `origin`.
pub async fn fetch_origin(repo_path: &str) -> Result<(), String> {
  run_git_checked(&["fetch", "origin"], repo_path).await
}

/// Initialize a new git repository at the given path.
pub async fn git_init(path: &str) -> Result<(), String> {
  run_git_checked(&["init"], path).await
}

/// Check if a worktree path exists on disk.
pub async fn worktree_exists_on_disk(path: &str) -> bool {
  tokio::fs::metadata(path).await.is_ok()
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run a git command and return an error with stderr on failure.
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
#[path = "repo_tests.rs"]
mod tests;
