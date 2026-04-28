use super::models::{ProjectItem, ProjectItemContent};
use crate::domain::mission_control::tracker::TrackerIssue;

pub(super) fn parse_identifier(identifier: &str) -> anyhow::Result<(String, String, u64)> {
  // Accept: "owner/repo#42" or "#42" (but the latter needs repo context)
  let parts: Vec<&str> = identifier.splitn(2, '#').collect();
  if parts.len() != 2 {
    anyhow::bail!("Invalid GitHub identifier format: {identifier}. Expected owner/repo#number");
  }

  let number: u64 = parts[1]
    .parse()
    .map_err(|_| anyhow::anyhow!("Invalid issue number in identifier: {identifier}"))?;

  let repo_parts: Vec<&str> = parts[0].splitn(2, '/').collect();
  if repo_parts.len() != 2 || repo_parts[0].is_empty() || repo_parts[1].is_empty() {
    anyhow::bail!("Invalid GitHub identifier format: {identifier}. Expected owner/repo#number");
  }

  Ok((repo_parts[0].to_string(), repo_parts[1].to_string(), number))
}

pub(super) fn filter_project_items(
  items: Vec<ProjectItem>,
  status_filter: &[String],
  label_filter: &[String],
) -> Vec<TrackerIssue> {
  let mut result = Vec::new();

  for item in items {
    let status = item
      .field_value_by_name
      .as_ref()
      .and_then(|v| v.name.clone());

    if !status_filter.is_empty() {
      if let Some(ref s) = status {
        if !status_filter.iter().any(|f| f.eq_ignore_ascii_case(s)) {
          continue;
        }
      } else {
        continue;
      }
    }

    let content = match item.content {
      Some(ProjectItemContent::Issue(issue)) => *issue,
      _ => continue,
    };

    if !label_filter.is_empty() {
      let has_label = content
        .labels
        .nodes
        .iter()
        .any(|l| label_filter.iter().any(|f| f.eq_ignore_ascii_case(&l.name)));
      if !has_label {
        continue;
      }
    }

    result.push(content.into_tracker_issue(status));
  }

  result
}
