use std::collections::HashSet;

use super::collect_recent_projects;

#[test]
fn collect_recent_projects_hides_removed_worktree_paths() {
  let removed_paths = HashSet::from([String::from("/repo/.orbitdock-worktrees/feature-a")]);
  let projects = collect_recent_projects(
    vec![
      (
        String::from("/repo/.orbitdock-worktrees/feature-a"),
        Some(String::from("2026-03-08T12:00:00Z")),
      ),
      (
        String::from("/repo/.orbitdock-worktrees/feature-b"),
        Some(String::from("2026-03-08T11:00:00Z")),
      ),
      (
        String::from("/repo"),
        Some(String::from("2026-03-08T10:00:00Z")),
      ),
    ],
    &removed_paths,
  );

  assert_eq!(projects.len(), 2);
  assert_eq!(projects[0].path, "/repo/.orbitdock-worktrees/feature-b");
  assert_eq!(projects[1].path, "/repo");
}

#[test]
fn collect_recent_projects_aggregates_counts_and_latest_activity_for_visible_paths() {
  let projects = collect_recent_projects(
    vec![
      (
        String::from("/repo"),
        Some(String::from("2026-03-08T09:00:00Z")),
      ),
      (
        String::from("/other"),
        Some(String::from("2026-03-08T08:00:00Z")),
      ),
      (
        String::from("/repo"),
        Some(String::from("2026-03-08T12:00:00Z")),
      ),
    ],
    &HashSet::new(),
  );

  assert_eq!(projects.len(), 2);
  assert_eq!(projects[0].path, "/repo");
  assert_eq!(projects[0].session_count, 2);
  assert_eq!(
    projects[0].last_active.as_deref(),
    Some("2026-03-08T12:00:00Z")
  );
  assert_eq!(projects[1].path, "/other");
}
