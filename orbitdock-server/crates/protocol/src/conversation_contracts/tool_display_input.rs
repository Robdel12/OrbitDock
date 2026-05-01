use crate::domain_events::{ToolKind, ToolStatus};

use super::tool_display_shared::truncate;
use super::ToolTodoItem;

pub fn detect_language(kind: ToolKind, input: Option<&serde_json::Value>) -> Option<String> {
  if !matches!(
    kind,
    ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
  ) {
    return None;
  }
  let path = input?
    .get("file_path")
    .or_else(|| input?.get("path"))
    .and_then(|value| value.as_str())?;
  let ext = path.rsplit('.').next()?;
  let language = match ext {
    "swift" => "Swift",
    "rs" => "Rust",
    "ts" | "tsx" => "TypeScript",
    "js" | "jsx" => "JavaScript",
    "py" => "Python",
    "rb" => "Ruby",
    "go" => "Go",
    "java" => "Java",
    "kt" | "kts" => "Kotlin",
    "c" | "h" => "C",
    "cpp" | "cc" | "cxx" | "hpp" => "C++",
    "cs" => "C#",
    "html" | "htm" => "HTML",
    "css" | "scss" | "sass" | "less" => "CSS",
    "json" => "JSON",
    "yaml" | "yml" => "YAML",
    "toml" => "TOML",
    "xml" => "XML",
    "sql" => "SQL",
    "sh" | "bash" | "zsh" => "Shell",
    "md" | "markdown" => "Markdown",
    "dockerfile" | "Dockerfile" => "Docker",
    _ => return None,
  };
  Some(language.to_string())
}

pub(super) fn extract_subtitle_from_input(
  kind: ToolKind,
  input: Option<&serde_json::Value>,
) -> Option<String> {
  let input = input?;
  let result = match kind {
    ToolKind::Bash => {
      let command = input
        .get("command")
        .and_then(|value| value.as_str())
        .unwrap_or("");
      if command.is_empty() {
        return input
          .get("description")
          .and_then(|value| value.as_str())
          .map(String::from);
      }
      Some(truncate(command, 120))
    }
    ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => {
      file_name_from_input(input)
    }
    ToolKind::Glob | ToolKind::Grep => input
      .get("pattern")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::WebSearch => input
      .get("query")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::WebFetch => input
      .get("url")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::SpawnAgent => {
      let description = input.get("description").and_then(|value| value.as_str());
      let agent_type = input.get("subagent_type").and_then(|value| value.as_str());
      match (agent_type, description) {
        (Some(agent_type), Some(description)) if !description.is_empty() => {
          Some(format!("{agent_type} — {description}"))
        }
        (Some(agent_type), _) => Some(agent_type.to_string()),
        (_, Some(description)) if !description.is_empty() => Some(description.to_string()),
        _ => None,
      }
    }
    ToolKind::McpToolCall | ToolKind::DynamicToolCall => input
      .get("server")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::ViewImage | ToolKind::ImageGeneration => file_name_from_input(input).or_else(|| {
      input
        .get("image_paths")
        .and_then(|value| value.as_array())
        .and_then(|array| array.first())
        .and_then(|value| value.as_str())
        .and_then(|path| path.rsplit('/').next())
        .map(String::from)
    }),
    ToolKind::Config => input
      .get("key")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::ToolSearch => input
      .get("query")
      .and_then(|value| value.as_str())
      .map(|query| truncate(query, 80)),
    ToolKind::AskUserQuestion => input
      .get("prompt")
      .or_else(|| input.get("question"))
      .and_then(|value| value.as_str())
      .map(|question| truncate(question, 120)),
    ToolKind::GuardianAssessment => {
      let action = input.get("action");
      let command = action
        .and_then(|action| action.get("command"))
        .and_then(|value| value.as_str());
      if let Some(command) = command {
        Some(truncate(command, 120))
      } else {
        action
          .and_then(|action| serde_json::to_string_pretty(action).ok())
          .map(|json| truncate(&json, 120))
      }
    }
    _ => None,
  };
  result.filter(|value| !value.trim().is_empty())
}

fn file_name_from_input(input: &serde_json::Value) -> Option<String> {
  let path = input
    .get("file_path")
    .or_else(|| input.get("path"))
    .and_then(|value| value.as_str())?;
  path.rsplit('/').next().map(String::from)
}

pub(super) fn compute_right_meta(
  kind: ToolKind,
  status: ToolStatus,
  duration_ms: Option<u64>,
  input: Option<&serde_json::Value>,
  result_output: Option<&str>,
) -> Option<String> {
  if let Some(ms) = duration_ms {
    if status == ToolStatus::Completed || status == ToolStatus::Failed {
      return Some(format_duration(ms));
    }
  }

  if status == ToolStatus::Running {
    return Some("LIVE".to_string());
  }

  if kind == ToolKind::Read {
    if let Some(output) = result_output {
      return Some(format!("{} lines", output.lines().count()));
    }
  }

  if kind == ToolKind::Grep || kind == ToolKind::Glob {
    if let Some(output) = result_output {
      let count = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count();
      return Some(format!("{count} results"));
    }
  }

  _ = input;
  None
}

fn format_duration(ms: u64) -> String {
  if ms < 1000 {
    format!("{ms}ms")
  } else {
    let seconds = ms as f64 / 1000.0;
    if seconds < 10.0 {
      format!("{seconds:.1}s")
    } else {
      format!("{seconds:.0}s")
    }
  }
}

