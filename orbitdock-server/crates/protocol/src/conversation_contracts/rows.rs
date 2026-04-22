use serde::{Deserialize, Serialize};

use crate::conversation_contracts::activity_groups::{ActivityGroupRow, ActivityGroupRowSummary};
use crate::conversation_contracts::approvals::{ApprovalRow, QuestionRow};
use crate::conversation_contracts::render_hints::RenderHints;
use crate::conversation_contracts::tool_display::{
  compute_tool_display, extract_compact_result_text, ToolDisplay, ToolDisplayInput,
};
use crate::conversation_contracts::tool_payloads::{
  ToolInvocationPayloadContract, ToolPreview, ToolResultPayloadContract,
};
use crate::conversation_contracts::workers::WorkerRow;
use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
use crate::{ImageInput, Provider};

const SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT: usize = 8 * 1024;
const SHELL_TRANSPORT_PREVIEW_LINE_LIMIT: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCitation {
  pub entries: Vec<MemoryCitationEntry>,
  pub rollout_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCitationEntry {
  pub path: String,
  pub line_start: u32,
  pub line_end: u32,
  pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageDeliveryStatus {
  Pending,
  Accepted,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageRowContent {
  pub id: String,
  pub content: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub turn_id: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub timestamp: Option<String>,
  /// True while the row is actively receiving streaming deltas.
  #[serde(default)]
  pub is_streaming: bool,
  /// Image attachments on user messages.
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub images: Vec<ImageInput>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub memory_citation: Option<MemoryCitation>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub delivery_status: Option<MessageDeliveryStatus>,
}

pub type UserRow = MessageRowContent;
pub type AssistantRow = MessageRowContent;
pub type ThinkingRow = MessageRowContent;
pub type SystemRow = MessageRowContent;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookRow {
  pub id: String,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  pub payload: crate::domain_events::HookPayload,
  #[serde(default)]
  pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HandoffRow {
  pub id: String,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  pub payload: crate::domain_events::HandoffPayload,
  #[serde(default)]
  pub render_hints: RenderHints,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanRow {
  pub id: String,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  pub payload: crate::domain_events::PlanModePayload,
  #[serde(default)]
  pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextRowKind {
  AgentInstructions,
  Environment,
  Skill,
  Reminder,
  Personality,
  UserInstructions,
  Generic,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextRow {
  pub id: String,
  pub kind: ContextRowKind,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub body: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub source_path: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub cwd: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub shell: Option<String>,
  #[serde(default)]
  pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeRowKind {
  TurnAborted,
  LocalCommandCaveat,
  Generic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeRowSeverity {
  Info,
  Warning,
  Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NoticeRow {
  pub id: String,
  pub kind: NoticeRowKind,
  pub severity: NoticeRowSeverity,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub body: Option<String>,
  #[serde(default)]
  pub render_hints: RenderHints,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShellCommandRowKind {
  UserShellCommand,
  SlashCommand,
  Bash,
  LocalCommandOutput,
  ShellContext,
  Generic,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShellCommandRow {
  pub id: String,
  pub kind: ShellCommandRowKind,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub command: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub args: Vec<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub stdout: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub stderr: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output_preview: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub exit_code: Option<i32>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub duration_seconds: Option<f64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub cwd: Option<String>,
  #[serde(default)]
  pub render_hints: RenderHints,
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

// ---------------------------------------------------------------------------
// Shell execution payload — provider-agnostic shell/bash execution
// ---------------------------------------------------------------------------

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

/// Shell execution payload for ToolRow — provider-agnostic bash/shell rendering.
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
    if self.live_output_preview.is_none() {
      self.live_output_preview = self
        .aggregated_output
        .as_deref()
        .map(|output| truncate_preview_text(output, SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT));
    } else if let Some(preview) = self.live_output_preview.as_mut() {
      *preview = truncate_preview_text(preview, SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT);
    }

    self.aggregated_output = None;
    self.terminal_snapshot = None;

    if let Some(preview) = self.preview.as_mut() {
      bound_shell_preview_lines(preview, SHELL_TRANSPORT_PREVIEW_LINE_LIMIT);
    }
  }
}

fn truncate_preview_text(value: &str, max_chars: usize) -> String {
  if value.chars().count() <= max_chars {
    return value.to_string();
  }

  let truncated: String = value.chars().take(max_chars).collect();
  format!("{truncated}…")
}

fn bound_shell_preview_lines(preview: &mut ShellPreview, max_lines: usize) {
  if preview.lines.len() <= max_lines {
    return;
  }

  let overflow = preview.lines.len() - max_lines;
  let current_overflow = preview.overflow_count.unwrap_or(0) as usize;
  preview.overflow_count = Some((overflow + current_overflow) as u32);
  preview.lines.truncate(max_lines);
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskRowKind {
  BackgroundCommand,
  Generic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskRowStatus {
  Pending,
  Running,
  Completed,
  Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskRow {
  pub id: String,
  pub kind: TaskRowKind,
  pub status: TaskRowStatus,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub task_id: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub tool_use_id: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output_file: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub result_text: Option<String>,
  #[serde(default)]
  pub render_hints: RenderHints,
}

/// Lifecycle status of a conversation row after undo/rollback operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TurnStatus {
  /// Row is part of the active conversation thread.
  #[default]
  Active,
  /// Row was undone (last-turn undo).
  Undone,
  /// Row was rolled back (multi-turn rollback).
  RolledBack,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationRowEntry {
  pub session_id: String,
  pub sequence: u64,
  /// Turn this row belongs to — lifted so all row types carry it.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub turn_id: Option<String>,
  /// Lifecycle status — active, undone, or rolled back.
  #[serde(default)]
  pub turn_status: TurnStatus,
  pub row: ConversationRow,
}

impl ConversationRowEntry {
  pub fn id(&self) -> &str {
    match &self.row {
      ConversationRow::User(row)
      | ConversationRow::Steer(row)
      | ConversationRow::Assistant(row)
      | ConversationRow::Thinking(row)
      | ConversationRow::System(row) => &row.id,
      ConversationRow::Context(row) => &row.id,
      ConversationRow::Notice(row) => &row.id,
      ConversationRow::ShellCommand(row) => &row.id,
      ConversationRow::Task(row) => &row.id,
      ConversationRow::Plan(row) => &row.id,
      ConversationRow::Hook(row) => &row.id,
      ConversationRow::Handoff(row) => &row.id,
      ConversationRow::Tool(row) => &row.id,
      ConversationRow::ActivityGroup(row) => &row.id,
      ConversationRow::Question(row) => &row.id,
      ConversationRow::Approval(row) => &row.id,
      ConversationRow::Worker(row) => &row.id,
    }
  }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationRowPage {
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub rows: Vec<ConversationRowEntry>,
  pub total_row_count: u64,
  pub has_more_before: bool,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub oldest_sequence: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub newest_sequence: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolRow {
  pub id: String,
  pub provider: Provider,
  pub family: ToolFamily,
  pub kind: ToolKind,
  pub status: ToolStatus,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview: Option<ToolPreview>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub ended_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub duration_ms: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub grouping_key: Option<String>,
  pub invocation: ToolInvocationPayloadContract,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub result: Option<ToolResultPayloadContract>,
  #[serde(default)]
  pub render_hints: RenderHints,
  /// Server-computed display metadata — the client renders this directly.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub tool_display: Option<ToolDisplay>,
  /// Shell execution payload for bash/shell tools — provider-agnostic terminal rendering.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub shell_execution: Option<ShellExecutionPayload>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum ConversationRow {
  User(UserRow),
  Steer(UserRow),
  Assistant(AssistantRow),
  Thinking(ThinkingRow),
  Context(ContextRow),
  Notice(NoticeRow),
  ShellCommand(ShellCommandRow),
  Task(TaskRow),
  Tool(ToolRow),
  ActivityGroup(ActivityGroupRow),
  Question(QuestionRow),
  Approval(ApprovalRow),
  Worker(WorkerRow),
  Plan(PlanRow),
  Hook(HookRow),
  Handoff(HandoffRow),
  System(SystemRow),
}

// ---------------------------------------------------------------------------
// Wire-safe summary types — no raw tool payloads, guaranteed tool_display
// ---------------------------------------------------------------------------

/// Wire-safe tool row for WS events and HTTP timeline responses.
/// Carries all display metadata but never raw invocation/result payloads.
/// `tool_display` is required — the server always computes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolRowSummary {
  pub id: String,
  pub provider: Provider,
  pub family: ToolFamily,
  pub kind: ToolKind,
  pub status: ToolStatus,
  pub title: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub summary: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview: Option<ToolPreview>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub started_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub ended_at: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub duration_ms: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub grouping_key: Option<String>,
  #[serde(default)]
  pub render_hints: RenderHints,
  /// Always present on wire — server computes eagerly.
  pub tool_display: ToolDisplay,
  /// Shell execution payload for bash/shell tools — provider-agnostic terminal rendering.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub shell_execution: Option<ShellExecutionPayload>,
}

impl ToolRow {
  pub fn to_summary(&self) -> ToolRowSummary {
    let display = self.tool_display.clone().unwrap_or_else(|| {
      let result_str = extract_compact_result_text(self.result.as_ref());
      compute_tool_display(ToolDisplayInput {
        kind: self.kind,
        family: self.family,
        status: self.status,
        title: &self.title,
        subtitle: self.subtitle.as_deref(),
        summary: self.summary.as_deref(),
        duration_ms: self.duration_ms,
        invocation_input: Some(&self.invocation),
        result_output: result_str.as_deref(),
      })
    });
    ToolRowSummary {
      id: self.id.clone(),
      provider: self.provider,
      family: self.family,
      kind: self.kind,
      status: self.status,
      title: self.title.clone(),
      subtitle: self.subtitle.clone(),
      summary: self.summary.clone(),
      preview: self.preview.clone(),
      started_at: self.started_at.clone(),
      ended_at: self.ended_at.clone(),
      duration_ms: self.duration_ms,
      grouping_key: self.grouping_key.clone(),
      render_hints: self.render_hints.clone(),
      tool_display: display,
      shell_execution: self.shell_execution.clone(),
    }
  }
}

/// Wire-safe row enum — Tool and ActivityGroup variants use summary types.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum ConversationRowSummary {
  User(UserRow),
  Steer(UserRow),
  Assistant(AssistantRow),
  Thinking(ThinkingRow),
  Context(ContextRow),
  Notice(NoticeRow),
  ShellCommand(ShellCommandRow),
  Task(TaskRow),
  Tool(ToolRowSummary),
  ActivityGroup(ActivityGroupRowSummary),
  Question(QuestionRow),
  Approval(ApprovalRow),
  Worker(WorkerRow),
  Plan(PlanRow),
  Hook(HookRow),
  Handoff(HandoffRow),
  System(SystemRow),
}

impl ConversationRowSummary {
  /// Convert an already-summarized row into transport-safe form.
  /// For Tool rows with shell_execution, drops heavy fields and bounds previews.
  pub fn into_transport_summary(self) -> ConversationRowSummary {
    match self {
      ConversationRowSummary::Tool(mut tool) => {
        if let Some(shell) = tool.shell_execution.as_mut() {
          shell.compact_for_transport();
        }
        ConversationRowSummary::Tool(tool)
      }
      ConversationRowSummary::ActivityGroup(mut group) => {
        for child in &mut group.children {
          if let Some(shell) = child.shell_execution.as_mut() {
            shell.compact_for_transport();
          }
        }
        ConversationRowSummary::ActivityGroup(group)
      }
      other => other,
    }
  }
}

impl ConversationRow {
  pub fn is_steer(&self) -> bool {
    matches!(self, ConversationRow::Steer(_))
  }

  pub fn starts_turn(&self) -> bool {
    matches!(self, ConversationRow::User(_))
  }

  pub fn is_user_input(&self) -> bool {
    matches!(self, ConversationRow::User(_) | ConversationRow::Steer(_))
  }

  /// Convert to wire-safe summary.
  pub fn to_summary(&self) -> ConversationRowSummary {
    match self {
      ConversationRow::User(r) => ConversationRowSummary::User(r.clone()),
      ConversationRow::Steer(r) => ConversationRowSummary::Steer(r.clone()),
      ConversationRow::Assistant(r) => ConversationRowSummary::Assistant(r.clone()),
      ConversationRow::Thinking(r) => ConversationRowSummary::Thinking(r.clone()),
      ConversationRow::System(r) => ConversationRowSummary::System(r.clone()),
      ConversationRow::Context(r) => ConversationRowSummary::Context(r.clone()),
      ConversationRow::Notice(r) => ConversationRowSummary::Notice(r.clone()),
      ConversationRow::ShellCommand(r) => ConversationRowSummary::ShellCommand(r.clone()),
      ConversationRow::Task(r) => ConversationRowSummary::Task(r.clone()),
      ConversationRow::Tool(r) => ConversationRowSummary::Tool(r.to_summary()),
      ConversationRow::ActivityGroup(r) => ConversationRowSummary::ActivityGroup(r.to_summary()),
      ConversationRow::Question(r) => ConversationRowSummary::Question(r.clone()),
      ConversationRow::Approval(r) => ConversationRowSummary::Approval(r.clone()),
      ConversationRow::Worker(r) => ConversationRowSummary::Worker(r.clone()),
      ConversationRow::Plan(r) => ConversationRowSummary::Plan(r.clone()),
      ConversationRow::Hook(r) => ConversationRowSummary::Hook(r.clone()),
      ConversationRow::Handoff(r) => ConversationRowSummary::Handoff(r.clone()),
    }
  }

  /// Convert to transport-safe timeline summary.
  pub fn to_transport_summary(&self) -> ConversationRowSummary {
    self.to_summary().into_transport_summary()
  }
}

/// Wire-safe entry wrapper.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowEntrySummary {
  pub session_id: String,
  pub sequence: u64,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub turn_id: Option<String>,
  /// Lifecycle status — active, undone, or rolled back.
  #[serde(default)]
  pub turn_status: TurnStatus,
  pub row: ConversationRowSummary,
}

impl RowEntrySummary {
  pub fn into_transport_summary(mut self) -> RowEntrySummary {
    self.row = self.row.into_transport_summary();
    self
  }

  pub fn id(&self) -> &str {
    match &self.row {
      ConversationRowSummary::User(row)
      | ConversationRowSummary::Steer(row)
      | ConversationRowSummary::Assistant(row)
      | ConversationRowSummary::Thinking(row)
      | ConversationRowSummary::System(row) => &row.id,
      ConversationRowSummary::Context(row) => &row.id,
      ConversationRowSummary::Notice(row) => &row.id,
      ConversationRowSummary::ShellCommand(row) => &row.id,
      ConversationRowSummary::Task(row) => &row.id,
      ConversationRowSummary::Plan(row) => &row.id,
      ConversationRowSummary::Hook(row) => &row.id,
      ConversationRowSummary::Handoff(row) => &row.id,
      ConversationRowSummary::Tool(row) => &row.id,
      ConversationRowSummary::ActivityGroup(row) => &row.id,
      ConversationRowSummary::Question(row) => &row.id,
      ConversationRowSummary::Approval(row) => &row.id,
      ConversationRowSummary::Worker(row) => &row.id,
    }
  }
}

impl ConversationRowEntry {
  /// Convert to wire-safe summary.
  pub fn to_summary(&self) -> RowEntrySummary {
    RowEntrySummary {
      session_id: self.session_id.clone(),
      sequence: self.sequence,
      turn_id: self.turn_id.clone(),
      turn_status: self.turn_status,
      row: self.row.to_summary(),
    }
  }

  /// Convert to transport-safe timeline summary.
  pub fn to_transport_summary(&self) -> RowEntrySummary {
    RowEntrySummary {
      session_id: self.session_id.clone(),
      sequence: self.sequence,
      turn_id: self.turn_id.clone(),
      turn_status: self.turn_status,
      row: self.row.to_transport_summary(),
    }
  }
}

/// Wire-safe page using summary entries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowPageSummary {
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub rows: Vec<RowEntrySummary>,
  pub total_row_count: u64,
  pub has_more_before: bool,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub oldest_sequence: Option<u64>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub newest_sequence: Option<u64>,
}

/// Extract a human-readable content string from a conversation row.
pub fn extract_row_content_str(row: &ConversationRow) -> String {
  match row {
    ConversationRow::User(m)
    | ConversationRow::Steer(m)
    | ConversationRow::Assistant(m)
    | ConversationRow::Thinking(m)
    | ConversationRow::System(m) => m.content.clone(),
    ConversationRow::Context(c) => c.summary.clone().unwrap_or_else(|| c.title.clone()),
    ConversationRow::Notice(n) => n.summary.clone().unwrap_or_else(|| n.title.clone()),
    ConversationRow::ShellCommand(s) => s
      .summary
      .clone()
      .or_else(|| s.output_preview.clone())
      .or_else(|| s.command.clone())
      .unwrap_or_else(|| s.title.clone()),
    ConversationRow::Task(t) => t.summary.clone().unwrap_or_else(|| t.title.clone()),
    ConversationRow::Tool(t) => t.title.clone(),
    ConversationRow::Plan(p) => p.title.clone(),
    ConversationRow::Hook(h) => h.title.clone(),
    ConversationRow::Handoff(h) => h.title.clone(),
    ConversationRow::Worker(w) => w.title.clone(),
    ConversationRow::Approval(a) => a.id.clone(),
    ConversationRow::Question(q) => q.id.clone(),
    ConversationRow::ActivityGroup(g) => g.title.clone(),
  }
}

/// Extract a human-readable content string from a summary row.
pub fn extract_row_content_str_summary(row: &ConversationRowSummary) -> String {
  match row {
    ConversationRowSummary::User(m)
    | ConversationRowSummary::Steer(m)
    | ConversationRowSummary::Assistant(m)
    | ConversationRowSummary::Thinking(m)
    | ConversationRowSummary::System(m) => m.content.clone(),
    ConversationRowSummary::Context(c) => c.summary.clone().unwrap_or_else(|| c.title.clone()),
    ConversationRowSummary::Notice(n) => n.summary.clone().unwrap_or_else(|| n.title.clone()),
    ConversationRowSummary::ShellCommand(s) => s
      .summary
      .clone()
      .or_else(|| s.output_preview.clone())
      .or_else(|| s.command.clone())
      .unwrap_or_else(|| s.title.clone()),
    ConversationRowSummary::Task(t) => t.summary.clone().unwrap_or_else(|| t.title.clone()),
    ConversationRowSummary::Tool(t) => t.title.clone(),
    ConversationRowSummary::Plan(p) => p.title.clone(),
    ConversationRowSummary::Hook(h) => h.title.clone(),
    ConversationRowSummary::Handoff(h) => h.title.clone(),
    ConversationRowSummary::Worker(w) => w.title.clone(),
    ConversationRowSummary::Approval(a) => a.id.clone(),
    ConversationRowSummary::Question(q) => q.id.clone(),
    ConversationRowSummary::ActivityGroup(g) => g.title.clone(),
  }
}

#[cfg(test)]
mod tests {
  use super::{
    compute_shell_preview, shell_terminal_snapshot, ConversationRow, ConversationRowEntry,
    ConversationRowSummary, MessageRowContent, ShellAction, ShellExecutionPayload,
    ShellPreviewKind, ShellTerminalSnapshot, ToolRow, TurnStatus,
  };
  use crate::conversation_contracts::render_hints::RenderHints;
  use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use crate::{ImageInput, Provider};

  #[test]
  fn message_row_content_round_trips_streaming_images_and_turn_id() {
    let entry = ConversationRowEntry {
      session_id: "sess-1".to_string(),
      sequence: 7,
      turn_id: Some("turn-42".to_string()),
      turn_status: TurnStatus::Active,
      row: ConversationRow::Assistant(MessageRowContent {
        id: "row-1".to_string(),
        content: "Streaming reply".to_string(),
        turn_id: Some("turn-42".to_string()),
        timestamp: Some("2026-03-13T12:00:00Z".to_string()),
        is_streaming: true,
        images: vec![ImageInput {
          input_type: "attachment".to_string(),
          value: "att-1".to_string(),
          mime_type: Some("image/png".to_string()),
          byte_count: None,
          display_name: None,
          pixel_width: None,
          pixel_height: None,
          detail: Some("original".to_string()),
        }],
        memory_citation: None,
        delivery_status: None,
      }),
    };

    let json = serde_json::to_value(&entry).expect("serialize conversation row");
    assert_eq!(
      json.get("turn_id").and_then(|value| value.as_str()),
      Some("turn-42")
    );
    assert_eq!(
      json
        .get("row")
        .and_then(|row| row.get("is_streaming"))
        .and_then(|value| value.as_bool()),
      Some(true)
    );
    assert_eq!(
      json
        .get("row")
        .and_then(|row| row.get("images"))
        .and_then(|value| value.as_array())
        .map(Vec::len),
      Some(1)
    );

    let decoded: ConversationRowEntry =
      serde_json::from_value(json).expect("deserialize conversation row");
    assert_eq!(decoded, entry);
  }

  #[test]
  fn steer_rows_do_not_start_turns() {
    let row = ConversationRow::Steer(MessageRowContent {
      id: "steer-1".to_string(),
      content: "nudge".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: Some(super::MessageDeliveryStatus::Pending),
    });

    assert!(row.is_steer());
    assert!(!row.starts_turn());
  }

  #[test]
  fn flat_invocation_passes_through_unchanged() {
    // Current format: flat JSON, correct kind — should not be affected
    let row = ToolRow {
      id: "toolu_abc".into(),
      provider: Provider::Claude,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Completed,
      title: "Bash".into(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: serde_json::json!({"command": "ls -la"}),
      result: Some(serde_json::json!({"output": "file1\nfile2"})),
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    };

    let summary = row.to_summary();
    assert_eq!(summary.kind, ToolKind::Bash);
    assert_eq!(summary.family, ToolFamily::Shell);
    assert_eq!(summary.tool_display.tool_type, "bash");
  }

  #[test]
  fn summary_fallback_uses_structured_result_output() {
    let row = ToolRow {
      id: "toolu_read".into(),
      provider: Provider::Codex,
      family: ToolFamily::FileRead,
      kind: ToolKind::Read,
      status: ToolStatus::Completed,
      title: "Read".into(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: serde_json::json!({"file_path": "/tmp/example.rs"}),
      result: Some(serde_json::json!({"output": "first line\nsecond line"})),
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    };

    let summary = row.to_summary();
    assert_eq!(summary.tool_display.tool_type, "read");
    assert_eq!(summary.tool_display.right_meta.as_deref(), Some("2 lines"));
    assert_eq!(
      summary.tool_display.output_preview.as_deref(),
      Some("first line\nsecond line")
    );
  }

  #[test]
  fn tool_transport_summary_compacts_shell_execution_payload() {
    let row = ConversationRow::Tool(ToolRow {
      id: "cmd-big".into(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Completed,
      title: "cat big.log".into(),
      subtitle: Some("/tmp/project".into()),
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: Some(11),
      grouping_key: None,
      invocation: serde_json::json!({"command": "cat big.log", "cwd": "/tmp/project"}),
      result: None,
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: Some(ShellExecutionPayload {
        command: "cat big.log".into(),
        cwd: "/tmp/project".into(),
        process_id: None,
        actions: vec![ShellAction::Unknown {
          command: "cat big.log".into(),
        }],
        live_output_preview: None,
        aggregated_output: Some("x".repeat(20_000)),
        terminal_snapshot: Some(ShellTerminalSnapshot {
          command: "cat big.log".into(),
          cwd: "/tmp/project".into(),
          output: Some("x".repeat(20_000)),
          transcript: "x".repeat(20_000),
          title: "/tmp/project".into(),
        }),
        preview: None,
        exit_code: Some(0),
      }),
    });

    let ConversationRowSummary::Tool(summary) = row.to_transport_summary() else {
      panic!("expected tool summary");
    };
    let shell = summary.shell_execution.expect("shell execution summary");
    assert!(shell.aggregated_output.is_none());
    assert!(shell.terminal_snapshot.is_none());
    assert!(
      shell
        .live_output_preview
        .as_deref()
        .expect("preview")
        .chars()
        .count()
        <= super::SHELL_TRANSPORT_PREVIEW_CHAR_LIMIT + 1
    );
  }

  #[test]
  fn shell_execution_payload_serializes_with_snake_case_wire_keys() {
    let payload = ShellExecutionPayload {
      command: "npm test".into(),
      cwd: "/tmp/project".into(),
      process_id: Some("pty-1".into()),
      actions: vec![ShellAction::Unknown {
        command: "npm test".into(),
      }],
      live_output_preview: Some("running".into()),
      aggregated_output: Some("done".into()),
      terminal_snapshot: None,
      preview: Some(super::ShellPreview {
        kind: ShellPreviewKind::Status,
        lines: vec!["done".into()],
        overflow_count: Some(1),
      }),
      exit_code: Some(0),
    };

    let value = serde_json::to_value(payload).expect("shell payload json");

    assert_eq!(value["process_id"], "pty-1");
    assert_eq!(value["live_output_preview"], "running");
    assert_eq!(value["aggregated_output"], "done");
    assert_eq!(value["preview"]["overflow_count"], 1);
    assert_eq!(value["exit_code"], 0);
    assert!(value.get("processId").is_none());
    assert!(value.get("liveOutputPreview").is_none());
    assert!(value.get("aggregatedOutput").is_none());
    assert!(value.get("exitCode").is_none());
  }

  #[test]
  fn shell_terminal_snapshot_renders_shell_like_transcript() {
    let snapshot =
      shell_terminal_snapshot("swiftc -print-target-info", "/tmp/project", Some("done\n"))
        .expect("terminal snapshot");

    assert_eq!(snapshot.command, "swiftc -print-target-info");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(snapshot.output.as_deref(), Some("done\n"));
    let transcript = snapshot.transcript();
    assert!(transcript.contains("➜"));
    assert!(transcript.contains("swiftc -print-target-info"));
    assert!(transcript.contains("done"));
    assert!(transcript.ends_with("$ "));
    assert_eq!(snapshot.title, "/tmp/project");
  }

  #[test]
  fn shell_terminal_snapshot_strips_legacy_stdin_markers() {
    let snapshot = shell_terminal_snapshot(
      "python -i",
      "/tmp/project",
      Some("[stdin] print('hello')\n[stdin]\ndone\n"),
    )
    .expect("terminal snapshot");

    assert_eq!(snapshot.output.as_deref(), Some("print('hello')\ndone\n"));
    assert!(!snapshot.transcript().contains("[stdin]"));
    assert!(snapshot.transcript().contains("print('hello')"));
  }

  #[test]
  fn shell_preview_prefers_build_status_line() {
    let preview = compute_shell_preview(
      &[ShellAction::Unknown {
        command: "npm run build".to_string(),
      }],
      Some("dist/assets/index.js 123 kB\nbuilt in 228ms\n"),
    )
    .expect("preview");

    assert_eq!(preview.kind, ShellPreviewKind::Status);
    assert_eq!(preview.lines, vec!["built in 228ms".to_string()]);
    assert_eq!(preview.overflow_count, None);
  }

  #[test]
  fn shell_preview_collapses_file_list() {
    let preview = compute_shell_preview(
      &[ShellAction::Unknown {
        command: "git status --short".to_string(),
      }],
      Some(
        "?? web/command-execution-expanded.jsx\n?? web/command-execution-row.jsx\n?? web/command-execution-row.module.css\n",
      ),
    )
    .expect("preview");

    assert_eq!(preview.kind, ShellPreviewKind::FileList);
    assert_eq!(preview.lines.len(), 2);
    assert_eq!(preview.overflow_count, Some(1));
  }
}
