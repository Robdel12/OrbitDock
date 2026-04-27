use serde_json::Value;

use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::{
  classify_tool_name, compute_shell_preview, compute_tool_display, shell_terminal_snapshot,
  ConversationRow, ConversationRowEntry, ShellAction, ShellExecutionPayload, ToolDisplayInput,
  ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};

/// Classify a raw tool name from the Claude CLI into (ToolFamily, ToolKind).
///
/// Delegates to the shared `classify_tool_name` in orbitdock_protocol, with
/// additional Claude-specific aliases (MultiEdit, FileRead, etc.).
fn classify_tool(name: &str) -> (ToolFamily, ToolKind) {
  match name {
    "FileEdit" | "MultiEdit" => return (ToolFamily::FileChange, ToolKind::Edit),
    "FileRead" => return (ToolFamily::FileRead, ToolKind::Read),
    "FileWrite" => return (ToolFamily::FileChange, ToolKind::Write),
    "SendMessage" => return (ToolFamily::Agent, ToolKind::SendAgentInput),
    "TaskCreate" | "TaskUpdate" | "TaskList" | "TaskGet" => {
      return (ToolFamily::Todo, ToolKind::TodoWrite)
    }
    "TaskOutput" => return (ToolFamily::Agent, ToolKind::TaskOutput),
    "TaskStop" => return (ToolFamily::Agent, ToolKind::TaskStop),
    "Skill" => return (ToolFamily::Mcp, ToolKind::McpToolCall),
    "ReadMcpResourceTool" => return (ToolFamily::Mcp, ToolKind::ReadMcpResource),
    "ListMcpResourcesTool" => return (ToolFamily::Mcp, ToolKind::ListMcpResources),
    _ => {}
  }
  classify_tool_name(name)
}

/// Build a flat JSON invocation value from a tool name and optional raw JSON input.
/// For Claude tools, the raw_input IS the flat invocation (e.g. {"command": "ls"}).
fn build_invocation(tool_name: &str, raw_input: Option<&Value>) -> Value {
  match raw_input {
    Some(input) if input.is_object() => input.clone(),
    Some(input) => serde_json::json!({ "tool_name": tool_name, "input": input }),
    None => serde_json::json!({ "tool_name": tool_name }),
  }
}

/// Build a tool title from the tool name (human-friendly).
fn tool_title(tool_name: &str) -> String {
  tool_name.to_string()
}

/// Extract a subtitle from the tool input based on tool kind.
fn extract_subtitle(tool_name: &str, raw_input: Option<&Value>) -> Option<String> {
  let input = raw_input?;
  let result = match tool_name {
    "Bash" | "bash" => {
      let cmd = input.get("command").and_then(Value::as_str).unwrap_or("");
      if cmd.is_empty() {
        return input
          .get("description")
          .and_then(Value::as_str)
          .map(String::from);
      }
      let truncated = if cmd.len() > 120 {
        format!("{}…", &cmd[..120])
      } else {
        cmd.to_string()
      };
      Some(truncated)
    }
    "Read" | "read" | "FileRead" | "Edit" | "edit" | "FileEdit" | "MultiEdit" | "Write"
    | "write" | "FileWrite" | "NotebookEdit" => input
      .get("file_path")
      .and_then(Value::as_str)
      .map(String::from),
    "Glob" | "glob" | "Grep" | "grep" => input
      .get("pattern")
      .and_then(Value::as_str)
      .map(String::from),
    "WebSearch" | "websearch" => input.get("query").and_then(Value::as_str).map(String::from),
    "WebFetch" | "webfetch" => input.get("url").and_then(Value::as_str).map(String::from),
    "Agent" | "agent" => {
      let desc = input.get("description").and_then(Value::as_str);
      let agent_type = input.get("subagent_type").and_then(Value::as_str);
      match (agent_type, desc) {
        (Some(t), Some(d)) => Some(format!("{t} — {d}")),
        (Some(t), None) => Some(t.to_string()),
        (None, Some(d)) => Some(d.to_string()),
        _ => None,
      }
    }
    n if n.starts_with("mcp__") => {
      let parts: Vec<&str> = n
        .strip_prefix("mcp__")
        .unwrap_or(n)
        .splitn(2, "__")
        .collect();
      match parts.as_slice() {
        [server, tool] => Some(format!("{server} · {tool}")),
        _ => None,
      }
    }
    _ => None,
  };
  result.filter(|s| !s.trim().is_empty())
}

