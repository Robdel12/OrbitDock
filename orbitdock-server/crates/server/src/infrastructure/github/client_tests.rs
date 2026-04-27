use super::super::models::*;
use super::*;

fn make_client() -> GitHubClient {
  GitHubClient::new("fake-token".to_string())
}

fn issue_item(status: Option<&str>, labels: &[&str]) -> ProjectItem {
  ProjectItem {
    field_value_by_name: status.map(|s| StatusFieldValue {
      name: Some(s.to_string()),
    }),
    content: Some(ProjectItemContent::Issue(Box::new(GitHubIssueNode {
      id: "I_1".to_string(),
      number: 1,
      title: "Test issue".to_string(),
      body: None,
      url: "https://github.com/test/repo/issues/1".to_string(),
      created_at: None,
      state: "OPEN".to_string(),
      labels: LabelConnection {
        nodes: labels
          .iter()
          .map(|l| GitHubLabel {
            name: l.to_string(),
          })
          .collect(),
      },
      repository: RepositoryRef {
        name: "repo".to_string(),
        owner: RepositoryOwner {
          login: "test".to_string(),
        },
      },
    }))),
  }
}

fn pr_item() -> ProjectItem {
  ProjectItem {
    field_value_by_name: Some(StatusFieldValue {
      name: Some("Todo".to_string()),
    }),
    content: Some(ProjectItemContent::PullRequest(GitHubPRNode {})),
  }
}

fn draft_item() -> ProjectItem {
  ProjectItem {
    field_value_by_name: Some(StatusFieldValue {
      name: Some("Todo".to_string()),
    }),
    content: Some(ProjectItemContent::DraftIssue(DraftIssueNode {})),
  }
}

fn issue_items_for_filter_contracts() -> Vec<ProjectItem> {
  let mut empty_status = issue_item(None, &[]);
  empty_status.field_value_by_name = Some(StatusFieldValue { name: None });

  vec![
    issue_item(Some("In Progress"), &["Bug"]),
    issue_item(Some("in progress"), &["bug"]),
    issue_item(Some("IN PROGRESS"), &["BUG"]),
    issue_item(Some("Todo"), &["feature"]),
    issue_item(None, &["bug"]),
    empty_status,
  ]
}

fn issue_items_for_unfiltered_contract() -> Vec<ProjectItem> {
  vec![
    issue_item(Some("Todo"), &[]),
    issue_item(None, &["bug"]),
    issue_item(None, &["enhancement", "p1"]),
    issue_item(None, &["docs"]),
  ]
}

#[test]
fn parse_identifier_accepts_valid_inputs_and_rejects_invalid_ones() {
  for (input, expected_owner, expected_repo, expected_number) in [
    ("owner/repo#42", "owner", "repo", 42),
    ("my-org/my-repo#99999", "my-org", "my-repo", 99_999),
  ] {
    let (owner, repo, number) = GitHubClient::parse_identifier(input).unwrap();
    assert_eq!(owner, expected_owner);
    assert_eq!(repo, expected_repo);
    assert_eq!(number, expected_number);
  }

  for (input, expected_message) in [
    ("owner/repo42", "Invalid GitHub identifier format"),
    ("/repo#42", "Invalid GitHub identifier format"),
    ("owner/#42", "Invalid GitHub identifier format"),
    ("owner/repo#abc", "Invalid issue number"),
  ] {
    let err = GitHubClient::parse_identifier(input).unwrap_err();
    assert!(
      err.to_string().contains(expected_message),
      "unexpected error for {input}: {err}"
    );
  }
}

#[test]
fn filter_project_items_honors_case_insensitive_status_and_label_filters() {
  let client = make_client();
  let status_matches = client.filter_project_items(
    issue_items_for_filter_contracts(),
    &["in progress".to_string()],
    &[],
  );
  assert_eq!(status_matches.len(), 3);

  let label_matches = client.filter_project_items(
    issue_items_for_filter_contracts(),
    &[],
    &["bug".to_string()],
  );
  assert_eq!(label_matches.len(), 4);

  let combined = client.filter_project_items(
    issue_items_for_filter_contracts(),
    &["in progress".to_string()],
    &["bug".to_string()],
  );
  assert_eq!(combined.len(), 3);
  assert!(combined
    .iter()
    .all(|issue| issue.state.eq_ignore_ascii_case("In Progress")));
}

#[test]
fn filter_project_items_returns_all_issues_without_filters_and_requires_a_real_match() {
  let client = make_client();
  let unfiltered = client.filter_project_items(issue_items_for_unfiltered_contract(), &[], &[]);
  assert_eq!(unfiltered.len(), 4);

  let label_filtered = client.filter_project_items(
    issue_items_for_unfiltered_contract(),
    &[],
    &["p1".to_string()],
  );
  assert_eq!(label_filtered.len(), 1);
  assert_eq!(label_filtered[0].title, "Test issue");
}

#[test]
fn skips_pull_request_items() {
  let client = make_client();
  let items = vec![pr_item(), issue_item(Some("Todo"), &[])];
  let filter = vec!["Todo".to_string()];
  let result = client.filter_project_items(items, &filter, &[]);
  assert_eq!(result.len(), 1);
}

#[test]
fn skips_draft_issue_items() {
  let client = make_client();
  let items = vec![draft_item(), issue_item(Some("Todo"), &[])];
  let filter = vec!["Todo".to_string()];
  let result = client.filter_project_items(items, &filter, &[]);
  assert_eq!(result.len(), 1);
}

#[test]
fn combined_status_and_label_filter() {
  let client = make_client();
  let items = vec![
    issue_item(Some("Todo"), &["bug"]),
    issue_item(Some("Todo"), &["feature"]),
    issue_item(Some("Done"), &["bug"]),
  ];
  let result = client.filter_project_items(items, &["Todo".to_string()], &["bug".to_string()]);
  assert_eq!(result.len(), 1);
  assert_eq!(result[0].state, "Todo");
}

#[test]
fn status_propagated_to_tracker_issue_state() {
  let client = make_client();
  let items = vec![issue_item(Some("In Review"), &[])];
  let result = client.filter_project_items(items, &[], &[]);
  assert_eq!(result[0].state, "In Review");
}

#[test]
fn no_status_uses_issue_state_when_no_filter() {
  let client = make_client();
  let items = vec![issue_item(None, &[])];
  let result = client.filter_project_items(items, &[], &[]);
  assert_eq!(result[0].state, "OPEN");
}
