use std::path::Path;

use orbitdock_protocol::{
  ApprovalPreview, ApprovalPreviewSegment, ApprovalPreviewType, ApprovalQuestionPrompt,
  ApprovalType,
};
use serde_json::{Map as JsonMap, Value as JsonValue};

#[path = "approval_preview_patch_diff.rs"]
mod patch_diff;
#[path = "approval_preview_questions.rs"]
mod questions;
#[path = "approval_preview_risk.rs"]
mod risk;
#[path = "approval_preview_shell.rs"]
mod shell;

pub struct ApprovalPreviewInput<'a> {
  pub request_id: &'a str,
  pub approval_type: ApprovalType,
  pub tool_name: Option<&'a str>,
  pub tool_input: Option<&'a str>,
  pub command: Option<&'a str>,
  pub file_path: Option<&'a str>,
  pub diff: Option<&'a str>,
  pub question: Option<&'a str>,
  pub permission_reason: Option<&'a str>,
}

pub fn approval_question_prompts(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  questions::approval_question_prompts(tool_input, fallback_question)
}

pub fn approval_question(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Option<String> {
  questions::approval_question(tool_input, fallback_question)
}

pub fn approval_preview(input: ApprovalPreviewInput<'_>) -> Option<ApprovalPreview> {
  build_approval_preview(input)
}

pub(crate) fn shell_segments_for_preview(command: &str) -> Vec<ApprovalPreviewSegment> {
  shell::shell_segments_for_preview(command)
}

fn build_approval_preview(input_data: ApprovalPreviewInput<'_>) -> Option<ApprovalPreview> {
  let ApprovalPreviewInput {
    request_id,
    approval_type,
    tool_name,
    tool_input,
    command,
    file_path,
    diff,
    question,
    permission_reason,
  } = input_data;

  let input = parse_tool_input_object(tool_input);
  let normalized_tool_name = trim_non_empty(tool_name)
    .map(|name| name.to_lowercase())
    .unwrap_or_default();

  let command_from_input = input
    .as_ref()
    .and_then(|dict| dict.get("command").or_else(|| dict.get("cmd")))
    .and_then(shell_command_from_json_value);
  let command = command_from_input.or_else(|| trim_non_empty(command));
  let risk_assessment = risk::assess_approval_risk(approval_type, command.as_deref());

  let file_path_from_input = input.as_ref().and_then(|dict| {
    dict
      .get("path")
      .and_then(|value| value.as_str())
      .and_then(trim_non_empty_str)
      .or_else(|| {
        dict
          .get("file_path")
          .and_then(|value| value.as_str())
          .and_then(trim_non_empty_str)
      })
  });
  let file_path = file_path_from_input.or_else(|| trim_non_empty(file_path));

  let url = input.as_ref().and_then(|dict| {
    dict
      .get("url")
      .and_then(|value| value.as_str())
      .and_then(trim_non_empty_str)
  });
  let query = input.as_ref().and_then(|dict| {
    dict
      .get("query")
      .and_then(|value| value.as_str())
      .and_then(trim_non_empty_str)
  });
  let pattern = input.as_ref().and_then(|dict| {
    dict
      .get("pattern")
      .and_then(|value| value.as_str())
      .and_then(trim_non_empty_str)
  });
  let prompt = input.as_ref().and_then(|dict| {
    dict
      .get("prompt")
      .and_then(|value| value.as_str())
      .and_then(trim_non_empty_str)
  });
  let fallback_input_value = input.as_ref().and_then(first_string_value_from_json_object);
  let question_text = trim_non_empty(question);
  let patch_diff = trim_non_empty(diff).or_else(|| {
    input
      .as_ref()
      .and_then(|dict| patch_diff::diff_preview_from_patch_input(dict, file_path.as_deref()))
  });

  let ctx = ApprovalPreviewContext {
    request_id,
    approval_type,
    tool_name,
    normalized_tool_name: normalized_tool_name.as_str(),
    risk_assessment: &risk_assessment,
  };

  if approval_type == ApprovalType::Patch {
    if let Some(diff_preview) = patch_diff {
      return Some(compose_approval_preview(
        &ctx,
        ApprovalPreviewType::Diff,
        patch_diff::normalize_diff_preview(diff_preview.as_str()),
        vec![],
      ));
    }
  }

  if let Some(command) = command {
    let shell_segments = shell_segments_for_preview(&command);
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::ShellCommand,
      command,
      shell_segments,
    ));
  }

  if let Some(url) = url {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::Url,
      url,
      vec![],
    ));
  }

  if let Some(query) = query {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::SearchQuery,
      query,
      vec![],
    ));
  }

  if let Some(pattern) = pattern {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::Pattern,
      pattern,
      vec![],
    ));
  }

  if let Some(prompt) = prompt {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::Prompt,
      prompt,
      vec![],
    ));
  }

  if matches!(
    approval_type,
    ApprovalType::Question | ApprovalType::Permissions
  ) {
    if let Some(question) = question_text.or_else(|| permission_reason.map(str::to_string)) {
      return Some(compose_approval_preview(
        &ctx,
        ApprovalPreviewType::Prompt,
        question,
        vec![],
      ));
    }
  }

  if let Some(path) = file_path {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::FilePath,
      path,
      vec![],
    ));
  }

  if let Some(value) = fallback_input_value {
    return Some(compose_approval_preview(
      &ctx,
      ApprovalPreviewType::Value,
      value,
      vec![],
    ));
  }

  let fallback_action = match approval_type {
    ApprovalType::Question => trim_non_empty(tool_name).unwrap_or_else(|| "Question".to_string()),
    ApprovalType::Permissions => {
      trim_non_empty(tool_name).unwrap_or_else(|| "Review requested permissions".to_string())
    }
    _ => trim_non_empty(tool_name)
      .map(|name| format!("Approve {name} action"))
      .unwrap_or_else(|| "Approve action".to_string()),
  };

  Some(compose_approval_preview(
    &ctx,
    ApprovalPreviewType::Action,
    fallback_action,
    vec![],
  ))
}

