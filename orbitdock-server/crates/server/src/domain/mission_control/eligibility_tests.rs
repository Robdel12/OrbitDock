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
    created_at: created_at.map(|s| s.to_string()),
  }
}

#[test]
fn eligibility_depends_on_running_claimed_and_capacity_constraints() {
  let issue = make_issue("1", None, None);
  let mut running = HashSet::new();
  running.insert("1".to_string());
  let mut claimed = HashSet::new();
  claimed.insert("1".to_string());

  assert!(is_eligible(&issue, &HashSet::new(), &HashSet::new(), 3, 0));
  assert!(!is_eligible(&issue, &running, &HashSet::new(), 3, 0));
  assert!(!is_eligible(&issue, &HashSet::new(), &claimed, 3, 0));
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
