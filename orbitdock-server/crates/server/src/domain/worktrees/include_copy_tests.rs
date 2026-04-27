use super::*;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
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

  crate::domain::git::repo::create_worktree(
    repo.to_string_lossy().as_ref(),
    &worktree,
    branch,
    Some("HEAD"),
    false,
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
  assert_eq!(summary.errored_entries, 0);
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
  std::fs::write(repo.join("not-ignored.txt"), "do not copy\n").expect("write non-ignored file");

  let worktree = create_worktree(&repo, "feature-intersection").await;

  let summary = copy_worktreeinclude(
    repo.to_string_lossy().as_ref(),
    worktree.to_string_lossy().as_ref(),
  )
  .await
  .expect("copy should succeed");

  assert!(summary.manifest_found);
  assert_eq!(summary.matched_entries, 2);
  assert_eq!(summary.errored_entries, 0);
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
  assert_eq!(summary.errored_entries, 0);
  let worktree_contents = std::fs::read_to_string(worktree.join("tracked.env"))
    .expect("tracked file should exist from checkout");
  assert_eq!(worktree_contents, "committed\n");
}

#[cfg(unix)]
#[tokio::test]
async fn copy_is_best_effort_when_one_entry_fails() {
  let (_tmp, repo) = setup_repo();

  std::fs::write(repo.join(".gitignore"), "bad-copy.txt\ngood-copy.txt\n")
    .expect("write gitignore");
  std::fs::write(
    repo.join(".worktreeinclude"),
    "bad-copy.txt\ngood-copy.txt\n",
  )
  .expect("write include");
  std::fs::write(repo.join("bad-copy.txt"), "restricted\n").expect("write bad file");
  std::fs::write(repo.join("good-copy.txt"), "good\n").expect("write good file");

  let mut restricted_mode = std::fs::metadata(repo.join("bad-copy.txt"))
    .expect("read bad metadata")
    .permissions();
  restricted_mode.set_mode(0o000);
  std::fs::set_permissions(repo.join("bad-copy.txt"), restricted_mode)
    .expect("restrict permissions");

  let worktree = create_worktree(&repo, "feature-best-effort").await;

  let summary = copy_worktreeinclude(
    repo.to_string_lossy().as_ref(),
    worktree.to_string_lossy().as_ref(),
  )
  .await
  .expect("copy should succeed");

  let mut restored_mode = std::fs::metadata(repo.join("bad-copy.txt"))
    .expect("read bad metadata for restore")
    .permissions();
  restored_mode.set_mode(0o644);
  std::fs::set_permissions(repo.join("bad-copy.txt"), restored_mode).expect("restore permissions");

  assert!(summary.manifest_found);
  assert_eq!(summary.matched_entries, 2);
  assert_eq!(summary.copied_entries, 1);
  assert_eq!(summary.errored_entries, 1);
  assert!(worktree.join("good-copy.txt").exists());
  assert!(!worktree.join("bad-copy.txt").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn symlinked_worktreeinclude_is_supported() {
  let (_tmp, repo) = setup_repo();

  std::fs::write(repo.join(".gitignore"), ".env.local\n").expect("write gitignore");
  std::fs::write(repo.join(".wtpatterns"), ".env.local\n").expect("write patterns");
  std::os::unix::fs::symlink(".wtpatterns", repo.join(".worktreeinclude")).expect("create symlink");
  std::fs::write(repo.join(".env.local"), "SYMLINK_TEST=1\n").expect("write env");

  let worktree = create_worktree(&repo, "feature-symlink-manifest").await;

  let summary = copy_worktreeinclude(
    repo.to_string_lossy().as_ref(),
    worktree.to_string_lossy().as_ref(),
  )
  .await
  .expect("copy should succeed");

  assert!(summary.manifest_found);
  assert_eq!(summary.errored_entries, 0);
  assert!(worktree.join(".env.local").exists());
}