struct ApprovalPreviewContext<'a> {
  request_id: &'a str,
  approval_type: ApprovalType,
  tool_name: Option<&'a str>,
  normalized_tool_name: &'a str,
  risk_assessment: &'a risk::ApprovalRiskAssessment,
}

fn compose_approval_preview(
  ctx: &ApprovalPreviewContext<'_>,
  preview_type: ApprovalPreviewType,
  value: String,
  shell_segments: Vec<ApprovalPreviewSegment>,
) -> ApprovalPreview {
  let compact = compact_detail_for_preview(
    preview_type,
    value.as_str(),
    shell_segments.as_slice(),
    ctx.normalized_tool_name,
  );
  let decision_scope = decision_scope_for_preview(preview_type).to_string();
  let manifest = build_manifest_for_preview(
    ctx,
    preview_type,
    value.as_str(),
    shell_segments.as_slice(),
    decision_scope.as_str(),
  );

  ApprovalPreview {
    preview_type,
    value,
    shell_segments,
    compact,
    decision_scope: Some(decision_scope),
    risk_level: ctx.risk_assessment.level,
    risk_findings: ctx.risk_assessment.findings.clone(),
    manifest: Some(manifest),
  }
}

fn decision_scope_for_preview(preview_type: ApprovalPreviewType) -> &'static str {
  match preview_type {
    ApprovalPreviewType::ShellCommand => {
      "approve/deny applies to all command segments in this request."
    }
    ApprovalPreviewType::Diff | ApprovalPreviewType::FilePath => {
      "approve/deny applies to this full file action."
    }
    ApprovalPreviewType::Action
    | ApprovalPreviewType::Value
    | ApprovalPreviewType::Url
    | ApprovalPreviewType::SearchQuery
    | ApprovalPreviewType::Pattern
    | ApprovalPreviewType::Prompt => "approve/deny applies to this full tool action.",
  }
}

fn build_manifest_for_preview(
  ctx: &ApprovalPreviewContext<'_>,
  preview_type: ApprovalPreviewType,
  value: &str,
  shell_segments: &[ApprovalPreviewSegment],
  decision_scope: &str,
) -> String {
  let resolved_tool = trim_non_empty(ctx.tool_name).unwrap_or_else(|| "unknown".to_string());
  let resolved_request_id =
    trim_non_empty(Some(ctx.request_id)).unwrap_or_else(|| "unknown".to_string());

  let mut lines: Vec<String> = vec![
    "APPROVAL MANIFEST".to_string(),
    format!("request_id: {resolved_request_id}"),
    format!(
      "approval_type: {}",
      risk::approval_type_label(ctx.approval_type)
    ),
    format!("tool: {resolved_tool}"),
    format!(
      "risk_tier: {}",
      risk::risk_level_label(ctx.risk_assessment.level)
    ),
  ];

  if !ctx.risk_assessment.findings.is_empty() {
    lines.push("risk_signals:".to_string());
    lines.extend(
      ctx
        .risk_assessment
        .findings
        .iter()
        .map(|finding| format!("- {finding}")),
    );
  }

  lines.push(String::new());
  lines.push(format!("decision_scope: {decision_scope}"));
  lines.extend(manifest_content_lines(preview_type, value, shell_segments));

  lines.join("\n")
}

