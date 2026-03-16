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
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn make_issue(id: &str, priority: Option<i32>, created_at: Option<&str>) -> TrackerIssue {
        TrackerIssue {
            id: id.to_string(),
            identifier: id.to_string(),
            title: format!("Issue {id}"),
            description: None,
            priority,
            state: "todo".to_string(),
            url: None,
            labels: vec![],
            blocked_by: vec![],
            created_at: created_at.map(|s| s.to_string()),
        }
    }

    #[test]
    fn eligible_when_not_running_and_under_limit() {
        let issue = make_issue("1", None, None);
        assert!(is_eligible(&issue, &HashSet::new(), &HashSet::new(), 3, 0));
    }

    #[test]
    fn ineligible_when_already_running() {
        let issue = make_issue("1", None, None);
        let mut running = HashSet::new();
        running.insert("1".to_string());
        assert!(!is_eligible(&issue, &running, &HashSet::new(), 3, 0));
    }

    #[test]
    fn ineligible_when_at_max_concurrent() {
        let issue = make_issue("1", None, None);
        assert!(!is_eligible(&issue, &HashSet::new(), &HashSet::new(), 3, 3));
    }

    #[test]
    fn sort_by_priority_then_date() {
        let mut issues = vec![
            make_issue("C", Some(3), Some("2024-01-03")),
            make_issue("A", Some(1), Some("2024-01-01")),
            make_issue("B", Some(1), Some("2024-01-02")),
        ];
        sort_candidates(&mut issues);
        assert_eq!(issues[0].id, "A");
        assert_eq!(issues[1].id, "B");
        assert_eq!(issues[2].id, "C");
    }
}