pub fn compute_input_display(kind: ToolKind, input: Option<&serde_json::Value>) -> Option<String> {
  let input = input?;
  match kind {
    ToolKind::Bash => {
      let command = input
        .get("command")
        .and_then(|value| value.as_str())
        .unwrap_or("");
      if command.is_empty() {
        None
      } else {
        Some(format!("$ {command}"))
      }
    }
    ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => input
      .get("file_path")
      .or_else(|| input.get("path"))
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::ViewImage => input
      .get("file_path")
      .or_else(|| input.get("path"))
      .and_then(|value| value.as_str())
      .or_else(|| {
        input
          .get("image_paths")
          .and_then(|value| value.as_array())
          .and_then(|array| array.first())
          .and_then(|value| value.as_str())
      })
      .map(String::from),
    ToolKind::ImageGeneration => input
      .get("prompt")
      .and_then(|value| value.as_str())
      .or_else(|| input.get("revised_prompt").and_then(|value| value.as_str()))
      .or_else(|| {
        input
          .get("image_paths")
          .and_then(|value| value.as_array())
          .and_then(|array| array.first())
          .and_then(|value| value.as_str())
      })
      .map(String::from),
    ToolKind::Glob | ToolKind::Grep => input
      .get("pattern")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::WebSearch => input
      .get("query")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::WebFetch => input
      .get("url")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::SpawnAgent => {
      let description = input.get("description").and_then(|value| value.as_str());
      let prompt = input.get("prompt").and_then(|value| value.as_str());
      let agent_type = input.get("subagent_type").and_then(|value| value.as_str());
      let label = description.or(prompt).unwrap_or("");
      match agent_type {
        Some(agent_type) if !label.is_empty() => Some(format!("{agent_type} — {label}")),
        Some(agent_type) => Some(agent_type.to_string()),
        None if !label.is_empty() => Some(label.to_string()),
        _ => None,
      }
    }
    ToolKind::ToolSearch => input
      .get("query")
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::ExitPlanMode => None,
    ToolKind::EnterPlanMode | ToolKind::UpdatePlan => input
      .get("plan")
      .and_then(|value| value.as_str())
      .or_else(|| input.get("explanation").and_then(|value| value.as_str()))
      .map(String::from),
    ToolKind::TodoWrite => None,
    ToolKind::AskUserQuestion => input
      .get("prompt")
      .or_else(|| input.get("question"))
      .and_then(|value| value.as_str())
      .map(String::from),
    ToolKind::GuardianAssessment => {
      let action = input.get("action");
      let command = action
        .and_then(|action| action.get("command"))
        .and_then(|value| value.as_str());
      if let Some(command) = command {
        Some(format!("$ {command}"))
      } else {
        action.and_then(|action| serde_json::to_string_pretty(action).ok())
      }
    }
    ToolKind::McpToolCall | ToolKind::DynamicToolCall => serde_json::to_string_pretty(input).ok(),
    _ => {
      if input.is_object() && input.as_object().is_none_or(|object| object.is_empty()) {
        None
      } else {
        serde_json::to_string_pretty(input).ok()
      }
    }
  }
}

pub(super) fn extract_todo_items(
  kind: ToolKind,
  input: Option<&serde_json::Value>,
) -> Vec<ToolTodoItem> {
  let input = match input {
    Some(value) => value,
    None => return vec![],
  };

  if matches!(
    kind,
    ToolKind::EnterPlanMode | ToolKind::UpdatePlan | ToolKind::ExitPlanMode
  ) {
    if let Some(steps) = input.get("plan").and_then(|value| value.as_array()) {
      return steps
        .iter()
        .map(|item| {
          let raw_status = item
            .get("status")
            .and_then(|value| value.as_str())
            .unwrap_or("pending");
          let status = match raw_status {
            "inProgress" => "in_progress",
            other => other,
          }
          .to_string();

          let content = item
            .get("step")
            .or_else(|| item.get("title"))
            .or_else(|| item.get("content"))
            .and_then(|value| value.as_str())
            .map(|content| truncate(content, 200));

          let active_form = item
            .get("activeForm")
            .and_then(|value| value.as_str())
            .map(|active_form| truncate(active_form, 200));

          ToolTodoItem {
            status,
            content,
            active_form,
          }
        })
        .collect();
    }
    return vec![];
  }

  if kind != ToolKind::TodoWrite {
    return vec![];
  }

  let items = match input
    .get("tasks")
    .or_else(|| input.get("todos"))
    .and_then(|value| value.as_array())
  {
    Some(items) => items,
    None => return vec![],
  };

  items
    .iter()
    .map(|item| {
      let status = item
        .get("status")
        .and_then(|value| value.as_str())
        .unwrap_or("pending")
        .to_string();
      let content = item
        .get("content")
        .and_then(|value| value.as_str())
        .map(|content| truncate(content, 200));
      let active_form = item
        .get("activeForm")
        .and_then(|value| value.as_str())
        .map(|active_form| truncate(active_form, 200));
      ToolTodoItem {
        status,
        content,
        active_form,
      }
    })
    .collect()
}

pub(super) fn extract_plan_explanation(
  kind: ToolKind,
  input: Option<&serde_json::Value>,
) -> Option<String> {
  if !matches!(
    kind,
    ToolKind::EnterPlanMode | ToolKind::UpdatePlan | ToolKind::ExitPlanMode
  ) {
    return None;
  }

  let input = input?;

  if let Some(explanation) = input.get("explanation").and_then(|value| value.as_str()) {
    if !explanation.is_empty() {
      return Some(truncate(explanation, 500));
    }
  }
  if let Some(summary) = input.get("summary").and_then(|value| value.as_str()) {
    if !summary.is_empty() {
      return Some(truncate(summary, 500));
    }
  }
  None
}