fn manifest_content_lines(
  preview_type: ApprovalPreviewType,
  value: &str,
  shell_segments: &[ApprovalPreviewSegment],
) -> Vec<String> {
  match preview_type {
    ApprovalPreviewType::ShellCommand => {
      let mut lines = vec![format!(
        "command_segments: {}",
        std::cmp::max(shell_segments.len(), 1)
      )];
      lines.push("segments:".to_string());
      if shell_segments.is_empty() {
        lines.push(format!("[1] {value}"));
        return lines;
      }

      lines.extend(shell_segments.iter().enumerate().map(|(index, segment)| {
        let prefix = shell::shell_operator_prefix(segment.leading_operator.as_deref());
        format!("[{}] {}{}", index + 1, prefix, segment.command)
      }));
      lines
    }
    ApprovalPreviewType::Diff => patch_diff::diff_manifest_lines(value),
    ApprovalPreviewType::FilePath => vec![format!("target_file: {value}")],
    ApprovalPreviewType::Url => vec![format!("target_url: {value}")],
    ApprovalPreviewType::SearchQuery => vec![format!("search_query: {value}")],
    ApprovalPreviewType::Pattern => vec![format!("pattern: {value}")],
    ApprovalPreviewType::Prompt => vec![format!("prompt: {value}")],
    ApprovalPreviewType::Value => vec![format!("value: {value}")],
    ApprovalPreviewType::Action => vec![format!("action: {value}")],
  }
}

fn parse_tool_input_object(tool_input: Option<&str>) -> Option<JsonMap<String, JsonValue>> {
  let raw = trim_non_empty(tool_input)?;
  let parsed: JsonValue = serde_json::from_str(&raw).ok()?;
  parsed.as_object().cloned()
}

fn shell_command_from_json_value(value: &JsonValue) -> Option<String> {
  if let Some(command) = value.as_str() {
    return trim_non_empty(Some(command));
  }

  let parts = value.as_array()?;
  let tokens: Option<Vec<String>> = parts
    .iter()
    .map(|item| item.as_str().map(|token| token.to_string()))
    .collect();
  let joined = tokens?.join(" ");
  trim_non_empty(Some(joined.as_str()))
}

fn first_string_value_from_json_object(dict: &JsonMap<String, JsonValue>) -> Option<String> {
  let mut keys: Vec<&String> = dict.keys().collect();
  keys.sort_unstable();

  for key in keys {
    if let Some(value) = dict.get(key).and_then(|raw| raw.as_str()) {
      if let Some(trimmed) = trim_non_empty(Some(value)) {
        return Some(trimmed);
      }
    }
  }

  None
}

fn compact_detail_for_preview(
  preview_type: ApprovalPreviewType,
  value: &str,
  shell_segments: &[ApprovalPreviewSegment],
  normalized_tool_name: &str,
) -> Option<String> {
  let summary = match preview_type {
    ApprovalPreviewType::ShellCommand => {
      if shell_segments.len() > 1 {
        let first = shell_segments
          .first()
          .map(|segment| segment.command.clone())
          .unwrap_or_else(|| value.to_string());
        let remaining = shell_segments.len().saturating_sub(1);
        let noun = if remaining == 1 {
          "segment"
        } else {
          "segments"
        };
        format!("{first} +{remaining} {noun}")
      } else {
        value.to_string()
      }
    }
    ApprovalPreviewType::Diff => patch_diff::diff_compact_summary(value),
    ApprovalPreviewType::Url => format!("url: {value}"),
    ApprovalPreviewType::SearchQuery => format!("query: {value}"),
    ApprovalPreviewType::Pattern => format!("pattern: {value}"),
    ApprovalPreviewType::Prompt => format!("prompt: {value}"),
    ApprovalPreviewType::FilePath
      if matches!(
        normalized_tool_name,
        "edit" | "write" | "read" | "notebookedit"
      ) =>
    {
      Path::new(value)
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_string())
        .unwrap_or_else(|| value.to_string())
    }
    ApprovalPreviewType::Value | ApprovalPreviewType::FilePath | ApprovalPreviewType::Action => {
      value.to_string()
    }
  };

  let trimmed = trim_non_empty(Some(summary.as_str()))?;
  Some(compact_truncate(trimmed, 50))
}

fn compact_truncate(text: String, max_length: usize) -> String {
  if max_length == 0 {
    return String::new();
  }
  if max_length <= 3 {
    return text.chars().take(max_length).collect();
  }
  if text.chars().count() <= max_length {
    return text;
  }
  let prefix: String = text.chars().take(max_length.saturating_sub(3)).collect();
  format!("{prefix}...")
}

fn trim_non_empty(value: Option<&str>) -> Option<String> {
  let value = value?;
  let trimmed = value.trim();
  if trimmed.is_empty() {
    None
  } else {
    Some(trimmed.to_string())
  }
}

fn trim_non_empty_str(value: &str) -> Option<String> {
  trim_non_empty(Some(value))
}
