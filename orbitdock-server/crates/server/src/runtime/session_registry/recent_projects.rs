use orbitdock_protocol::RecentProject;
use std::collections::{HashMap, HashSet};

pub(crate) fn collect_recent_projects<I>(
    sessions: I,
    hidden_paths: &HashSet<String>,
) -> Vec<RecentProject>
where
    I: IntoIterator<Item = (String, Option<String>)>,
{
    let mut project_map: HashMap<String, (u32, Option<String>)> = HashMap::new();
    for (path, last_activity) in sessions {
        if hidden_paths.contains(&path) {
            continue;
        }

        let counter = project_map.entry(path).or_insert((0, None));
        counter.0 += 1;
        if let Some(ref activity) = last_activity {
            if counter
                .1
                .as_ref()
                .is_none_or(|existing| activity > existing)
            {
                counter.1 = last_activity;
            }
        }
    }

    let mut projects: Vec<RecentProject> = project_map
        .into_iter()
        .map(|(path, (session_count, last_active))| RecentProject {
            path,
            session_count,
            last_active,
        })
        .collect();

    projects.sort_by(|a, b| b.last_active.cmp(&a.last_active));
    projects
}

#[cfg(test)]
mod tests {
    use super::collect_recent_projects;
    use std::collections::HashSet;

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
}
