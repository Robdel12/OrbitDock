use anyhow::{Context, Result};
use liquid::ParserBuilder;

/// Render a Liquid prompt template with issue context.
pub fn render_prompt(
    template_source: &str,
    issue_id: &str,
    issue_identifier: &str,
    issue_title: &str,
    issue_description: Option<&str>,
    attempt: u32,
) -> Result<String> {
    let parser = ParserBuilder::with_stdlib()
        .build()
        .context("build Liquid parser")?;
    let template = parser
        .parse(template_source)
        .context("parse Liquid prompt template")?;

    let globals = liquid::object!({
        "issue": {
            "id": issue_id,
            "identifier": issue_identifier,
            "title": issue_title,
            "description": issue_description.unwrap_or(""),
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

    #[test]
    fn render_basic_template() {
        let template =
            "Fix issue {{ issue.identifier }}: {{ issue.title }}\n\n{{ issue.description }}";
        let result = render_prompt(
            template,
            "id-123",
            "PROJ-42",
            "Login broken",
            Some("Users can't log in with Google OAuth"),
            1,
        )
        .unwrap();

        assert!(result.contains("PROJ-42"));
        assert!(result.contains("Login broken"));
        assert!(result.contains("Google OAuth"));
    }

    #[test]
    fn render_with_attempt() {
        let template = "{% if attempt > 1 %}Retry attempt {{ attempt }}. {% endif %}Fix {{ issue.identifier }}";
        let result = render_prompt(template, "id-1", "PROJ-1", "Bug", None, 3).unwrap();
        assert!(result.contains("Retry attempt 3"));
    }

    #[test]
    fn render_empty_description() {
        let template = "{{ issue.description }}";
        let result = render_prompt(template, "id-1", "PROJ-1", "Bug", None, 1).unwrap();
        assert_eq!(result.trim(), "");
    }
}