/// Compute a summary from tool result output.
pub(crate) fn extract_result_summary(tool_name: &str, output: &str) -> Option<String> {
  if output.is_empty() {
    return None;
  }
  let summary = match tool_name {
    "Bash" | "bash" => {
      let first_line = output.lines().next().unwrap_or("");
      if first_line.len() > 200 {
        format!("{}…", &first_line[..200])
      } else {
        first_line.to_string()
      }
    }
    "Read" | "read" | "FileRead" => format!("{} lines", output.lines().count()),
    "Edit" | "edit" | "FileEdit" | "MultiEdit" => {
      let has_diff = output.contains("@@") || output.contains("+") || output.contains("-");
      if has_diff {
        let additions = output.lines().filter(|line| line.starts_with('+')).count();
        let deletions = output.lines().filter(|line| line.starts_with('-')).count();
        format!("+{additions} -{deletions}")
      } else {
        "Applied".to_string()
      }
    }
    "Write" | "write" | "FileWrite" => "Created file".to_string(),
    "Glob" | "glob" => {
      let count = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count();
      format!("{count} files matched")
    }
    "Grep" | "grep" => {
      let non_empty: Vec<&str> = output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
      let file_count = non_empty
        .iter()
        .filter_map(|line| line.split(':').next())
        .collect::<std::collections::HashSet<_>>()
        .len();
      format!("{} matches in {} files", non_empty.len(), file_count)
    }
    _ => {
      let first_line = output.lines().next().unwrap_or("");
      if first_line.starts_with('[') || first_line.starts_with('{') {
        return None;
      }
      if first_line.len() > 200 {
        format!("{}…", &first_line[..200])
      } else {
        first_line.to_string()
      }
    }
  };

  if summary.trim().is_empty() {
    None
  } else {
    Some(summary)
  }
}

fn shell_command_from_tool_row(row: &ToolRow) -> String {
  row
    .invocation
    .get("command")
    .and_then(Value::as_str)
    .or_else(|| row.invocation.get("cmd").and_then(Value::as_str))
    .or(row.subtitle.as_deref())
    .unwrap_or(row.title.as_str())
    .trim()
    .to_string()
}

fn shell_execution_payload(
  command: String,
  cwd: String,
  actions: Vec<ShellAction>,
  output: Option<String>,
  status: ToolStatus,
) -> ShellExecutionPayload {
  let live_output_preview = matches!(status, ToolStatus::Running)
    .then(|| output.clone())
    .flatten();
  let aggregated_output = matches!(
    status,
    ToolStatus::Completed | ToolStatus::Failed | ToolStatus::Cancelled
  )
  .then(|| output.clone())
  .flatten();
  let terminal_output = aggregated_output
    .as_deref()
    .or(live_output_preview.as_deref());
  let preview = compute_shell_preview(&actions, terminal_output);
  let terminal_snapshot = shell_terminal_snapshot(&command, &cwd, terminal_output);

  ShellExecutionPayload {
    command,
    cwd,
    process_id: None,
    actions,
    live_output_preview,
    aggregated_output,
    terminal_snapshot,
    preview,
    exit_code: None,
  }
}

pub(crate) fn refresh_shell_execution(row: &mut ToolRow, cwd: &str, output: Option<&str>) {
  if row.kind != ToolKind::Bash {
    return;
  }

  let command = shell_command_from_tool_row(row);
  let output = output
    .map(str::to_string)
    .filter(|value| !value.trim().is_empty());
  let actions = vec![ShellAction::Unknown {
    command: command.clone(),
  }];
  row.shell_execution = Some(shell_execution_payload(
    command,
    cwd.to_string(),
    actions,
    output,
    row.status,
  ));
}

fn tool_render_hints(kind: ToolKind) -> RenderHints {
  match kind {
    ToolKind::Bash => RenderHints {
      can_expand: true,
      monospace_summary: true,
      ..Default::default()
    },
    ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => RenderHints {
      can_expand: true,
      ..Default::default()
    },
    ToolKind::Grep | ToolKind::Glob => RenderHints {
      can_expand: true,
      ..Default::default()
    },
    _ => RenderHints::default(),
  }
}

/// Construct a ToolRow for a newly-created tool use.
pub(crate) fn make_tool_row(
  id: String,
  tool_name: &str,
  raw_input: Option<&Value>,
  status: ToolStatus,
) -> ToolRow {
  let (family, kind) = classify_tool(tool_name);
  let subtitle = extract_subtitle(tool_name, raw_input);
  let render_hints = tool_render_hints(kind);
  let tool_display = Some(compute_tool_display(ToolDisplayInput {
    kind,
    family,
    status,
    title: tool_name,
    subtitle: subtitle.as_deref(),
    summary: None,
    duration_ms: None,
    invocation_input: raw_input,
    result_output: None,
  }));

  ToolRow {
    id,
    provider: orbitdock_protocol::Provider::Claude,
    family,
    kind,
    status,
    title: tool_title(tool_name),
    subtitle,
    summary: None,
    preview: None,
    started_at: Some(now_iso()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: build_invocation(tool_name, raw_input),
    result: None,
    render_hints,
    tool_display,
    shell_execution: None,
  }
}

/// Wrap a ConversationRow in a ConversationRowEntry.
pub(crate) fn make_entry(session_id: &str, row: ConversationRow) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row,
  }
}

pub(crate) fn now_iso() -> String {
  use std::time::{SystemTime, UNIX_EPOCH};

  let ms = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default()
    .as_millis();
  format!("{}.{:03}Z", ms / 1000, ms % 1000)
}

/// Parse an epoch-based timestamp ("1234567890Z" or "1234567890.123Z") to epoch milliseconds.
pub(crate) fn parse_epoch_ms(s: &str) -> Option<u64> {
  let stripped = s.strip_suffix('Z')?;
  if let Some((secs_str, ms_str)) = stripped.split_once('.') {
    let secs: u64 = secs_str.parse().ok()?;
    let ms: u64 = ms_str.parse().ok()?;
    Some(secs * 1000 + ms)
  } else {
    let secs: u64 = stripped.parse().ok()?;
    Some(secs * 1000)
  }
}
