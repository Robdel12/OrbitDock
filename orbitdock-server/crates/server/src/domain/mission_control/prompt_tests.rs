use super::*;

fn default_issue<'a>() -> IssueContext<'a> {
  IssueContext {
    issue_id: "id-1",
    issue_identifier: "PROJ-1",
    issue_title: "Bug",
    issue_description: None,
    issue_url: None,
    issue_state: None,
    issue_labels: &[],
  }
}

#[test]
fn render_prompt_populates_core_issue_fields_and_attempts() {
  let issue = IssueContext {
    issue_id: "id-123",
    issue_identifier: "PROJ-42",
    issue_title: "Login broken",
    issue_description: Some("Users can't log in with Google OAuth"),
    issue_url: Some("https://linear.app/team/PROJ-1"),
    issue_state: Some("In Progress"),
    issue_labels: &[],
  };
  let template = "\
{% if attempt > 1 %}Retry attempt {{ attempt }}. {% endif %}\
Fix issue {{ issue.identifier }}: {{ issue.title }}

{{ issue.description }}
URL: {{ issue.url }} | State: {{ issue.state }}";

  let retry_result = render_prompt(template, &issue, 3).unwrap();
  assert!(retry_result.contains("Retry attempt 3"));
  assert!(retry_result.contains("PROJ-42"));
  assert!(retry_result.contains("Login broken"));
  assert!(retry_result.contains("Google OAuth"));
  assert!(retry_result.contains("https://linear.app/team/PROJ-1"));
  assert!(retry_result.contains("In Progress"));

  let default_result = render_prompt("{{ issue.description }}", &default_issue(), 1).unwrap();
  assert_eq!(default_result.trim(), "");
}
