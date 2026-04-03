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
  FellBackToNewTurn,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandExecutionStatus {
  InProgress,
  Completed,
  Failed,
  Declined,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandExecutionTerminalSnapshot {
  /// Normalized command (shell wrapper prefixes stripped by connector mapping).
  pub command: String,
  /// Absolute working directory used for prompt/title rendering.
  pub cwd: String,
  /// Normalized terminal output body (without forced trailing newline).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output: Option<String>,
  /// Preformatted ANSI transcript for non-interactive terminal rendering.
  pub transcript: String,
  /// Prompt path/title label (already shortened for compact headers).
  pub title: String,
}

impl CommandExecutionTerminalSnapshot {
  pub fn transcript(&self) -> &str {
    self.transcript.as_str()
  }
}

pub fn command_execution_terminal_snapshot(
  command: &str,
  cwd: &str,
  output: Option<&str>,
) -> Option<CommandExecutionTerminalSnapshot> {
  let command = normalize_terminal_command(command)?;
  let cwd = cwd.trim();
  if cwd.is_empty() {
    return None;
  }

  let output = normalize_terminal_output(output);
  let transcript =
    command_execution_terminal_transcript(Some(command.as_str()), output.as_deref(), Some(cwd))?;
  let title = normalize_prompt_path(Some(cwd));

  Some(CommandExecutionTerminalSnapshot {
    command,
    cwd: cwd.to_string(),
    output,
    transcript,
    title,
  })
}

pub fn command_execution_terminal_transcript(
  command: Option<&str>,
  output: Option<&str>,
  cwd: Option<&str>,
) -> Option<String> {
  let normalized_command = command.and_then(normalize_terminal_command);
  let normalized_output = normalize_terminal_output(output);

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
  let output = output?;
  if output.trim().is_empty() {
    return None;
  }

  Some(output.trim_matches('\n').to_string())
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CommandExecutionAction {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandExecutionPreviewKind {
  Excerpt,
  SearchMatches,
  FileList,
  Diff,
  Status,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandExecutionPreview {
  pub kind: CommandExecutionPreviewKind,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub lines: Vec<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub overflow_count: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommandExecutionRow {
  pub id: String,
  pub status: CommandExecutionStatus,
  pub command: String,
  pub cwd: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub process_id: Option<String>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub command_actions: Vec<CommandExecutionAction>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub live_output_preview: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub aggregated_output: Option<String>,
  /// Canonical terminal snapshot for expanded shell rendering.
  /// Typed fields (`command`, `cwd`, `output`) stay authoritative; `transcript`
  /// and `title` are derived presentation fields.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub terminal_snapshot: Option<CommandExecutionTerminalSnapshot>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub preview: Option<CommandExecutionPreview>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub exit_code: Option<i32>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub duration_ms: Option<u64>,
  #[serde(default)]
  pub render_hints: RenderHints,
}

pub fn compute_command_execution_preview(
  actions: &[CommandExecutionAction],
  output: Option<&str>,
) -> Option<CommandExecutionPreview> {
  let lines = preview_lines(output?);
  if lines.is_empty() {
    return None;
  }

  if actions
    .iter()
    .all(|action| matches!(action, CommandExecutionAction::Search { .. }))
  {
    return Some(preview_from_lines(
      CommandExecutionPreviewKind::SearchMatches,
      &lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if actions
    .iter()
    .all(|action| matches!(action, CommandExecutionAction::Read { .. }))
  {
    return Some(preview_from_lines(
      CommandExecutionPreviewKind::Excerpt,
      &lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if actions
    .iter()
    .all(|action| matches!(action, CommandExecutionAction::ListFiles { .. }))
  {
    return Some(preview_from_lines(
      CommandExecutionPreviewKind::FileList,
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
  if !diff_lines.is_empty() && supports_diff_preview(actions) {
    return Some(preview_from_lines(
      CommandExecutionPreviewKind::Diff,
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
    return Some(preview_from_lines(
      CommandExecutionPreviewKind::FileList,
      &file_list_lines,
      2,
      PreviewSlice::Head,
    ));
  }

  if let Some(status_line) = build_status_preview_line(&lines) {
    return Some(CommandExecutionPreview {
      kind: CommandExecutionPreviewKind::Status,
      lines: vec![status_line],
      overflow_count: None,
    });
  }

  Some(preview_from_lines(
    CommandExecutionPreviewKind::Status,
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

fn preview_from_lines(
  kind: CommandExecutionPreviewKind,
  lines: &[String],
  max_lines: usize,
  slice: PreviewSlice,
) -> CommandExecutionPreview {
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

  CommandExecutionPreview {
    kind,
    lines: selected,
    overflow_count,
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

fn supports_diff_preview(actions: &[CommandExecutionAction]) -> bool {
  !actions.is_empty()
    && !actions
      .iter()
      .all(|action| matches!(action, CommandExecutionAction::Unknown { .. }))
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
      ConversationRow::CommandExecution(row) => &row.id,
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
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
pub enum ConversationRow {
  User(UserRow),
  Steer(UserRow),
  Assistant(AssistantRow),
  Thinking(ThinkingRow),
  Context(ContextRow),
  Notice(NoticeRow),
  ShellCommand(ShellCommandRow),
  CommandExecution(CommandExecutionRow),
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
    }
  }
}

/// Wire-safe row enum — Tool and ActivityGroup variants use summary types.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "row_type", rename_all = "snake_case")]
pub enum ConversationRowSummary {
  User(UserRow),
  Steer(UserRow),
  Assistant(AssistantRow),
  Thinking(ThinkingRow),
  Context(ContextRow),
  Notice(NoticeRow),
  ShellCommand(ShellCommandRow),
  CommandExecution(CommandExecutionRow),
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

const MAX_INLINE_PREVIEW_CHARACTERS: usize = 8_192;
const MAX_COMMAND_PREVIEW_LINES: usize = 6;
const MAX_PREVIEW_LINE_CHARACTERS: usize = 220;

fn clipped_text(value: Option<&str>, max_characters: usize) -> Option<String> {
  let value = value?;
  if value.trim().is_empty() {
    return None;
  }
  if value.chars().count() <= max_characters {
    return Some(value.to_string());
  }
  let clipped: String = value.chars().take(max_characters).collect();
  Some(format!("{clipped}..."))
}

fn bounded_command_preview(
  preview: Option<&CommandExecutionPreview>,
) -> Option<CommandExecutionPreview> {
  let preview = preview?;
  let original_line_count = preview.lines.len();
  let lines: Vec<String> = preview
    .lines
    .iter()
    .take(MAX_COMMAND_PREVIEW_LINES)
    .map(|line| {
      let trimmed = line.trim();
      if trimmed.chars().count() > MAX_PREVIEW_LINE_CHARACTERS {
        let clipped: String = trimmed.chars().take(MAX_PREVIEW_LINE_CHARACTERS).collect();
        format!("{clipped}...")
      } else {
        trimmed.to_string()
      }
    })
    .filter(|line| !line.is_empty())
    .collect();

  let dropped_line_count = original_line_count.saturating_sub(lines.len());
  let overflow_count = if dropped_line_count > 0 {
    Some(
      preview
        .overflow_count
        .unwrap_or(0)
        .saturating_add(dropped_line_count.min(u32::MAX as usize) as u32),
    )
  } else {
    preview.overflow_count
  };

  Some(CommandExecutionPreview {
    kind: preview.kind,
    lines,
    overflow_count,
  })
}

fn transport_command_execution_row(row: &CommandExecutionRow) -> CommandExecutionRow {
  CommandExecutionRow {
    id: row.id.clone(),
    status: row.status,
    command: row.command.clone(),
    cwd: row.cwd.clone(),
    process_id: row.process_id.clone(),
    command_actions: row.command_actions.clone(),
    live_output_preview: clipped_text(
      row
        .live_output_preview
        .as_deref()
        .or(row.aggregated_output.as_deref()),
      MAX_INLINE_PREVIEW_CHARACTERS,
    ),
    aggregated_output: None,
    terminal_snapshot: None,
    preview: bounded_command_preview(row.preview.as_ref()),
    exit_code: row.exit_code,
    duration_ms: row.duration_ms,
    render_hints: row.render_hints.clone(),
  }
}

impl ConversationRowSummary {
  /// Convert an already-summarized row into transport-safe form.
  pub fn into_transport_summary(self) -> ConversationRowSummary {
    match self {
      ConversationRowSummary::CommandExecution(row) => {
        ConversationRowSummary::CommandExecution(transport_command_execution_row(&row))
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
      ConversationRow::CommandExecution(r) => ConversationRowSummary::CommandExecution(r.clone()),
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
  /// Heavy command execution fields are omitted; expanded content is fetched via HTTP.
  pub fn to_transport_summary(&self) -> ConversationRowSummary {
    match self {
      ConversationRow::CommandExecution(row) => {
        ConversationRowSummary::CommandExecution(transport_command_execution_row(row))
      }
      _ => self.to_summary(),
    }
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
      ConversationRowSummary::CommandExecution(row) => &row.id,
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
    ConversationRow::CommandExecution(c) => c
      .aggregated_output
      .clone()
      .or_else(|| c.live_output_preview.clone())
      .unwrap_or_else(|| c.command.clone()),
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
    ConversationRowSummary::CommandExecution(c) => c
      .aggregated_output
      .clone()
      .or_else(|| c.live_output_preview.clone())
      .unwrap_or_else(|| c.command.clone()),
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
    command_execution_terminal_snapshot, compute_command_execution_preview,
    extract_row_content_str, CommandExecutionAction, CommandExecutionPreviewKind,
    CommandExecutionRow, CommandExecutionStatus, CommandExecutionTerminalSnapshot, ConversationRow,
    ConversationRowEntry, ConversationRowSummary, MessageRowContent, ToolRow, TurnStatus,
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
  fn command_execution_content_prefers_aggregated_output() {
    let row = ConversationRow::CommandExecution(CommandExecutionRow {
      id: "cmd-1".to_string(),
      status: CommandExecutionStatus::Completed,
      command: "cat Cargo.toml".to_string(),
      cwd: "/tmp/project".to_string(),
      process_id: Some("pty-1".to_string()),
      command_actions: vec![CommandExecutionAction::Read {
        command: "cat Cargo.toml".to_string(),
        name: "Cargo.toml".to_string(),
        path: "Cargo.toml".to_string(),
      }],
      live_output_preview: Some("preview".to_string()),
      aggregated_output: Some("[package]".to_string()),
      terminal_snapshot: Some(CommandExecutionTerminalSnapshot {
        command: "cat Cargo.toml".to_string(),
        cwd: "/tmp/project".to_string(),
        output: Some("[package]".to_string()),
        transcript: "➜ /tmp/project $ cat Cargo.toml\n[package]\n➜ /tmp/project $ ".to_string(),
        title: "/tmp/project".to_string(),
      }),
      preview: None,
      exit_code: Some(0),
      duration_ms: Some(12),
      render_hints: RenderHints::default(),
    });

    assert_eq!(extract_row_content_str(&row), "[package]");
  }

  #[test]
  fn command_execution_terminal_snapshot_renders_shell_like_transcript() {
    let snapshot = command_execution_terminal_snapshot(
      "swiftc -print-target-info",
      "/tmp/project",
      Some("done\n"),
    )
    .expect("terminal snapshot");

    assert_eq!(snapshot.command, "swiftc -print-target-info");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(snapshot.output.as_deref(), Some("done"));
    let transcript = snapshot.transcript();
    assert!(transcript.contains("➜"));
    assert!(transcript.contains("swiftc -print-target-info"));
    assert!(transcript.contains("done"));
    assert!(transcript.ends_with("$ "));
    assert_eq!(snapshot.title, "/tmp/project");
  }

  #[test]
  fn command_execution_row_deserializes_without_terminal_snapshot() {
    let json = serde_json::json!({
      "row_type": "command_execution",
      "id": "cmd-legacy",
      "status": "completed",
      "command": "echo hi",
      "cwd": "/tmp/project",
      "process_id": null,
      "command_actions": [],
      "live_output_preview": null,
      "aggregated_output": "hi\n",
      "preview": null,
      "exit_code": 0,
      "duration_ms": 4,
      "render_hints": {
        "can_expand": false,
        "default_expanded": false,
        "emphasized": false,
        "monospace_summary": false,
        "accent_tone": null
      }
    });

    let row: ConversationRow = serde_json::from_value(json).expect("command execution row");
    let ConversationRow::CommandExecution(row) = row else {
      panic!("expected command execution row");
    };

    assert!(row.terminal_snapshot.is_none());
  }

  #[test]
  fn command_execution_preview_prefers_build_status_line() {
    let preview = compute_command_execution_preview(
      &[CommandExecutionAction::Unknown {
        command: "npm run build".to_string(),
      }],
      Some("dist/assets/index.js 123 kB\nbuilt in 228ms\n"),
    )
    .expect("preview");

    assert_eq!(preview.kind, CommandExecutionPreviewKind::Status);
    assert_eq!(preview.lines, vec!["built in 228ms".to_string()]);
    assert_eq!(preview.overflow_count, None);
  }

  #[test]
  fn command_execution_preview_collapses_file_list() {
    let preview = compute_command_execution_preview(
      &[CommandExecutionAction::Unknown {
        command: "git status --short".to_string(),
      }],
      Some(
        "?? orbitdock-web/src/components/conversation/command-execution-expanded.jsx\n?? orbitdock-web/src/components/conversation/command-execution-row.jsx\n?? orbitdock-web/src/components/conversation/command-execution-row.module.css\n",
      ),
    )
    .expect("preview");

    assert_eq!(preview.kind, CommandExecutionPreviewKind::FileList);
    assert_eq!(preview.lines.len(), 2);
    assert_eq!(preview.overflow_count, Some(1));
  }

  #[test]
  fn command_execution_preview_does_not_mark_generic_shell_as_diff() {
    let preview = compute_command_execution_preview(
      &[CommandExecutionAction::Unknown {
        command: "git diff".to_string(),
      }],
      Some("+++ b/src/main.rs\n--- a/src/main.rs\n+let value = 42;\n-let value = 7;\n"),
    )
    .expect("preview");

    assert_eq!(preview.kind, CommandExecutionPreviewKind::Status);
    assert_eq!(preview.lines, vec!["-let value = 7;".to_string()]);
  }

  #[test]
  fn command_execution_transport_summary_omits_heavy_fields() {
    let row = ConversationRow::CommandExecution(CommandExecutionRow {
      id: "cmd-transport".to_string(),
      status: CommandExecutionStatus::Completed,
      command: "cat big.log".to_string(),
      cwd: "/tmp/project".to_string(),
      process_id: Some("pty-1".to_string()),
      command_actions: vec![],
      live_output_preview: None,
      aggregated_output: Some("x".repeat(20_000)),
      terminal_snapshot: Some(CommandExecutionTerminalSnapshot {
        command: "cat big.log".to_string(),
        cwd: "/tmp/project".to_string(),
        output: Some("payload".to_string()),
        transcript: "payload".to_string(),
        title: "/tmp/project".to_string(),
      }),
      preview: Some(super::CommandExecutionPreview {
        kind: CommandExecutionPreviewKind::Status,
        lines: vec![
          "line 1".to_string(),
          "line 2".to_string(),
          "line 3".to_string(),
          "line 4".to_string(),
          "line 5".to_string(),
          "line 6".to_string(),
          "line 7".to_string(),
        ],
        overflow_count: None,
      }),
      exit_code: Some(0),
      duration_ms: Some(7),
      render_hints: RenderHints::default(),
    });

    let summary = row.to_transport_summary();
    let ConversationRowSummary::CommandExecution(summary) = summary else {
      panic!("expected command execution summary");
    };
    assert!(summary.aggregated_output.is_none());
    assert!(summary.terminal_snapshot.is_none());
    assert!(summary.live_output_preview.is_some());
    assert!(
      summary
        .live_output_preview
        .unwrap_or_default()
        .chars()
        .count()
        <= 8_195
    );
    assert_eq!(summary.preview.as_ref().map(|p| p.lines.len()), Some(6));
  }

  #[test]
  fn row_entry_transport_summary_uses_transport_row_shape() {
    let entry = ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence: 42,
      turn_id: Some("turn-1".to_string()),
      turn_status: TurnStatus::Active,
      row: ConversationRow::CommandExecution(CommandExecutionRow {
        id: "cmd-entry".to_string(),
        status: CommandExecutionStatus::Completed,
        command: "echo hi".to_string(),
        cwd: "/tmp/project".to_string(),
        process_id: None,
        command_actions: vec![],
        live_output_preview: Some("preview".to_string()),
        aggregated_output: Some("full".to_string()),
        terminal_snapshot: Some(CommandExecutionTerminalSnapshot {
          command: "echo hi".to_string(),
          cwd: "/tmp/project".to_string(),
          output: Some("full".to_string()),
          transcript: "full".to_string(),
          title: "/tmp/project".to_string(),
        }),
        preview: None,
        exit_code: Some(0),
        duration_ms: Some(1),
        render_hints: RenderHints::default(),
      }),
    };

    let summary = entry.to_transport_summary();
    let ConversationRowSummary::CommandExecution(summary) = summary.row else {
      panic!("expected command execution summary");
    };
    assert!(summary.aggregated_output.is_none());
    assert!(summary.terminal_snapshot.is_none());
    assert_eq!(summary.live_output_preview.as_deref(), Some("preview"));
  }
}
