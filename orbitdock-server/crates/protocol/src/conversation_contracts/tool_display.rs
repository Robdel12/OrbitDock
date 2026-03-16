//! Server-computed display metadata for tool rows.
//!
//! The client renders this struct directly — no tool-specific branching needed.
//! Matches the Swift `ServerToolDisplay` 1:1 for zero-friction decoding.

use serde::{Deserialize, Serialize};

use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};

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
}

/// Diff preview for edit/write tool cards.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolDiffPreview {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_line: Option<String>,
    pub snippet_text: String,
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
// Safe string truncation (never panics on multi-byte UTF-8)
// ---------------------------------------------------------------------------

/// Truncate a string to at most `max_chars` characters, appending "…" if truncated.
/// Safe for any UTF-8 content — never slices at byte boundaries.
fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let t: String = s.chars().take(max_chars).collect();
    format!("{t}…")
}

// ---------------------------------------------------------------------------
// Display computation
// ---------------------------------------------------------------------------

/// Compute a `ToolDisplay` from tool metadata.
///
/// This is the single source of truth for how tools appear in the client.
/// Called when building/updating ToolRows in connectors.
#[allow(clippy::too_many_arguments)]
pub fn compute_tool_display(
    kind: ToolKind,
    family: ToolFamily,
    status: ToolStatus,
    title: &str,
    subtitle: Option<&str>,
    summary: Option<&str>,
    duration_ms: Option<u64>,
    invocation_input: Option<&serde_json::Value>,
    result_output: Option<&str>,
) -> ToolDisplay {
    // Unwrap the raw_input wrapper if present — hook data wraps input as
    // {"raw_input": {"command": "..."}, "tool_name": "Bash"} but extract
    // functions expect the flat {"command": "..."} shape.
    let unwrapped =
        invocation_input.and_then(|v| v.get("raw_input").filter(|ri| ri.is_object()).or(Some(v)));
    let invocation_input = unwrapped;

    let (glyph_symbol, glyph_color) = glyph_for_kind(kind, family);
    let tool_type = tool_type_string(kind, family);
    let display_tier = display_tier_string(kind, family, status);
    let summary_font = summary_font_string(kind, family);

    let display_name = display_name_for_kind(kind, title);

    // Build subtitle from invocation input if not already provided
    let computed_subtitle = subtitle
        .map(String::from)
        .or_else(|| extract_subtitle_from_input(kind, invocation_input));

    // Build right-side meta
    let right_meta = compute_right_meta(kind, status, duration_ms, invocation_input, result_output);

    // Build output preview from result
    let output_preview = if status == ToolStatus::Completed || status == ToolStatus::Failed {
        compute_output_preview(kind, result_output)
    } else {
        None
    };

    // Detect language for file tools
    let language = detect_language(kind, invocation_input);

    // Build diff preview for edit tools
    let diff_preview = compute_diff_preview(kind, invocation_input, result_output);

    // Use provided summary, or compute one
    let display_summary = summary
        .filter(|s| !s.is_empty())
        .map(String::from)
        .unwrap_or(display_name);

    // --- Expanded rendering fields (fetched on demand via REST) ---
    let input_display = None;
    let output_display = None;
    let diff_display = None;

    // Extract todo items from invocation input
    let todo_items = extract_todo_items(kind, invocation_input);

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
    }
}

// ---------------------------------------------------------------------------
// Glyph mapping
// ---------------------------------------------------------------------------

