use crate::domain_events::ToolKind;

use super::tool_display_shared::truncate;

pub fn extract_compact_result_text(result: Option<&serde_json::Value>) -> Option<String> {
  let result = result?;

  if let Some(summary) = result.get("summary").and_then(|value| value.as_str()) {
    return Some(summary.to_string());
  }
  if let Some(output) = result.get("output").and_then(|value| value.as_str()) {
    return Some(output.to_string());
  }
  if let Some(raw_output) = result.get("raw_output").and_then(|value| value.as_str()) {
    return Some(raw_output.to_string());
  }
  if let Some(text) = result.as_str() {
    return Some(text.to_string());
  }

  serde_json::to_string(result).ok()
}

pub fn extract_expanded_result_text(result: Option<&serde_json::Value>) -> Option<String> {
  let result = result?;

  if let Some(output) = result.get("output").and_then(|value| value.as_str()) {
    return Some(output.to_string());
  }
  if let Some(raw_output) = result.get("raw_output").and_then(|value| value.as_str()) {
    return Some(raw_output.to_string());
  }
  if let Some(text) = result.as_str() {
    return Some(text.to_string());
  }

  serde_json::to_string_pretty(result)
    .or_else(|_| serde_json::to_string(result))
    .ok()
}

pub(super) fn compute_output_preview(
  kind: ToolKind,
  result_output: Option<&str>,
) -> Option<String> {
  let output = result_output?;
  if output.is_empty() {
    return None;
  }

  match kind {
    ToolKind::Bash => {
      let first_meaningful = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .find(|line| {
          let lower = line.trim().to_lowercase();
          !lower.starts_with("(bash completed")
            && !lower.starts_with("bash completed")
            && !lower.starts_with("command completed")
        });
      first_meaningful.map(|line| truncate(line.trim(), 120).to_string())
    }
    ToolKind::Grep | ToolKind::Glob => {
      let lines: Vec<&str> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
      if lines.len() <= 3 {
        Some(lines.join("\n"))
      } else {
        Some(format!(
          "{}\n… and {} more",
          lines[..3].join("\n"),
          lines.len() - 3
        ))
      }
    }
    ToolKind::Read => {
      let lines: Vec<&str> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .take(2)
        .map(|line| {
          super::tool_display_diff::split_line_number(line)
            .map(|(_, content)| content)
            .unwrap_or(line)
        })
        .collect();
      if lines.is_empty() {
        None
      } else {
        Some(truncate(&lines.join("\n"), 200))
      }
    }
    ToolKind::AskUserQuestion => {
      let first = output.lines().find(|line| !line.trim().is_empty())?;
      Some(truncate(first, 120))
    }
    ToolKind::WebSearch => compute_web_search_preview(output),
    ToolKind::ImageGeneration => Some(truncate(output, 160)),
    ToolKind::McpToolCall | ToolKind::DynamicToolCall => compute_structured_preview(output),
    ToolKind::SpawnAgent
    | ToolKind::SendAgentInput
    | ToolKind::WaitAgent
    | ToolKind::CloseAgent
    | ToolKind::ResumeAgent => {
      let lines: Vec<&str> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .filter(|line| !line.trim().to_lowercase().starts_with("status:"))
        .take(3)
        .collect();
      if lines.is_empty() {
        None
      } else {
        Some(lines.join("\n"))
      }
    }
    ToolKind::GuardianAssessment => {
      let parsed = serde_json::from_str::<serde_json::Value>(output).ok()?;
      let rationale = parsed.get("rationale").and_then(|value| value.as_str());
      if let Some(rationale) = rationale {
        return Some(truncate(rationale, 120));
      }
      let score = parsed.get("risk_score").and_then(|value| value.as_u64());
      let level = parsed.get("risk_level").and_then(|value| value.as_str());
      match (level, score) {
        (Some(level), Some(score)) => Some(format!("{level} risk — score {score}/100")),
        (Some(level), None) => Some(format!("{level} risk")),
        (None, Some(score)) => Some(format!("risk score {score}/100")),
        _ => None,
      }
    }
    _ => None,
  }
}

fn compute_web_search_preview(output: &str) -> Option<String> {
  let parsed = serde_json::from_str::<serde_json::Value>(output).ok()?;
  let results = parsed.get("results")?.as_array()?;
  let lines: Vec<String> = results
    .iter()
    .take(3)
    .filter_map(|item| {
      let title = item.get("title").and_then(|value| value.as_str())?;
      Some(truncate(title, 90))
    })
    .collect();

  if lines.is_empty() {
    None
  } else {
    Some(lines.join("\n"))
  }
}

fn compute_structured_preview(output: &str) -> Option<String> {
  let parsed = serde_json::from_str::<serde_json::Value>(output).ok()?;
  match parsed {
    serde_json::Value::Object(map) => {
      let lines: Vec<String> = map
        .iter()
        .take(3)
        .map(|(key, value)| match value {
          serde_json::Value::String(s) => format!("{key}: {}", truncate(s, 80)),
          serde_json::Value::Array(arr) => format!("{key}: [{} items]", arr.len()),
          serde_json::Value::Object(obj) => format!("{key}: {{{} keys}}", obj.len()),
          other => format!("{key}: {}", truncate(&other.to_string(), 80)),
        })
        .collect();
      if lines.is_empty() {
        None
      } else {
        Some(lines.join("\n"))
      }
    }
    serde_json::Value::Array(arr) => {
      let lines: Vec<String> = arr
        .iter()
        .take(3)
        .map(|item| truncate(&item.to_string(), 80))
        .collect();
      if lines.is_empty() {
        None
      } else {
        Some(lines.join("\n"))
      }
    }
    _ => None,
  }
}
