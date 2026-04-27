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
#[path = "recent_projects_tests.rs"]
mod recent_projects_tests;
