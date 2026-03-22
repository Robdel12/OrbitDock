use anyhow::{Context, Result};
use liquid::ParserBuilder;

/// Issue metadata passed to the prompt template renderer.
pub struct IssueContext<'a> {
    pub issue_id: &'a str,
    pub issue_identifier: &'a str,
    pub issue_title: &'a str,
    pub issue_description: Option<&'a str>,
    pub issue_url: Option<&'a str>,
    pub issue_state: Option<&'a str>,
    pub issue_labels: &'a [String],
}

/// Render a Liquid prompt template with issue context.
pub fn render_prompt(
    template_source: &str,
    issue: &IssueContext<'_>,
    attempt: u32,
) -> Result<String> {
    let IssueContext {
        issue_id,
        issue_identifier,
        issue_title,
        issue_description,
        issue_url,
        issue_state,
        issue_labels,
    } = issue;

    let parser = ParserBuilder::with_stdlib()
        .build()
        .context("build Liquid parser")?;
    let template = parser
        .parse(template_source)
        .context("parse Liquid prompt template")?;

    let labels_str = issue_labels.join(", ");

    let globals = liquid::object!({
        "issue": {
            "id": *issue_id,
            "identifier": *issue_identifier,
            "title": *issue_title,
            "description": issue_description.unwrap_or(""),
            "url": issue_url.unwrap_or(""),
            "state": issue_state.unwrap_or(""),
            "labels": labels_str,
        },
        "attempt": attempt,
    });

    let rendered = template
        .render(&globals)
        .context("render prompt template")?;
    Ok(rendered)
}

#[cfg(test)]
mod tests {
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
    fn render_basic_template() {
        let template =
            "Fix issue {{ issue.identifier }}: {{ issue.title }}\n\n{{ issue.description }}";
        let issue = IssueContext {
            issue_id: "id-123",
            issue_identifier: "PROJ-42",
            issue_title: "Login broken",
            issue_description: Some("Users can't log in with Google OAuth"),
            ..default_issue()
        };
        let result = render_prompt(template, &issue, 1).unwrap();

        assert!(result.contains("PROJ-42"));
        assert!(result.contains("Login broken"));
        assert!(result.contains("Google OAuth"));
    }

    #[test]
    fn render_with_attempt() {
        let template = "{% if attempt > 1 %}Retry attempt {{ attempt }}. {% endif %}Fix {{ issue.identifier }}";
        let result = render_prompt(template, &default_issue(), 3).unwrap();
        assert!(result.contains("Retry attempt 3"));
    }

    #[test]
    fn render_empty_description() {
        let template = "{{ issue.description }}";
        let result = render_prompt(template, &default_issue(), 1).unwrap();
        assert_eq!(result.trim(), "");
    }

    #[test]
    fn render_url_and_state() {
        let template = "URL: {{ issue.url }} | State: {{ issue.state }}";
        let issue = IssueContext {
            issue_url: Some("https://linear.app/team/PROJ-1"),
            issue_state: Some("In Progress"),
            ..default_issue()
        };
        let result = render_prompt(template, &issue, 1).unwrap();

        assert!(result.contains("https://linear.app/team/PROJ-1"));
        assert!(result.contains("In Progress"));
    }
}
