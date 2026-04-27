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
#[path = "prompt_tests.rs"]
mod tests;