fn glyph_for_kind(kind: ToolKind, family: ToolFamily) -> (String, String) {
    match kind {
        ToolKind::Bash => ("terminal".into(), "toolBash".into()),
        ToolKind::Read => ("doc.plaintext".into(), "toolRead".into()),
        ToolKind::Edit => ("pencil.line".into(), "toolWrite".into()),
        ToolKind::Write => ("pencil.line".into(), "toolWrite".into()),
        ToolKind::NotebookEdit => ("pencil.line".into(), "toolWrite".into()),
        ToolKind::Glob | ToolKind::Grep | ToolKind::ToolSearch => {
            ("magnifyingglass".into(), "toolSearch".into())
        }
        ToolKind::WebSearch => ("globe".into(), "toolWeb".into()),
        ToolKind::WebFetch => ("globe".into(), "toolWeb".into()),
        ToolKind::McpToolCall
        | ToolKind::ReadMcpResource
        | ToolKind::ListMcpResources
        | ToolKind::DynamicToolCall => ("puzzlepiece.extension".into(), "toolMcp".into()),
        ToolKind::SpawnAgent
        | ToolKind::SendAgentInput
        | ToolKind::ResumeAgent
        | ToolKind::WaitAgent
        | ToolKind::CloseAgent => ("bolt.fill".into(), "toolTask".into()),
        ToolKind::AskUserQuestion => ("questionmark.bubble".into(), "toolQuestion".into()),
        ToolKind::EnterPlanMode | ToolKind::ExitPlanMode | ToolKind::UpdatePlan => {
            ("map".into(), "toolPlan".into())
        }
        ToolKind::TodoWrite | ToolKind::TaskOutput | ToolKind::TaskStop => {
            ("checklist".into(), "toolTodo".into())
        }
        ToolKind::CompactContext => ("arrow.triangle.2.circlepath".into(), "accent".into()),
        ToolKind::ViewImage | ToolKind::ImageGeneration => ("photo".into(), "toolRead".into()),
        ToolKind::HookNotification => ("bolt.badge.clock".into(), "feedbackCaution".into()),
        ToolKind::HandoffRequested => ("arrow.triangle.branch".into(), "statusReply".into()),
        _ => match family {
            ToolFamily::Shell => ("terminal".into(), "toolBash".into()),
            ToolFamily::FileRead => ("doc.plaintext".into(), "toolRead".into()),
            ToolFamily::FileChange => ("pencil.line".into(), "toolWrite".into()),
            ToolFamily::Search => ("magnifyingglass".into(), "toolSearch".into()),
            ToolFamily::Web => ("globe".into(), "toolWeb".into()),
            ToolFamily::Agent => ("bolt.fill".into(), "toolTask".into()),
            ToolFamily::Mcp => ("puzzlepiece.extension".into(), "toolMcp".into()),
            ToolFamily::Hook => ("bolt.badge.clock".into(), "feedbackCaution".into()),
            _ => ("gearshape".into(), "secondaryLabel".into()),
        },
    }
}

// ---------------------------------------------------------------------------
// Display name
// ---------------------------------------------------------------------------

