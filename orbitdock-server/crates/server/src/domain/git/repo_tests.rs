use super::*;
use futures::future::join_all;
use tempfile::tempdir;

async fn configure_repo_identity(repo: &str) {
  run_git_checked(&["config", "user.email", "test@test.com"], repo)
    .await
    .expect("git config email");
  run_git_checked(&["config", "user.name", "Test"], repo)
    .await
    .expect("git config name");
}

async fn commit_file(repo: &str, path: &str, contents: &str) {
  std::fs::write(std::path::Path::new(repo).join(path), contents).expect("write file");
  run_git_checked(&["add", "."], repo).await.expect("git add");
  run_git_checked(&["commit", "-m", "init"], repo)
    .await
    .expect("git commit");
}

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

#[tokio::test]
async fn create_worktree_serializes_remote_tracking_setup_per_repo() {
  let temp = tempdir().expect("tempdir");
  let origin = temp.path().join("origin.git");
  let seed = temp.path().join("seed");
  let repo = temp.path().join("repo");

  run_git_checked(
    &["init", "--bare", origin.to_string_lossy().as_ref()],
    temp.path().to_string_lossy().as_ref(),
  )
  .await
  .expect("git init --bare");

  run_git_checked(
    &[
      "clone",
      origin.to_string_lossy().as_ref(),
      seed.to_string_lossy().as_ref(),
    ],
    temp.path().to_string_lossy().as_ref(),
  )
  .await
  .expect("git clone seed");
  configure_repo_identity(seed.to_string_lossy().as_ref()).await;
  commit_file(seed.to_string_lossy().as_ref(), "README.md", "hello").await;
  run_git_checked(&["branch", "-M", "main"], seed.to_string_lossy().as_ref())
    .await
    .expect("git branch -M main");
  run_git_checked(
    &["push", "-u", "origin", "main"],
    seed.to_string_lossy().as_ref(),
  )
  .await
  .expect("git push origin main");

  run_git_checked(
    &[
      "clone",
      origin.to_string_lossy().as_ref(),
      repo.to_string_lossy().as_ref(),
    ],
    temp.path().to_string_lossy().as_ref(),
  )
  .await
  .expect("git clone repo");
  run_git_checked(&["checkout", "main"], repo.to_string_lossy().as_ref())
    .await
    .expect("git checkout main");

  let repo_path = repo.to_string_lossy().into_owned();
  let futures = (0..12).map(|idx| {
    let repo_path = repo_path.clone();
    async move {
      let branch = format!("mission/test-{idx}");
      let worktree_path = format!("{repo_path}/.orbitdock-worktrees/test-{idx}");
      create_worktree(
        &repo_path,
        &worktree_path,
        &branch,
        Some("origin/main"),
        false,
      )
      .await
    }
  });

  let results = join_all(futures).await;
  for result in results {
    assert!(
      result.is_ok(),
      "expected serialized worktree add to succeed: {result:?}"
    );
  }
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
  let branch = create_worktree(repo, wt, "test-branch", None, false)
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
