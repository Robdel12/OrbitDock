use super::tracker::TrackerIssue;

/// Check whether an issue is eligible for dispatch.
///
/// An issue is eligible when:
/// - It is not already running or claimed
/// - The total running count is below max_concurrent
pub fn is_eligible(
  issue: &TrackerIssue,
  running_ids: &std::collections::HashSet<String>,
  claimed_ids: &std::collections::HashSet<String>,
  max_concurrent: u32,
  current_running: u32,
) -> bool {
  if running_ids.contains(&issue.id) || claimed_ids.contains(&issue.id) {
    return false;
  }
  current_running < max_concurrent
}

/// Sort issues by (priority ASC, created_at ASC, identifier ASC).
/// Lower priority number = higher priority. None priority sorts last.
pub fn sort_candidates(issues: &mut [TrackerIssue]) {
  issues.sort_by(|a, b| {
    let pri_a = a.priority.unwrap_or(i32::MAX);
    let pri_b = b.priority.unwrap_or(i32::MAX);
    pri_a
      .cmp(&pri_b)
      .then_with(|| {
        let ca = a.created_at.as_deref().unwrap_or("");
        let cb = b.created_at.as_deref().unwrap_or("");
        ca.cmp(cb)
      })
      .then_with(|| a.identifier.cmp(&b.identifier))
  });
}

#[cfg(test)]
#[path = "eligibility_tests.rs"]
mod tests;