fn display_name_for_kind(kind: ToolKind, title: &str) -> String {
    match kind {
        ToolKind::Bash => "Bash".into(),
        ToolKind::Read => "Read".into(),
        ToolKind::Edit => "Edit".into(),
        ToolKind::Write => "Write".into(),
        ToolKind::NotebookEdit => "Notebook Edit".into(),
        ToolKind::Glob => "Glob".into(),
        ToolKind::Grep => "Grep".into(),
        ToolKind::ToolSearch => "Tool Search".into(),
        ToolKind::WebSearch => "Web Search".into(),
        ToolKind::WebFetch => "Web Fetch".into(),
        ToolKind::McpToolCall | ToolKind::DynamicToolCall => {
            if title.is_empty() {
                "MCP Tool".into()
            } else {
                title.to_string()
            }
        }
        ToolKind::SpawnAgent => "Agent".into(),
        ToolKind::AskUserQuestion => "Question".into(),
        ToolKind::EnterPlanMode => "Plan Mode".into(),
        ToolKind::ExitPlanMode => "Exit Plan".into(),
        ToolKind::TodoWrite => "Todo".into(),
        ToolKind::CompactContext => "Compacting Context".into(),
        ToolKind::ViewImage => "View Image".into(),
        ToolKind::HookNotification => "Hook".into(),
        ToolKind::HandoffRequested => "Handoff".into(),
        _ => {
            if title.is_empty() {
                "Tool".into()
            } else {
                title.to_string()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tool type string (dispatch tag for cell rendering)
// ---------------------------------------------------------------------------

fn tool_type_string(kind: ToolKind, _family: ToolFamily) -> String {
    match kind {
        ToolKind::Bash => "bash",
        ToolKind::Read => "read",
        ToolKind::Edit | ToolKind::NotebookEdit => "edit",
        ToolKind::Write => "write",
        ToolKind::Glob => "glob",
        ToolKind::Grep => "grep",
        ToolKind::SpawnAgent
        | ToolKind::SendAgentInput
        | ToolKind::ResumeAgent
        | ToolKind::WaitAgent
        | ToolKind::CloseAgent => "task",
        ToolKind::McpToolCall | ToolKind::DynamicToolCall => "mcp",
        ToolKind::ReadMcpResource | ToolKind::ListMcpResources => "mcp",
        ToolKind::WebSearch | ToolKind::WebFetch => "web",
        ToolKind::EnterPlanMode | ToolKind::ExitPlanMode | ToolKind::UpdatePlan => "plan",
        ToolKind::TodoWrite => "todo",
        ToolKind::AskUserQuestion => "question",
        ToolKind::ToolSearch => "toolSearch",
        ToolKind::HookNotification => "hook",
        ToolKind::HandoffRequested => "handoff",
        ToolKind::ViewImage | ToolKind::ImageGeneration => "image",
        ToolKind::CompactContext => "compactContext",
        ToolKind::Config => "config",
        ToolKind::EnterWorktree => "worktree",
        _ => "generic",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Display tier
// ---------------------------------------------------------------------------

fn display_tier_string(kind: ToolKind, _family: ToolFamily, _status: ToolStatus) -> String {
    match kind {
        // Prominent: demands attention
        ToolKind::AskUserQuestion => "prominent",
        // Standard: full card with detail
        ToolKind::Bash | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => "standard",
        ToolKind::SpawnAgent | ToolKind::HandoffRequested => "standard",
        ToolKind::McpToolCall | ToolKind::DynamicToolCall => "standard",
        ToolKind::WebSearch | ToolKind::WebFetch => "standard",
        // Compact: inline, muted
        ToolKind::Read | ToolKind::Glob | ToolKind::Grep | ToolKind::ToolSearch => "compact",
        // Minimal: nearly invisible
        ToolKind::EnterPlanMode
        | ToolKind::ExitPlanMode
        | ToolKind::UpdatePlan
        | ToolKind::TodoWrite
        | ToolKind::CompactContext
        | ToolKind::HookNotification => "minimal",
        _ => "standard",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Summary font
// ---------------------------------------------------------------------------

fn summary_font_string(kind: ToolKind, family: ToolFamily) -> String {
    match kind {
        ToolKind::Bash => "mono",
        _ => match family {
            ToolFamily::Shell => "mono",
            _ => "system",
        },
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Subtitle extraction from tool input
// ---------------------------------------------------------------------------

fn extract_subtitle_from_input(
    kind: ToolKind,
    input: Option<&serde_json::Value>,
) -> Option<String> {
    let input = input?;
    let result = match kind {
        ToolKind::Bash => {
            let cmd = input.get("command").and_then(|v| v.as_str()).unwrap_or("");
            if cmd.is_empty() {
                return input
                    .get("description")
                    .and_then(|v| v.as_str())
                    .map(String::from);
            }
            let truncated = truncate(cmd, 120);
            Some(truncated)
        }
        ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => {
            file_name_from_input(input)
        }
        ToolKind::Glob | ToolKind::Grep => input
            .get("pattern")
            .and_then(|v| v.as_str())
            .map(String::from),
        ToolKind::WebSearch => input
            .get("query")
            .and_then(|v| v.as_str())
            .map(String::from),
        ToolKind::WebFetch => input.get("url").and_then(|v| v.as_str()).map(String::from),
        ToolKind::SpawnAgent => {
            let desc = input.get("description").and_then(|v| v.as_str());
            let agent_type = input.get("subagent_type").and_then(|v| v.as_str());
            match (agent_type, desc) {
                (Some(t), Some(d)) if !d.is_empty() => Some(format!("{t} — {d}")),
                (Some(t), _) => Some(t.to_string()),
                (_, Some(d)) if !d.is_empty() => Some(d.to_string()),
                _ => None,
            }
        }
        ToolKind::McpToolCall | ToolKind::DynamicToolCall => {
            // For MCP tools, the server name is in the invocation
            input
                .get("server")
                .and_then(|v| v.as_str())
                .map(String::from)
        }
        ToolKind::ViewImage => file_name_from_input(input),
        ToolKind::Config => input.get("key").and_then(|v| v.as_str()).map(String::from),
        _ => None,
    };
    result.filter(|s| !s.trim().is_empty())
}

fn file_name_from_input(input: &serde_json::Value) -> Option<String> {
    let path = input.get("file_path").and_then(|v| v.as_str())?;
    // Extract just the filename
    path.rsplit('/').next().map(String::from)
}

// ---------------------------------------------------------------------------
// Right meta computation
// ---------------------------------------------------------------------------

fn compute_right_meta(
    kind: ToolKind,
    status: ToolStatus,
    duration_ms: Option<u64>,
    input: Option<&serde_json::Value>,
    result_output: Option<&str>,
) -> Option<String> {
    // Duration as primary meta for completed tools
    if let Some(ms) = duration_ms {
        if status == ToolStatus::Completed || status == ToolStatus::Failed {
            return Some(format_duration(ms));
        }
    }

    // Running status
    if status == ToolStatus::Running {
        return Some("LIVE".to_string());
    }

    // Line count for read tools
    if kind == ToolKind::Read {
        if let Some(output) = result_output {
            let line_count = output.lines().count();
            return Some(format!("{line_count} lines"));
        }
    }

    // Match count for search tools
    if kind == ToolKind::Grep || kind == ToolKind::Glob {
        if let Some(output) = result_output {
            let count = output.lines().filter(|l| !l.trim().is_empty()).count();
            return Some(format!("{count} results"));
        }
    }

    _ = input; // suppress unused warning
    None
}

fn format_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{}ms", ms)
    } else {
        let s = ms as f64 / 1000.0;
        if s < 10.0 {
            format!("{:.1}s", s)
        } else {
            format!("{:.0}s", s)
        }
    }
}

// ---------------------------------------------------------------------------
// Output preview
// ---------------------------------------------------------------------------

fn compute_output_preview(kind: ToolKind, result_output: Option<&str>) -> Option<String> {
    let output = result_output?;
    if output.is_empty() {
        return None;
    }

    match kind {
        // Shell: single meaningful output line, skip noise
        ToolKind::Bash => {
            let first_meaningful = output.lines().filter(|l| !l.trim().is_empty()).find(|l| {
                let lower = l.trim().to_lowercase();
                // Skip status messages that add no value in preview
                !lower.starts_with("(bash completed")
                    && !lower.starts_with("bash completed")
                    && !lower.starts_with("command completed")
            });
            first_meaningful.map(|l| truncate(l.trim(), 120).to_string())
        }
        // Search: summary line
        ToolKind::Grep | ToolKind::Glob => {
            let lines: Vec<&str> = output.lines().filter(|l| !l.trim().is_empty()).collect();
            if lines.len() <= 3 {
                Some(lines.join("\n"))
            } else {
                let first_three = lines[..3].join("\n");
                Some(format!("{}\n… and {} more", first_three, lines.len() - 3))
            }
        }
        // Read: first 2 non-empty lines, with line number prefixes stripped
        ToolKind::Read => {
            let lines: Vec<&str> = output
                .lines()
                .filter(|l| !l.trim().is_empty())
                .take(2)
                .map(|l| {
                    split_line_number(l)
                        .map(|(_, content)| content)
                        .unwrap_or(l)
                })
                .collect();
            if lines.is_empty() {
                None
            } else {
                Some(truncate(&lines.join("\n"), 200))
            }
        }
        // Question: first line of the question prompt
        ToolKind::AskUserQuestion => {
            let first = output.lines().find(|l| !l.trim().is_empty())?;
            Some(truncate(first, 120))
        }
        // Most tools: no preview in compact mode
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

pub fn detect_language(kind: ToolKind, input: Option<&serde_json::Value>) -> Option<String> {
    if !matches!(
        kind,
        ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
    ) {
        return None;
    }
    let path = input?.get("file_path").and_then(|v| v.as_str())?;
    let ext = path.rsplit('.').next()?;
    let lang = match ext {
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
    Some(lang.to_string())
}

// ---------------------------------------------------------------------------
// Diff preview
// ---------------------------------------------------------------------------

fn compute_diff_preview(
    kind: ToolKind,
    input: Option<&serde_json::Value>,
    _result_output: Option<&str>,
) -> Option<ToolDiffPreview> {
    if !matches!(
        kind,
        ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
    ) {
        return None;
    }
    let input = input?;

    let old_string = input.get("old_string").and_then(|v| v.as_str());
    let new_string = input.get("new_string").and_then(|v| v.as_str());

    match (old_string, new_string) {
        (Some(old), Some(new)) => {
            let additions = new.lines().count() as u32;
            let deletions = old.lines().count() as u32;
            let is_addition = deletions == 0;
            let snippet = if is_addition {
                new.lines().next().unwrap_or("").to_string()
            } else {
                old.lines().next().unwrap_or("").to_string()
            };
            let prefix = if is_addition { "+" } else { "-" };
            Some(ToolDiffPreview {
                context_line: None,
                snippet_text: truncate(&snippet, 80),
                snippet_prefix: prefix.to_string(),
                is_addition,
                additions,
                deletions,
            })
        }
        (None, _) => {
            // Write tool — all additions
            let content = input.get("content").and_then(|v| v.as_str())?;
            let lines = content.lines().count() as u32;
            let first_line = content.lines().next().unwrap_or("").to_string();
            Some(ToolDiffPreview {
                context_line: None,
                snippet_text: truncate(&first_line, 80),
                snippet_prefix: "+".to_string(),
                is_addition: true,
                additions: lines,
                deletions: 0,
            })
        }
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Expanded rendering: input_display
// ---------------------------------------------------------------------------

/// Pre-formatted input for the expanded tool card.
pub fn compute_input_display(kind: ToolKind, input: Option<&serde_json::Value>) -> Option<String> {
    let input = input?;
    match kind {
        ToolKind::Bash => {
            let cmd = input.get("command").and_then(|v| v.as_str()).unwrap_or("");
            if cmd.is_empty() {
                None
            } else {
                Some(format!("$ {cmd}"))
            }
        }
        ToolKind::Read | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => input
            .get("file_path")
            .and_then(|v| v.as_str())
            .map(String::from),
        ToolKind::Glob | ToolKind::Grep => input
            .get("pattern")
            .and_then(|v| v.as_str())
            .map(String::from),
        ToolKind::WebSearch => input
            .get("query")
            .and_then(|v| v.as_str())
            .map(String::from),
        ToolKind::WebFetch => input.get("url").and_then(|v| v.as_str()).map(String::from),
        ToolKind::SpawnAgent => {
            let desc = input.get("description").and_then(|v| v.as_str());
            let prompt = input.get("prompt").and_then(|v| v.as_str());
            let agent_type = input.get("subagent_type").and_then(|v| v.as_str());
            let label = desc.or(prompt).unwrap_or("");
            match agent_type {
                Some(t) if !label.is_empty() => Some(format!("{t}: {label}")),
                Some(t) => Some(t.to_string()),
                None if !label.is_empty() => Some(label.to_string()),
                _ => None,
            }
        }
        ToolKind::McpToolCall | ToolKind::DynamicToolCall => {
            serde_json::to_string_pretty(input).ok()
        }
        _ => {
            if input.is_object() && input.as_object().is_none_or(|o| o.is_empty()) {
                None
            } else {
                serde_json::to_string_pretty(input).ok()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Expanded rendering: output_display
// ---------------------------------------------------------------------------

/// Pre-formatted output for the expanded tool card.
///
/// For Read tools, strips `cat -n` line number prefixes so the client receives
/// clean content. The starting line number is available via [`extract_start_line`].
pub fn compute_expanded_output(kind: ToolKind, result_output: Option<&str>) -> Option<String> {
    let output = result_output?;
    if output.is_empty() {
        return None;
    }

    if kind == ToolKind::Read {
        return Some(strip_cat_n_prefixes(output));
    }

    Some(output.to_string())
}

/// Extract the starting line number from Read tool output (`cat -n` format).
/// Returns `None` if the output doesn't use line numbers.
pub fn extract_start_line(kind: ToolKind, result_output: Option<&str>) -> Option<u32> {
    if kind != ToolKind::Read {
        return None;
    }
    let output = result_output?;
    let first_line = output.lines().next()?;
    parse_cat_n_line_number(first_line)
}

/// Strip line number prefixes from Read tool output.
///
/// Detection strategy (robust against format changes):
/// 1. Try to parse a leading number + separator from each of the first few lines
/// 2. Verify the parsed numbers are consecutive (N, N+1, N+2...)
/// 3. Only strip if the consecutive check passes — prevents false positives
///    on content that happens to start with numbers.
///
/// The separator can be any single non-alphanumeric character (tab, →, |, etc.)
fn strip_cat_n_prefixes(output: &str) -> String {
    let lines: Vec<&str> = output.lines().collect();

    if !has_consecutive_line_numbers(&lines) {
        return output.to_string();
    }

    lines
        .iter()
        .map(|line| {
            if let Some((_, content)) = split_line_number(line) {
                content
            } else {
                *line
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Parse the line number from a line with a number prefix.
fn parse_cat_n_line_number(line: &str) -> Option<u32> {
    split_line_number(line).map(|(num, _)| num)
}

/// Check whether the output has consecutive line numbers across multiple lines.
/// Requires at least 2 consecutive matches to confirm the pattern.
fn has_consecutive_line_numbers(lines: &[&str]) -> bool {
    let mut prev_num: Option<u32> = None;
    let mut consecutive_count = 0;

    for line in lines.iter().take(10) {
        if line.trim().is_empty() {
            continue;
        }
        match split_line_number(line) {
            Some((num, _)) => {
                if let Some(prev) = prev_num {
                    if num == prev + 1 {
                        consecutive_count += 1;
                        if consecutive_count >= 2 {
                            return true;
                        }
                    } else {
                        // Numbers aren't consecutive — not line-numbered output
                        return false;
                    }
                }
                prev_num = Some(num);
            }
            None => return false, // a non-empty line without a number → not line-numbered
        }
    }

    consecutive_count >= 2
}

/// Split a line into (line_number, content) if it has a number prefix.
///
/// Matches the pattern: `optional_whitespace + digits + single_separator_char + content`
/// where separator is any non-alphanumeric, non-space character.
/// This handles tab, →, |, :, and any future separator without hardcoding.
fn split_line_number(line: &str) -> Option<(u32, &str)> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() {
        return None;
    }

    // Find the run of leading digits
    let digit_end = trimmed.find(|c: char| !c.is_ascii_digit()).unwrap_or(0);
    if digit_end == 0 {
        return None; // no leading digits
    }

    let num: u32 = trimmed[..digit_end].parse().ok()?;

    // The next character must be a separator (non-alphanumeric, non-space)
    let rest = &trimmed[digit_end..];
    let sep_char = rest.chars().next()?;
    if sep_char.is_alphanumeric() || sep_char == ' ' {
        return None; // e.g. "42 items" or "42nd line" — not a line number prefix
    }

    let content_start = sep_char.len_utf8();
    Some((num, &rest[content_start..]))
}

// ---------------------------------------------------------------------------
// Expanded rendering: diff_display
// ---------------------------------------------------------------------------

/// Structured diff for edit/write tools in the expanded view.
/// Uses the `similar` crate for proper LCS-based interleaved diffs with context lines.
pub fn compute_diff_display(
    kind: ToolKind,
    input: Option<&serde_json::Value>,
) -> Option<Vec<DiffLine>> {
    if !matches!(
        kind,
        ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
    ) {
        return None;
    }
    let input = input?;

    // Check for pre-computed unified_diff first — parse it into structured lines
    if let Some(diff_str) = input.get("unified_diff").and_then(|v| v.as_str()) {
        if !diff_str.is_empty() {
            return Some(parse_unified_diff_string(diff_str));
        }
    }

    let old_string = input.get("old_string").and_then(|v| v.as_str());
    let new_string = input.get("new_string").and_then(|v| v.as_str());

    match (old_string, new_string) {
        (Some(old), Some(new)) => {
            let lines = compute_similar_diff(old, new);
            if lines.is_empty() {
                None
            } else {
                Some(lines)
            }
        }
        (None, _) => {
            // Write-only: content field = all additions
            let content = input.get("content").and_then(|v| v.as_str())?;
            let lines: Vec<DiffLine> = content
                .lines()
                .enumerate()
                .map(|(i, line)| DiffLine {
                    kind: DiffLineKind::Addition,
                    old_line: None,
                    new_line: Some((i + 1) as u32),
                    content: line.to_string(),
                })
                .collect();
            if lines.is_empty() {
                None
            } else {
                Some(lines)
            }
        }
        _ => None,
    }
}

/// Compute a proper interleaved diff using the `similar` crate (Myers/LCS algorithm).
fn compute_similar_diff(old: &str, new: &str) -> Vec<DiffLine> {
    use similar::{ChangeTag, TextDiff};

    let text_diff = TextDiff::from_lines(old, new);
    let mut lines = Vec::new();

    for change in text_diff.iter_all_changes() {
        let content = change.value().trim_end_matches('\n').to_string();
        match change.tag() {
            ChangeTag::Equal => {
                lines.push(DiffLine {
                    kind: DiffLineKind::Context,
                    old_line: change.old_index().map(|i| (i + 1) as u32),
                    new_line: change.new_index().map(|i| (i + 1) as u32),
                    content,
                });
            }
            ChangeTag::Delete => {
                lines.push(DiffLine {
                    kind: DiffLineKind::Deletion,
                    old_line: change.old_index().map(|i| (i + 1) as u32),
                    new_line: None,
                    content,
                });
            }
            ChangeTag::Insert => {
                lines.push(DiffLine {
                    kind: DiffLineKind::Addition,
                    old_line: None,
                    new_line: change.new_index().map(|i| (i + 1) as u32),
                    content,
                });
            }
        }
    }

    lines
}

/// Parse a pre-computed unified diff string into structured DiffLine entries.
/// Handles standard unified diff format with @@ hunk headers.
fn parse_unified_diff_string(diff: &str) -> Vec<DiffLine> {
    let mut lines = Vec::new();
    let mut old_line: u32 = 1;
    let mut new_line: u32 = 1;

    for raw in diff.lines() {
        if raw.starts_with("@@") {
            // Parse hunk header: @@ -a,b +c,d @@
            if let Some(nums) = parse_hunk_header(raw) {
                old_line = nums.0;
                new_line = nums.1;
            }
            continue;
        }
        if raw.starts_with("---") || raw.starts_with("+++") {
            continue; // Skip file headers
        }

        if let Some(content) = raw.strip_prefix('-') {
            lines.push(DiffLine {
                kind: DiffLineKind::Deletion,
                old_line: Some(old_line),
                new_line: None,
                content: content.to_string(),
            });
            old_line += 1;
        } else if let Some(content) = raw.strip_prefix('+') {
            lines.push(DiffLine {
                kind: DiffLineKind::Addition,
                old_line: None,
                new_line: Some(new_line),
                content: content.to_string(),
            });
            new_line += 1;
        } else {
            // Context line (may have leading space)
            let content = raw.strip_prefix(' ').unwrap_or(raw);
            lines.push(DiffLine {
                kind: DiffLineKind::Context,
                old_line: Some(old_line),
                new_line: Some(new_line),
                content: content.to_string(),
            });
            old_line += 1;
            new_line += 1;
        }
    }

    lines
}

/// Parse @@ -a,b +c,d @@ → (a, c)
fn parse_hunk_header(header: &str) -> Option<(u32, u32)> {
    let header = header.trim_start_matches('@').trim();
    let parts: Vec<&str> = header.split_whitespace().collect();
    if parts.len() < 2 {
        return None;
    }

    let old_start = parts[0]
        .trim_start_matches('-')
        .split(',')
        .next()?
        .parse::<u32>()
        .ok()?;
    let new_start = parts[1]
        .trim_start_matches('+')
        .split(',')
        .next()?
        .parse::<u32>()
        .ok()?;

    Some((old_start, new_start))
}

// ---------------------------------------------------------------------------
// Todo item extraction
// ---------------------------------------------------------------------------

fn extract_todo_items(kind: ToolKind, input: Option<&serde_json::Value>) -> Vec<ToolTodoItem> {
    if kind != ToolKind::TodoWrite {
        return vec![];
    }
    let input = match input {
        Some(v) => v,
        None => return vec![],
    };
    // TodoWrite input shape: {"tasks": [{"content": "...", "status": "completed"}, ...]}
    let items = match input.get("tasks").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return vec![],
    };
    items
        .iter()
        .map(|item| {
            let status = item
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("pending")
                .to_string();
            let content = item
                .get("content")
                .and_then(|v| v.as_str())
                .map(|s| truncate(s, 200));
            ToolTodoItem { status, content }
        })
        .collect()
}
