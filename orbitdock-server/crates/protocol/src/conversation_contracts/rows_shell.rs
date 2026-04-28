use serde::{Deserialize, Serialize};

use super::rows_transport::compact_shell_execution_payload;

/// Semantic classification of shell command intent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ShellAction {
  Read {
    command: String,
    name: String,
    path: String,
  },
  ListFiles {
    command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    path: Option<String>,
  },
  Search {
    command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    path: Option<String>,
  },
  Unknown {
    command: String,
  },
}

/// Terminal snapshot for Ghostty rendering.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellTerminalSnapshot {
  /// Normalized command (shell wrapper prefixes stripped).
  pub command: String,
  /// Absolute working directory.
  pub cwd: String,
  /// Normalized terminal output body.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output: Option<String>,
  /// Preformatted ANSI transcript for Ghostty rendering.
  pub transcript: String,
  /// Prompt path/title label (shortened for compact headers).
  pub title: String,
}

impl ShellTerminalSnapshot {
  pub fn transcript(&self) -> &str {
    self.transcript.as_str()
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellPreviewKind {
  Excerpt,
  SearchMatches,
  FileList,
  Diff,
  Status,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShellPreview {
  pub kind: ShellPreviewKind,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub lines: Vec<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub overflow_count: Option<u32>,
}

/// Shell execution payload for ToolRow - provider-agnostic bash/shell rendering.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShellExecutionPayload {
  /// The shell command that was executed.
  pub command: String,
  /// Working directory where the command ran.
  pub cwd: String,
  /// Process ID (if available).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub process_id: Option<String>,
  /// Semantic classification of command intent (read, search, list, etc.).
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub actions: Vec<ShellAction>,
  /// Live output preview (streaming, throttled).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub live_output_preview: Option<String>,
  /// Final aggregated output after completion.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub aggregated_output: Option<String>,
  /// Terminal snapshot for Ghostty rendering.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub terminal_snapshot: Option<ShellTerminalSnapshot>,
  /// Computed preview for collapsed card.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview: Option<ShellPreview>,
  /// Exit code (0 = success).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub exit_code: Option<i32>,
}

impl ShellExecutionPayload {
  pub fn output_text(&self) -> Option<String> {
    self
      .aggregated_output
      .clone()
      .or_else(|| self.live_output_preview.clone())
      .or_else(|| {
        self
          .terminal_snapshot
          .as_ref()
          .and_then(|snapshot| snapshot.output.clone())
      })
      .filter(|value| !value.trim().is_empty())
  }

  pub fn into_transport_summary(mut self) -> Self {
    self.compact_for_transport();
    self
  }

  pub fn compact_for_transport(&mut self) {
    compact_shell_execution_payload(self);
  }
}

fn normalize_terminal_command(command: &str) -> Option<String> {
  let trimmed = command.trim();
  if trimmed.is_empty() {
    return None;
  }

  Some(
    trimmed
      .lines()
      .map(str::trim)
      .filter(|line| !line.is_empty())
      .collect::<Vec<_>>()
      .join(" "),
  )
}

fn normalize_terminal_output(output: Option<&str>) -> Option<String> {
  let output = strip_terminal_stdin_markers(output?);
  (!output.trim().is_empty()).then_some(output)
}

fn strip_terminal_stdin_markers(output: &str) -> String {
  let had_trailing_newline = output.ends_with('\n');
  let cleaned = output
    .lines()
    .filter_map(strip_terminal_stdin_marker_line)
    .collect::<Vec<_>>()
    .join("\n");

  if had_trailing_newline {
    format!("{cleaned}\n")
  } else {
    cleaned
  }
}

fn strip_terminal_stdin_marker_line(line: &str) -> Option<String> {
  let trimmed = line.trim_start();
  if trimmed == "[stdin]" {
    return None;
  }

  Some(match trimmed.strip_prefix("[stdin] ") {
    Some(rest) => {
      let prefix_len = line.len().saturating_sub(trimmed.len());
      format!("{}{}", &line[..prefix_len], rest)
    }
    None => line.to_string(),
  })
}

fn wrap_terminal_command_for_display(command: &str) -> Vec<String> {
  const COMMAND_SOFT_WRAP_THRESHOLD: usize = 120;

  if command.chars().count() <= COMMAND_SOFT_WRAP_THRESHOLD {
    return vec![command.to_string()];
  }

  let words: Vec<String> = command
    .split(' ')
    .filter(|word| !word.is_empty())
    .map(ToString::to_string)
    .collect();
  if words.len() <= 1 {
    return vec![command.to_string()];
  }

  let mut lines = Vec::new();
  let mut current = String::new();

  for word in words {
    if current.is_empty() {
      current = word;
      continue;
    }

    let candidate = format!("{current} {word}");
    if candidate.chars().count() <= COMMAND_SOFT_WRAP_THRESHOLD {
      current = candidate;
    } else {
      lines.push(current);
      current = word;
    }
  }

  if !current.is_empty() {
    lines.push(current);
  }

  if lines.is_empty() {
    vec![command.to_string()]
  } else {
    lines
  }
}

fn terminal_prompt_prefix(cwd: Option<&str>) -> String {
  const ANSI_RESET: &str = "\u{001b}[0m";
  const ANSI_PROMPT_GLYPH: &str = "\u{001b}[38;5;84m";
  const ANSI_PROMPT_PATH: &str = "\u{001b}[38;5;81m";

  let path = normalize_prompt_path(cwd);
  format!("{ANSI_PROMPT_GLYPH}➜{ANSI_RESET} {ANSI_PROMPT_PATH}{path}{ANSI_RESET} $ ")
}

fn normalize_prompt_path(cwd: Option<&str>) -> String {
  let Some(cwd) = cwd else {
    return "~".to_string();
  };

  let trimmed = cwd.trim();
  if trimmed.is_empty() {
    return "~".to_string();
  }

  let with_home_tilde = home_directory_path()
    .and_then(|home| {
      trimmed
        .strip_prefix(&home)
        .map(|suffix| format!("~{suffix}"))
    })
    .unwrap_or_else(|| trimmed.to_string());

  shorten_display_path(with_home_tilde)
}

fn home_directory_path() -> Option<String> {
  std::env::var_os("HOME").and_then(|home| {
    let home = home.to_string_lossy().trim().to_string();
    (!home.is_empty()).then_some(home)
  })
}

fn shorten_display_path(path: String) -> String {
  let components: Vec<&str> = path.split('/').collect();
  if components.len() > 3 {
    format!(
      ".../{}",
      components[components.len().saturating_sub(2)..].join("/")
    )
  } else {
    path
  }
}

fn preview_lines(output: &str) -> Vec<String> {
  output
    .lines()
    .map(str::trim_end)
    .filter(|line| !line.trim().is_empty())
    .map(|line| truncate_preview_line(line, 180))
    .collect()
}

fn truncate_preview_line(line: &str, max_chars: usize) -> String {
  let total_chars = line.chars().count();
  if total_chars <= max_chars {
    return line.to_string();
  }

  let mut truncated = String::with_capacity(max_chars + 1);
  for (index, ch) in line.chars().enumerate() {
    if index >= max_chars.saturating_sub(1) {
      break;
    }
    truncated.push(ch);
  }
  truncated.push('…');
  truncated
}

fn is_diff_preview_line(line: &str) -> bool {
  (line.starts_with('+') && !line.starts_with("+++"))
    || (line.starts_with('-') && !line.starts_with("---"))
}

fn is_file_list_preview_line(line: &str) -> bool {
  let trimmed = line.trim_start();
  trimmed.starts_with("?? ")
    || trimmed.starts_with("M ")
    || trimmed.starts_with("A ")
    || trimmed.starts_with("D ")
    || trimmed.starts_with("R ")
    || trimmed.starts_with("C ")
    || trimmed.starts_with("U ")
}

fn build_status_preview_line(lines: &[String]) -> Option<String> {
  lines.iter().rev().find_map(|line| {
    let lower = line.to_lowercase();
    if lower.contains("built in ")
      || lower.starts_with("finished `")
      || lower.contains("compiled successfully")
      || lower.contains("build completed")
      || lower.contains("test result:")
    {
      Some(line.clone())
    } else {
      None
    }
  })
}

#[derive(Clone, Copy)]
enum PreviewSlice {
  Head,
  Tail,
}

fn shell_preview_from_lines(
  kind: ShellPreviewKind,
  lines: &[String],
  max_lines: usize,
  slice: PreviewSlice,
) -> ShellPreview {
  let selected: Vec<String> = match slice {
    PreviewSlice::Head => lines.iter().take(max_lines).cloned().collect(),
    PreviewSlice::Tail => {
      let start = lines.len().saturating_sub(max_lines);
      lines.iter().skip(start).cloned().collect()
    }
  };

  let overflow_count = lines
    .len()
    .checked_sub(selected.len())
    .and_then(|count| (count > 0).then_some(count as u32));

  ShellPreview {
    kind,
    lines: selected,
    overflow_count,
  }
}

fn supports_shell_diff_preview(actions: &[ShellAction]) -> bool {
  !actions.is_empty()
    && !actions
      .iter()
      .all(|action| matches!(action, ShellAction::Unknown { .. }))
}

pub fn shell_terminal_snapshot(
  command: &str,
  cwd: &str,
  output: Option<&str>,
) -> Option<ShellTerminalSnapshot> {
  let command = normalize_terminal_command(command)?;
  let cwd = cwd.trim();
  if cwd.is_empty() {
    return None;
  }

  let output = normalize_terminal_output(output);
  let transcript =
    shell_terminal_transcript_from_parts(Some(command.clone()), output.clone(), Some(cwd))?;
  let title = normalize_prompt_path(Some(cwd));

  Some(ShellTerminalSnapshot {
    command,
    cwd: cwd.to_string(),
    output,
    transcript,
    title,
  })
}

pub fn shell_terminal_transcript(
  command: Option<&str>,
  output: Option<&str>,
  cwd: Option<&str>,
) -> Option<String> {
  shell_terminal_transcript_from_parts(
    command.and_then(normalize_terminal_command),
    normalize_terminal_output(output),
    cwd,
  )
}

fn shell_terminal_transcript_from_parts(
  normalized_command: Option<String>,
  normalized_output: Option<String>,
  cwd: Option<&str>,
) -> Option<String> {
  if normalized_command.is_none() && normalized_output.is_none() {
    return None;
  }

  let prompt = terminal_prompt_prefix(cwd);
  let mut chunks = Vec::new();
  let has_command = normalized_command.is_some();

  if let Some(command) = normalized_command {
    let wrapped_command_lines = wrap_terminal_command_for_display(&command);
    if let Some(first_line) = wrapped_command_lines.first() {
      chunks.push(format!("{prompt}{first_line}"));
    }
    if wrapped_command_lines.len() > 1 {
      for continuation in wrapped_command_lines.iter().skip(1) {
        chunks.push(format!("  {continuation}"));
      }
    }
  }

  if let Some(output) = normalized_output {
    chunks.push(output);
  }

  if has_command {
    chunks.push(prompt);
  }

  Some(chunks.join("\n"))
}

pub fn compute_shell_preview(
  actions: &[ShellAction],
  output: Option<&str>,
) -> Option<ShellPreview> {
  let lines = preview_lines(output?);
  if lines.is_empty() {
    return None;
  }

  if actions
    .iter()
    .all(|action| matches!(action, ShellAction::Search { .. }))
  {
    return Some(shell_preview_from_lines(
      ShellPreviewKind::SearchMatches,
      &lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if actions
    .iter()
    .all(|action| matches!(action, ShellAction::Read { .. }))
  {
    return Some(shell_preview_from_lines(
      ShellPreviewKind::Excerpt,
      &lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if actions
    .iter()
    .all(|action| matches!(action, ShellAction::ListFiles { .. }))
  {
    return Some(shell_preview_from_lines(
      ShellPreviewKind::FileList,
      &lines,
      2,
      PreviewSlice::Head,
    ));
  }

  let diff_lines: Vec<String> = lines
    .iter()
    .filter(|line| is_diff_preview_line(line))
    .cloned()
    .collect();
  if !diff_lines.is_empty() && supports_shell_diff_preview(actions) {
    return Some(shell_preview_from_lines(
      ShellPreviewKind::Diff,
      &diff_lines,
      2,
      PreviewSlice::Tail,
    ));
  }

  let file_list_lines: Vec<String> = lines
    .iter()
    .filter(|line| is_file_list_preview_line(line))
    .cloned()
    .collect();
  if !file_list_lines.is_empty() {
    return Some(shell_preview_from_lines(
      ShellPreviewKind::FileList,
      &file_list_lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if let Some(status_line) = build_status_preview_line(&lines) {
    return Some(ShellPreview {
      kind: ShellPreviewKind::Status,
      lines: vec![status_line],
      overflow_count: None,
    });
  }

  Some(shell_preview_from_lines(
    ShellPreviewKind::Status,
    &lines,
    1,
    PreviewSlice::Tail,
  ))
}
