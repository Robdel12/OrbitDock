use super::{
  compute_tool_display, extract_compact_result_text, extract_expanded_result_text, ToolDisplayInput,
};
use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};

#[test]
fn codex_edit_diff_payload_produces_lightweight_preview() {
  let input_json = serde_json::json!({
      "path": "/tmp/SessionRuntime+Events.swift",
      "diff": "--- /tmp/SessionRuntime+Events.swift\n+++ /tmp/SessionRuntime+Events.swift\n@@ -10,2 +10,3 @@\n let keep = true\n+let preview = true\n let done = true"
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Edit,
    family: ToolFamily::FileChange,
    status: ToolStatus::Completed,
    title: "Edit",
    subtitle: None,
    summary: None,
    duration_ms: None,
    invocation_input: Some(&input_json),
    result_output: None,
  });

  let preview = display
    .diff_preview
    .expect("Codex diff-only payload should render a compact preview");
  assert_eq!(preview.snippet_prefix, "+");
  assert!(preview.is_addition);
  assert_eq!(preview.additions, 1);
  assert_eq!(preview.deletions, 0);
  assert_eq!(preview.preview_lines, vec!["let preview = true"]);
}

#[test]
fn write_content_payload_still_produces_addition_preview() {
  let input_json = serde_json::json!({
      "path": "/tmp/example.swift",
      "content": "let a = 1\nlet b = 2"
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Write,
    family: ToolFamily::FileChange,
    status: ToolStatus::Completed,
    title: "Write",
    subtitle: None,
    summary: None,
    duration_ms: None,
    invocation_input: Some(&input_json),
    result_output: None,
  });

  let preview = display
    .diff_preview
    .expect("Write payload should still render a compact preview");
  assert_eq!(preview.snippet_prefix, "+");
  assert!(preview.is_addition);
  assert_eq!(preview.additions, 2);
  assert_eq!(preview.deletions, 0);
  assert_eq!(preview.preview_lines, vec!["let a = 1", "let b = 2"]);
}

#[test]
fn diff_preview_prefers_first_added_block_for_collapsed_file_change_cards() {
  let input_json = serde_json::json!({
      "path": "/tmp/example.swift",
      "diff": "--- /tmp/example.swift\n+++ /tmp/example.swift\n@@ -1,3 +1,4 @@\n-import OldView from './old-view';\n+import NewView from './new-view';\n+import PreviewStrip from './preview-strip';\n let keep = true\n let done = true"
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Edit,
    family: ToolFamily::FileChange,
    status: ToolStatus::Completed,
    title: "Edit",
    subtitle: None,
    summary: None,
    duration_ms: None,
    invocation_input: Some(&input_json),
    result_output: None,
  });

  let preview = display
    .diff_preview
    .expect("Edit payload should produce a collapsed diff preview");
  assert_eq!(preview.snippet_prefix, "+");
  assert!(preview.is_addition);
  assert_eq!(
    preview.preview_lines,
    vec![
      "import NewView from './new-view';",
      "import PreviewStrip from './preview-strip';"
    ]
  );
}

#[test]
fn compact_result_text_prefers_summary_then_output() {
  let summary_result = serde_json::json!({
      "summary": "3 files updated",
      "raw_output": { "files": 3 }
  });
  assert_eq!(
    extract_compact_result_text(Some(&summary_result)).as_deref(),
    Some("3 files updated")
  );

  let output_result = serde_json::json!({
      "raw_output": { "files": 3 },
      "output": "done"
  });
  assert_eq!(
    extract_compact_result_text(Some(&output_result)).as_deref(),
    Some("done")
  );
}

use super::{compute_expanded_output, compute_input_display};

fn guardian_card(
  status: ToolStatus,
  invocation: Option<&serde_json::Value>,
  result_output: Option<&str>,
) -> super::ToolDisplay {
  compute_tool_display(ToolDisplayInput {
    kind: ToolKind::GuardianAssessment,
    family: ToolFamily::Approval,
    status,
    title: "Auto-review",
    subtitle: None,
    summary: None,
    duration_ms: None,
    invocation_input: invocation,
    result_output,
  })
}

#[test]
fn guardian_card_identity() {
  let display = guardian_card(ToolStatus::Completed, None, None);
  assert_eq!(display.summary, "Auto-review");
  assert_eq!(display.tool_type, "guardianAssessment");
  assert_eq!(display.glyph_symbol, "shield.lefthalf.filled");
  assert_eq!(display.glyph_color, "feedbackCaution");
  assert_eq!(display.display_tier, "prominent");
}

#[test]
fn guardian_output_preview_shows_rationale() {
  let result = serde_json::json!({
      "status_label": "approved",
      "risk_level": "medium",
      "risk_score": 42,
      "rationale": "Command only reads local files"
  });
  let display = guardian_card(
    ToolStatus::Completed,
    None,
    Some(&serde_json::to_string(&result).unwrap()),
  );
  assert_eq!(
    display.output_preview.as_deref(),
    Some("Command only reads local files")
  );
}

