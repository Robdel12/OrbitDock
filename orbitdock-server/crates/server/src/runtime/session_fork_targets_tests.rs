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
