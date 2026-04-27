use orbitdock_protocol::SessionStatus;

use super::{build_git_refresh_candidate, plan_git_refresh_delta};
use crate::domain::git::repo::GitInfo;

#[test]
fn refresh_candidate_requires_active_subscribed_session_with_non_empty_cwd() {
  assert!(build_git_refresh_candidate(
    "session-1",
    SessionStatus::Ended,
    1,
    Some("/tmp/repo"),
    "/tmp/repo",
    None,
    None,
  )
  .is_none());
  assert!(build_git_refresh_candidate(
    "session-1",
    SessionStatus::Active,
    0,
    Some("/tmp/repo"),
    "/tmp/repo",
    None,
    None,
  )
  .is_none());
  assert!(build_git_refresh_candidate(
    "session-1",
    SessionStatus::Active,
    1,
    Some("   "),
    "",
    None,
    None,
  )
  .is_none());
}

#[test]
fn refresh_candidate_falls_back_to_project_path_and_keeps_existing_git_state() {
  let candidate = build_git_refresh_candidate(
    "session-1",
    SessionStatus::Active,
    2,
    None,
    "/tmp/repo",
    Some("main"),
    Some("abc123"),
  )
  .expect("candidate");

  assert_eq!(candidate.session_id, "session-1");
  assert_eq!(candidate.cwd, "/tmp/repo");
  assert_eq!(candidate.old_branch.as_deref(), Some("main"));
  assert_eq!(candidate.old_sha.as_deref(), Some("abc123"));
}

#[test]
fn git_refresh_delta_only_emits_when_branch_or_sha_changes() {
  let unchanged = GitInfo {
    toplevel: "/tmp/repo".to_string(),
    common_dir_root: "/tmp/repo".to_string(),
    branch: "main".to_string(),
    sha: "abc123".to_string(),
    is_worktree: false,
  };
  let changed = GitInfo {
    branch: "feature".to_string(),
    sha: "def456".to_string(),
    common_dir_root: "/tmp/repo".to_string(),
    is_worktree: true,
    ..unchanged.clone()
  };

  assert!(plan_git_refresh_delta(Some("main"), Some("abc123"), &unchanged).is_none());

  let delta = plan_git_refresh_delta(Some("main"), Some("abc123"), &changed)
    .expect("delta when git state changes");
  assert_eq!(delta.git_branch, Some(Some("feature".to_string())));
  assert_eq!(delta.git_sha, Some(Some("def456".to_string())));
  assert_eq!(delta.repository_root, Some(Some("/tmp/repo".to_string())));
  assert_eq!(delta.is_worktree, Some(true));
}