#[test]
fn guardian_output_preview_falls_back_to_risk() {
  let result = serde_json::json!({
      "status_label": "approved",
      "risk_level": "high",
      "risk_score": 85
  });
  let display = guardian_card(
    ToolStatus::Completed,
    None,
    Some(&serde_json::to_string(&result).unwrap()),
  );
  assert_eq!(
    display.output_preview.as_deref(),
    Some("high risk — score 85/100")
  );
}

#[test]
fn guardian_subtitle_extracts_command() {
  let invocation = serde_json::json!({
      "action": { "command": "git push --force" },
      "status_label": "reviewing"
  });
  let display = guardian_card(ToolStatus::Running, Some(&invocation), None);
  assert_eq!(display.subtitle.as_deref(), Some("git push --force"));
}

#[test]
fn guardian_expanded_output_structured() {
  let result = serde_json::json!({
      "status_label": "denied",
      "risk_level": "high",
      "risk_score": 90,
      "rationale": "Destructive command detected"
  });
  let output_str = serde_json::to_string(&result).unwrap();
  let expanded = compute_expanded_output(ToolKind::GuardianAssessment, Some(&output_str)).unwrap();
  assert!(expanded.contains("Verdict: denied"));
  assert!(expanded.contains("Risk: high (90/100)"));
  assert!(expanded.contains("Rationale: Destructive command detected"));
}

#[test]
fn guardian_input_display_shows_command() {
  let invocation = serde_json::json!({
      "action": { "command": "rm -rf /tmp/data" },
      "risk_level": "high",
      "status_label": "reviewing"
  });
  let input = compute_input_display(ToolKind::GuardianAssessment, Some(&invocation)).unwrap();
  assert_eq!(input, "$ rm -rf /tmp/data");
}

#[test]
fn guardian_input_display_falls_back_to_pretty_action() {
  let invocation = serde_json::json!({
      "action": { "tool": "write", "path": "/tmp/test.txt" },
      "status_label": "reviewing"
  });
  let input = compute_input_display(ToolKind::GuardianAssessment, Some(&invocation)).unwrap();
  assert!(input.contains("\"tool\": \"write\""));
  assert!(input.contains("\"path\": \"/tmp/test.txt\""));
}

#[test]
fn expanded_result_text_preserves_structured_payloads() {
  let payload = serde_json::json!({
      "status_label": "approved",
      "risk_level": "low",
      "risk_score": 12,
      "rationale": "Local-only command"
  });
  let text = extract_expanded_result_text(Some(&payload)).unwrap();
  assert!(text.contains("\"status_label\": \"approved\""));
  assert!(text.contains("\"risk_score\": 12"));
}

#[test]
fn dynamic_tool_display_is_not_classified_as_mcp() {
  let invocation = serde_json::json!({
    "tool_name": "file_write",
    "raw_input": {
      "path": "README.md",
      "content": "hello"
    }
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::DynamicToolCall,
    family: ToolFamily::Generic,
    status: ToolStatus::Completed,
    title: "file_write",
    subtitle: None,
    summary: None,
    duration_ms: Some(7),
    invocation_input: Some(&invocation),
    result_output: Some("{\"bytes_written\":5}"),
  });

  assert_eq!(display.summary, "file_write");
  assert_eq!(display.tool_type, "dynamicTool");
  assert_eq!(display.glyph_symbol, "wrench.and.screwdriver");
  assert_eq!(display.glyph_color, "toolTask");
}

#[test]
fn view_image_input_display_reads_path_payloads() {
  let invocation = serde_json::json!({
    "path": "/tmp/pitboard-now-board_8243f01796e5.png"
  });

  let input = compute_input_display(ToolKind::ViewImage, Some(&invocation)).unwrap();

  assert_eq!(input, "/tmp/pitboard-now-board_8243f01796e5.png");
}

#[test]
fn plan_family_write_uses_plan_tool_card_semantics() {
  let invocation = serde_json::json!({
    "raw_input": {
      "path": "plans/new-plan.md",
      "content": "# Plan"
    }
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Write,
    family: ToolFamily::Plan,
    status: ToolStatus::Completed,
    title: "Plan",
    subtitle: None,
    summary: Some("Saved plan (42 bytes) to plans/new-plan.md"),
    duration_ms: Some(4),
    invocation_input: Some(&invocation),
    result_output: Some("{\"path\":\"plans/new-plan.md\",\"bytes_written\":42}"),
  });

  assert_eq!(display.tool_type, "plan");
  assert_eq!(display.glyph_symbol, "map");
  assert_eq!(display.glyph_color, "toolPlan");
  assert_eq!(display.display_tier, "standard");
}

#[test]
fn plan_family_write_defaults_summary_to_plan() {
  let invocation = serde_json::json!({
    "raw_input": {
      "path": "plans/new-plan.md",
      "content": "# Plan"
    }
  });
  let display = compute_tool_display(ToolDisplayInput {
    kind: ToolKind::Write,
    family: ToolFamily::Plan,
    status: ToolStatus::Running,
    title: "Plan",
    subtitle: None,
    summary: None,
    duration_ms: None,
    invocation_input: Some(&invocation),
    result_output: None,
  });

  assert_eq!(display.summary, "Plan");
  assert_eq!(display.tool_type, "plan");
}
