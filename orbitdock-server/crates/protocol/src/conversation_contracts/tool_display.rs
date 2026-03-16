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

    /// Unified diff string for edit/write tools — expanded view renders this line-by-line.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_display: Option<String>,
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
    let unwrapped = invocation_input.and_then(|v| {
        v.get("raw_input").filter(|ri| ri.is_object()).or(Some(v))
    });
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
        ToolKind::HandoffRequested => {
            ("arrow.triangle.branch".into(), "statusReply".into())
        }
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
            if title.is_empty() { "MCP Tool".into() } else { title.to_string() }
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
            if title.is_empty() { "Tool".into() } else { title.to_string() }
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
        ToolKind::WebFetch => input
            .get("url")
            .and_then(|v| v.as_str())
            .map(String::from),
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
        ToolKind::Config => input
            .get("key")
            .and_then(|v| v.as_str())
            .map(String::from),
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
        // Shell: first few meaningful lines
        ToolKind::Bash => {
            let preview: String = output
                .lines()
                .filter(|l| !l.trim().is_empty())
                .take(3)
                .collect::<Vec<_>>()
                .join("\n");
            if preview.is_empty() {
                None
            } else {
                Some(truncate(&preview, 300))
            }
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
        // Read: first 2 non-empty lines for file content preview
        ToolKind::Read => {
            let lines: Vec<&str> = output
                .lines()
                .filter(|l| !l.trim().is_empty())
                .take(2)
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
    if !matches!(kind, ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit) {
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
        ToolKind::WebFetch => input
            .get("url")
            .and_then(|v| v.as_str())
            .map(String::from),
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
            if input.is_object() && input.as_object().map_or(true, |o| o.is_empty()) {
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
pub fn compute_expanded_output(kind: ToolKind, result_output: Option<&str>) -> Option<String> {
    let output = result_output?;
    if output.is_empty() {
        return None;
    }
    _ = kind;
    Some(output.to_string())
}

// ---------------------------------------------------------------------------
// Expanded rendering: diff_display
// ---------------------------------------------------------------------------

/// Unified diff for edit/write tools in the expanded view.
pub fn compute_diff_display(kind: ToolKind, input: Option<&serde_json::Value>) -> Option<String> {
    if !matches!(
        kind,
        ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
    ) {
        return None;
    }
    let input = input?;

    if let Some(diff) = input.get("unified_diff").and_then(|v| v.as_str()) {
        if !diff.is_empty() {
            return Some(diff.to_string());
        }
    }

    let old_string = input.get("old_string").and_then(|v| v.as_str());
    let new_string = input.get("new_string").and_then(|v| v.as_str());

    match (old_string, new_string) {
        (Some(old), Some(new)) => {
            let mut diff = String::new();
            for line in old.lines() {
                diff.push_str(&format!("-{line}\n"));
            }
            for line in new.lines() {
                diff.push_str(&format!("+{line}\n"));
            }
            if diff.is_empty() { None } else { Some(diff) }
        }
        (None, _) => {
            let content = input.get("content").and_then(|v| v.as_str())?;
            let diff: String = content.lines().map(|l| format!("+{l}\n")).collect();
            if diff.is_empty() { None } else { Some(diff) }
        }
        _ => None,
    }
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
        .filter_map(|item| {
            let status = item
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("pending")
                .to_string();
            let content = item
                .get("content")
                .and_then(|v| v.as_str())
                .map(|s| truncate(s, 200));
            Some(ToolTodoItem { status, content })
        })
        .collect()
}
