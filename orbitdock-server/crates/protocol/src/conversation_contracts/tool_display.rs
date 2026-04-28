//! Server-computed display metadata for tool rows.
//!
//! The client renders this struct directly — no tool-specific branching needed.
//! Matches the Swift `ServerToolDisplay` 1:1 for zero-friction decoding.

use serde::{Deserialize, Serialize};

use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};

#[path = "tool_display_classification.rs"]
mod tool_display_classification;
#[path = "tool_display_diff.rs"]
mod tool_display_diff;
#[path = "tool_display_input.rs"]
mod tool_display_input;
#[path = "tool_display_preview.rs"]
mod tool_display_preview;
#[path = "tool_display_shared.rs"]
mod tool_display_shared;

pub use self::tool_display_classification::classify_tool_name;
pub use self::tool_display_diff::{
  compute_diff_display, compute_expanded_output, extract_start_line,
};
pub use self::tool_display_input::{compute_input_display, detect_language};
pub use self::tool_display_preview::{extract_compact_result_text, extract_expanded_result_text};

use self::tool_display_classification::{
  display_name_for_kind, display_tier_string, glyph_for_kind, summary_font_string, tool_type_string,
};
use self::tool_display_diff::compute_diff_preview;
use self::tool_display_input::{compute_right_meta, extract_subtitle_from_input};
use self::tool_display_preview::compute_output_preview;

/// Complete display metadata for a tool card in the conversation timeline.
/// The client reads these fields and renders them verbatim.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolDisplay {
  /// Primary text — tool name or action description.
  pub summary: String,

  /// Secondary text — file path, command, pattern, etc.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub subtitle: Option<String>,

  /// Right-side meta badge — duration, language, line count, etc.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub right_meta: Option<String>,

  /// When true, subtitle already contains the meta info — hide right_meta.
  #[serde(default)]
  pub subtitle_absorbs_meta: bool,

  /// SF Symbol name for the tool glyph.
  pub glyph_symbol: String,

  /// Semantic color name for the glyph (e.g. "toolBash", "toolRead").
  pub glyph_color: String,

  /// Programming language (for read/edit tools — enables syntax badge).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub language: Option<String>,

  /// Diff preview for edit/write tools.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub diff_preview: Option<ToolDiffPreview>,

  /// Static output preview (first lines of tool output).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output_preview: Option<String>,

  /// Live streaming output preview (while tool is running).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub live_output_preview: Option<String>,

  /// Todo items for plan/todo tools.
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub todo_items: Vec<ToolTodoItem>,

  /// Dispatch tag for tool-type-specific cell rendering.
  pub tool_type: String,

  /// Font style for summary text: "system" or "mono".
  #[serde(default = "default_summary_font")]
  pub summary_font: String,

  /// Visual weight tier: "prominent", "standard", "compact", "minimal".
  #[serde(default = "default_display_tier")]
  pub display_tier: String,

  // --- Expanded rendering fields ---
  /// Full tool input for expanded view — pre-formatted, human-readable.
  /// e.g. "$ git status" for bash, file path for read, pattern for grep.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub input_display: Option<String>,

  /// Full tool output for expanded view — pre-formatted, human-readable.
  /// e.g. sanitized stdout, file content, match results.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub output_display: Option<String>,

  /// Structured diff for edit/write tools — expanded view renders this line-by-line.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub diff_display: Option<Vec<DiffLine>>,

  /// Plan explanation/summary for plan tools (EnterPlanMode, UpdatePlan, ExitPlanMode).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub plan_explanation: Option<String>,
}

/// Diff preview for edit/write tool cards.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolDiffPreview {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub context_line: Option<String>,
  pub snippet_text: String,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub preview_lines: Vec<String>,
  pub snippet_prefix: String,
  pub is_addition: bool,
  pub additions: u32,
  pub deletions: u32,
}

/// Todo item status for plan/todo tool cards.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolTodoItem {
  pub status: String,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub content: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub active_form: Option<String>,
}

/// A single line in a structured diff.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiffLine {
  /// Line type: "context", "addition", or "deletion".
  #[serde(rename = "type")]
  pub kind: DiffLineKind,

  /// Line number in the old file (present for deletions and context lines).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub old_line: Option<u32>,

  /// Line number in the new file (present for additions and context lines).
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub new_line: Option<u32>,

  /// Line content (without +/- prefix).
  pub content: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiffLineKind {
  Context,
  Addition,
  Deletion,
}

fn default_summary_font() -> String {
  "system".to_string()
}

fn default_display_tier() -> String {
  "standard".to_string()
}

// ---------------------------------------------------------------------------
// Shared text helpers
// ---------------------------------------------------------------------------

/// Input struct for [`compute_tool_display`].
pub struct ToolDisplayInput<'a> {
  pub kind: ToolKind,
  pub family: ToolFamily,
  pub status: ToolStatus,
  pub title: &'a str,
  pub subtitle: Option<&'a str>,
  pub summary: Option<&'a str>,
  pub duration_ms: Option<u64>,
  pub invocation_input: Option<&'a serde_json::Value>,
  pub result_output: Option<&'a str>,
}

/// Compute a `ToolDisplay` from tool metadata.
///
/// This is the single source of truth for how tools appear in the client.
/// Called when building/updating ToolRows in connectors.
pub fn compute_tool_display(input: ToolDisplayInput<'_>) -> ToolDisplay {
  let ToolDisplayInput {
    kind,
    family,
    status,
    title,
    subtitle,
    summary,
    duration_ms,
    invocation_input,
    result_output,
  } = input;

  let unwrapped =
    invocation_input.and_then(|v| v.get("raw_input").filter(|ri| ri.is_object()).or(Some(v)));
  let invocation_input = unwrapped;

  let (glyph_symbol, glyph_color) = glyph_for_kind(kind, family);
  let tool_type = tool_type_string(kind, family);
  let display_tier = display_tier_string(kind, family, status);
  let summary_font = summary_font_string(kind, family);
  let display_name = display_name_for_kind(kind, family, title);

  let computed_subtitle = subtitle
    .map(String::from)
    .or_else(|| extract_subtitle_from_input(kind, invocation_input));

  let right_meta = compute_right_meta(kind, status, duration_ms, invocation_input, result_output);

  let output_preview = if status == ToolStatus::Completed || status == ToolStatus::Failed {
    compute_output_preview(kind, result_output)
  } else {
    None
  };

  let language = detect_language(kind, invocation_input);
  let diff_preview = compute_diff_preview(kind, invocation_input, result_output);

  let display_summary = summary
    .filter(|s| !s.is_empty())
    .map(String::from)
    .unwrap_or(display_name);

  let input_display = None;
  let output_display = None;
  let diff_display = None;

  let todo_items = tool_display_input::extract_todo_items(kind, invocation_input);
  let plan_explanation = tool_display_input::extract_plan_explanation(kind, invocation_input);

  ToolDisplay {
    summary: display_summary,
    subtitle: computed_subtitle,
    right_meta,
    subtitle_absorbs_meta: false,
    glyph_symbol,
    glyph_color,
    language,
    diff_preview,
    output_preview,
    live_output_preview: None,
    todo_items,
    tool_type,
    summary_font,
    display_tier,
    input_display,
    output_display,
    diff_display,
    plan_explanation,
  }
}

#[cfg(test)]
#[path = "tool_display_tests.rs"]
mod tests;
