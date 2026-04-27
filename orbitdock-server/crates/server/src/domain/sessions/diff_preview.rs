use orbitdock_protocol::{DashboardDiffPreview, TurnDiff};

pub(crate) fn has_turn_diff(current_diff: Option<&str>, turn_diffs: &[TurnDiff]) -> bool {
  current_diff.is_some() || !turn_diffs.is_empty()
}

/// Build the lightweight dashboard diff summary from archived turn diffs plus
/// the optional live turn diff. Keep the heavy diff bodies out of dashboard
/// transport; the sidebar only needs counts and a few representative paths.
pub(crate) fn build_dashboard_diff_preview(
  current_diff: Option<&str>,
  turn_diffs: &[TurnDiff],
) -> Option<DashboardDiffPreview> {
  let mut accumulator = DashboardDiffPreviewAccumulator::default();

  for turn_diff in turn_diffs {
    accumulator.add_diff(&turn_diff.diff);
  }
  if let Some(diff) = current_diff {
    accumulator.add_diff(diff);
  }

  accumulator.finish()
}

#[derive(Default)]
struct DashboardDiffPreviewAccumulator {
  file_paths: Vec<String>,
  additions: u32,
  deletions: u32,
}

impl DashboardDiffPreviewAccumulator {
  fn add_diff(&mut self, diff: &str) {
    let diff = diff.trim();
    if diff.is_empty() {
      return;
    }

    for line in diff.lines() {
      if let Some(path) = line.strip_prefix("+++ b/") {
        self.add_file_path(path);
        continue;
      }
      if let Some(path) = line
        .strip_prefix("diff --git ")
        .and_then(|rest| rest.split(" b/").nth(1))
      {
        self.add_file_path(path);
        continue;
      }
      if line.starts_with('+') && !line.starts_with("+++") {
        self.additions = self.additions.saturating_add(1);
      } else if line.starts_with('-') && !line.starts_with("---") {
        self.deletions = self.deletions.saturating_add(1);
      }
    }
  }

  fn add_file_path(&mut self, path: &str) {
    let path = path.trim();
    if path.is_empty() || self.file_paths.iter().any(|existing| existing == path) {
      return;
    }
    self.file_paths.push(path.to_string());
  }

  fn finish(self) -> Option<DashboardDiffPreview> {
    let has_content = !self.file_paths.is_empty() || self.additions > 0 || self.deletions > 0;
    if !has_content {
      return None;
    }

    Some(DashboardDiffPreview {
      file_count: self.file_paths.len() as u32,
      additions: self.additions,
      deletions: self.deletions,
      file_paths: self.file_paths.into_iter().take(3).collect(),
    })
  }
}

#[cfg(test)]
#[path = "diff_preview_tests.rs"]
mod diff_preview_tests;
