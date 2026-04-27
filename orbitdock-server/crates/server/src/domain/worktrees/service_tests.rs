use super::plan_tracked_worktree;

#[test]
fn plan_tracked_worktree_normalizes_inputs_and_builds_path() {
  let planned = plan_tracked_worktree(" /repo/path/ ", " feature/refactor ", Some(" main "), None)
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
  let planned = plan_tracked_worktree("/repo", "feature", Some("   "), None).expect("planned");
  assert_eq!(planned.base_branch, None);
}
