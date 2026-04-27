use std::path::Path;

use orbitdock_protocol::{
  ApprovalPreview, ApprovalPreviewSegment, ApprovalPreviewType, ApprovalQuestionOption,
  ApprovalQuestionPrompt, ApprovalRiskLevel, ApprovalType,
};
use serde_json::{Map as JsonMap, Value as JsonValue};

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
  extract_question_prompts_for_approval(tool_input, fallback_question)
}

pub fn approval_question(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Option<String> {
  let prompts = approval_question_prompts(tool_input, fallback_question);
  prompts
    .first()
    .map(|prompt| prompt.question.clone())
    .filter(|text| !text.is_empty())
    .or_else(|| trim_non_empty(fallback_question))
}

pub fn approval_preview(input: ApprovalPreviewInput<'_>) -> Option<ApprovalPreview> {
  build_approval_preview(input)
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
  let risk_assessment = assess_approval_risk(approval_type, command.as_deref());

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
  let question = trim_non_empty(question);
  let patch_diff = trim_non_empty(diff).or_else(|| {
    input
      .as_ref()
      .and_then(|dict| diff_preview_from_patch_input(dict, file_path.as_deref()))
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
        normalize_diff_preview(diff_preview.as_str()),
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
    if let Some(question) = question.or_else(|| permission_reason.map(str::to_string)) {
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

#[derive(Debug, Clone)]
struct ApprovalRiskAssessment {
  level: ApprovalRiskLevel,
  findings: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
struct ExecRiskRule {
  pattern: &'static str,
  finding: &'static str,
}

const EXEC_RISK_RULES: &[ExecRiskRule] = &[
  ExecRiskRule {
    pattern: " sudo ",
    finding: "Uses elevated privileges via sudo.",
  },
  ExecRiskRule {
    pattern: " rm -rf",
    finding: "Deletes files recursively with rm -rf.",
  },
  ExecRiskRule {
    pattern: " rm -fr",
    finding: "Deletes files recursively with rm -fr.",
  },
  ExecRiskRule {
    pattern: " git reset --hard",
    finding: "Performs hard git reset and discards local changes.",
  },
  ExecRiskRule {
    pattern: " git clean -fd",
    finding: "Deletes untracked files with git clean -fd.",
  },
  ExecRiskRule {
    pattern: " git clean -xdf",
    finding: "Deletes ignored and untracked files with git clean -xdf.",
  },
  ExecRiskRule {
    pattern: " git push --force",
    finding: "Force-pushes git history.",
  },
  ExecRiskRule {
    pattern: " git push -f",
    finding: "Force-pushes git history.",
  },
  ExecRiskRule {
    pattern: " drop table",
    finding: "Contains SQL DROP TABLE statement.",
  },
  ExecRiskRule {
    pattern: " drop database",
    finding: "Contains SQL DROP DATABASE statement.",
  },
  ExecRiskRule {
    pattern: " truncate table",
    finding: "Contains SQL TRUNCATE TABLE statement.",
  },
  ExecRiskRule {
    pattern: " chmod 777",
    finding: "Sets permissive file mode (chmod 777).",
  },
  ExecRiskRule {
    pattern: " curl | sh",
    finding: "Pipes remote script directly into shell (curl | sh).",
  },
  ExecRiskRule {
    pattern: " wget | sh",
    finding: "Pipes remote script directly into shell (wget | sh).",
  },
  ExecRiskRule {
    pattern: " dd if=",
    finding: "Uses dd with direct device/file writes.",
  },
  ExecRiskRule {
    pattern: " > /dev/",
    finding: "Writes output directly to a /dev device path.",
  },
  ExecRiskRule {
    pattern: " mkfs",
    finding: "Formats a filesystem with mkfs.",
  },
  ExecRiskRule {
    pattern: ":(){ :|:& };:",
    finding: "Contains a shell fork bomb signature.",
  },
];

fn assess_approval_risk(
  approval_type: ApprovalType,
  command: Option<&str>,
) -> ApprovalRiskAssessment {
  match approval_type {
    ApprovalType::Question => ApprovalRiskAssessment {
      level: ApprovalRiskLevel::Low,
      findings: vec![],
    },
    ApprovalType::Permissions | ApprovalType::Patch => ApprovalRiskAssessment {
      level: ApprovalRiskLevel::Normal,
      findings: vec![],
    },
    ApprovalType::Exec => {
      let Some(normalized_command) = normalize_command_for_risk(command) else {
        return ApprovalRiskAssessment {
          level: ApprovalRiskLevel::Normal,
          findings: vec![],
        };
      };

      let mut findings: Vec<String> = vec![];
      for rule in EXEC_RISK_RULES {
        if normalized_command.contains(rule.pattern) {
          let finding = rule.finding.to_string();
          if !findings.contains(&finding) {
            findings.push(finding);
          }
        }
      }

      let level = if findings.is_empty() {
        ApprovalRiskLevel::Normal
      } else {
        ApprovalRiskLevel::High
      };
      ApprovalRiskAssessment { level, findings }
    }
  }
}

fn normalize_command_for_risk(command: Option<&str>) -> Option<String> {
  let normalized = trim_non_empty(command)?.to_lowercase();
  Some(format!(" {normalized} "))
}

struct ApprovalPreviewContext<'a> {
  request_id: &'a str,
  approval_type: ApprovalType,
  tool_name: Option<&'a str>,
  normalized_tool_name: &'a str,
  risk_assessment: &'a ApprovalRiskAssessment,
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
    format!("approval_type: {}", approval_type_label(ctx.approval_type)),
    format!("tool: {resolved_tool}"),
    format!("risk_tier: {}", risk_level_label(ctx.risk_assessment.level)),
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
        let prefix = shell_operator_prefix(segment.leading_operator.as_deref());
        format!("[{}] {}{}", index + 1, prefix, segment.command)
      }));
      lines
    }
    ApprovalPreviewType::Diff => {
      let lines: Vec<&str> = value.lines().collect();
      let mut content = vec![format!("diff_lines: {}", lines.len())];
      if let Some(target_file) = diff_target_file(value) {
        content.push(format!("target_file: {target_file}"));
      }
      content.push("diff_preview:".to_string());
      let preview_limit = 40usize;
      content.extend(
        lines
          .iter()
          .take(preview_limit)
          .map(|line| (*line).to_string()),
      );
      if lines.len() > preview_limit {
        content.push(format!("... +{} more lines", lines.len() - preview_limit));
      }
      content
    }
    ApprovalPreviewType::FilePath => vec![format!("target_file: {value}")],
    ApprovalPreviewType::Url => vec![format!("target_url: {value}")],
    ApprovalPreviewType::SearchQuery => vec![format!("search_query: {value}")],
    ApprovalPreviewType::Pattern => vec![format!("pattern: {value}")],
    ApprovalPreviewType::Prompt => vec![format!("prompt: {value}")],
    ApprovalPreviewType::Value => vec![format!("value: {value}")],
    ApprovalPreviewType::Action => vec![format!("action: {value}")],
  }
}

fn shell_operator_prefix(leading_operator: Option<&str>) -> String {
  let Some(op) = leading_operator
    .map(|value| value.trim())
    .filter(|value| !value.is_empty())
  else {
    return String::new();
  };

  let meaning = match op {
    "||" => "if previous fails",
    "&&" => "if previous succeeds",
    "|" => "pipe output from previous",
    _ => "then",
  };
  format!("({op}, {meaning}) ")
}

fn approval_type_label(approval_type: ApprovalType) -> &'static str {
  match approval_type {
    ApprovalType::Exec => "exec",
    ApprovalType::Patch => "patch",
    ApprovalType::Question => "question",
    ApprovalType::Permissions => "permissions",
  }
}

fn risk_level_label(risk_level: ApprovalRiskLevel) -> &'static str {
  match risk_level {
    ApprovalRiskLevel::Low => "low",
    ApprovalRiskLevel::Normal => "normal",
    ApprovalRiskLevel::High => "high",
  }
}

fn parse_tool_input_object(tool_input: Option<&str>) -> Option<JsonMap<String, JsonValue>> {
  let raw = trim_non_empty(tool_input)?;
  let parsed: JsonValue = serde_json::from_str(&raw).ok()?;
  parsed.as_object().cloned()
}

fn parse_bool_value(value: Option<&JsonValue>) -> bool {
  let Some(value) = value else {
    return false;
  };
  if let Some(flag) = value.as_bool() {
    return flag;
  }
  if let Some(number) = value.as_u64() {
    return number > 0;
  }
  if let Some(text) = value.as_str() {
    let normalized = text.trim().to_ascii_lowercase();
    return normalized == "true" || normalized == "1" || normalized == "yes";
  }
  false
}

fn parse_question_options_from_json(value: Option<&JsonValue>) -> Vec<ApprovalQuestionOption> {
  let Some(options) = value.and_then(JsonValue::as_array) else {
    return vec![];
  };

  options
    .iter()
    .filter_map(|raw_option| {
      let option = raw_option.as_object()?;
      let label = option
        .get("label")
        .or_else(|| option.get("value"))
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)?;
      let description = option
        .get("description")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str);
      Some(ApprovalQuestionOption { label, description })
    })
    .collect()
}

fn parse_question_prompt_from_json(
  payload: &JsonMap<String, JsonValue>,
  fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
  let id = payload
    .get("id")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
    .unwrap_or_else(|| fallback_id.to_string());
  let header = payload
    .get("header")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str);
  let question = payload
    .get("question")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
    .unwrap_or_else(|| "Question".to_string());
  if question.is_empty() {
    return None;
  }

  Some(ApprovalQuestionPrompt {
    id,
    header,
    question,
    options: parse_question_options_from_json(payload.get("options")),
    allows_multiple_selection: parse_bool_value(
      payload
        .get("multiSelect")
        .or_else(|| payload.get("multi_select")),
    ),
    allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
    is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
  })
}

fn parse_question_prompts_from_tool_input(tool_input: Option<&str>) -> Vec<ApprovalQuestionPrompt> {
  let Some(input) = parse_tool_input_object(tool_input) else {
    return vec![];
  };

  if let Some(raw_questions) = input.get("questions").and_then(JsonValue::as_array) {
    return raw_questions
      .iter()
      .enumerate()
      .filter_map(|(index, raw_question)| {
        let payload = raw_question.as_object()?;
        parse_question_prompt_from_json(payload, index.to_string().as_str())
      })
      .collect();
  }

  if input.contains_key("question") || input.contains_key("options") {
    if let Some(prompt) = parse_question_prompt_from_json(&input, "0") {
      return vec![prompt];
    }
  }

  vec![]
}

fn extract_question_prompts_for_approval(
  tool_input: Option<&str>,
  fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
  let prompts = parse_question_prompts_from_tool_input(tool_input);
  if !prompts.is_empty() {
    return prompts;
  }

  let Some(question) = trim_non_empty(fallback_question) else {
    return vec![];
  };

  vec![ApprovalQuestionPrompt {
    id: "0".to_string(),
    header: None,
    question,
    options: vec![],
    allows_multiple_selection: false,
    allows_other: true,
    is_secret: false,
  }]
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

const APPROVAL_DIFF_PREVIEW_MAX_CHARS: usize = 12_000;

fn diff_preview_from_patch_input(
  dict: &JsonMap<String, JsonValue>,
  fallback_file_path: Option<&str>,
) -> Option<String> {
  if let Some(explicit_diff) = dict
    .get("diff")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
  {
    return Some(explicit_diff);
  }

  let file_path = dict
    .get("file_path")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
    .or_else(|| fallback_file_path.and_then(trim_non_empty_str))
    .unwrap_or_else(|| "file".to_string());

  let old_string = dict.get("old_string").and_then(JsonValue::as_str);
  let new_string = dict.get("new_string").and_then(JsonValue::as_str);

  if old_string.is_some() || new_string.is_some() {
    return Some(render_patch_diff(
      file_path.as_str(),
      file_path.as_str(),
      old_string.unwrap_or_default(),
      new_string.unwrap_or_default(),
    ));
  }

  if let Some(content) = dict
    .get("content")
    .and_then(JsonValue::as_str)
    .and_then(trim_non_empty_str)
  {
    return Some(render_patch_diff(
      "/dev/null",
      file_path.as_str(),
      "",
      content.as_str(),
    ));
  }

  None
}

fn render_patch_diff(old_path: &str, new_path: &str, old_text: &str, new_text: &str) -> String {
  let mut lines = vec![
    format!("--- {old_path}"),
    format!("+++ {new_path}"),
    "@@".to_string(),
  ];

  lines.extend(old_text.lines().map(|line| format!("-{line}")));
  lines.extend(new_text.lines().map(|line| format!("+{line}")));

  if old_text.is_empty() && new_text.is_empty() {
    lines.push("(no textual changes provided)".to_string());
  }

  lines.join("\n")
}

fn normalize_diff_preview(diff: &str) -> String {
  let trimmed = diff.trim();
  if trimmed.is_empty() {
    return String::new();
  }

  let char_count = trimmed.chars().count();
  if char_count <= APPROVAL_DIFF_PREVIEW_MAX_CHARS {
    return trimmed.to_string();
  }

  let preview_len = APPROVAL_DIFF_PREVIEW_MAX_CHARS.saturating_sub(64);
  let preview: String = trimmed.chars().take(preview_len).collect();
  format!("{preview}\n... diff preview truncated ({char_count} chars total)")
}

fn diff_target_file(diff: &str) -> Option<String> {
  for line in diff.lines() {
    let Some(candidate) = line.strip_prefix("+++ ") else {
      continue;
    };
    let candidate = candidate.trim();
    if candidate.is_empty() || candidate == "/dev/null" {
      continue;
    }

    let normalized = candidate
      .strip_prefix("b/")
      .or_else(|| candidate.strip_prefix("a/"))
      .unwrap_or(candidate)
      .trim();

    if !normalized.is_empty() {
      return Some(normalized.to_string());
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
    ApprovalPreviewType::Diff => {
      let diff_lines = value.lines().count();
      if let Some(target_file) = diff_target_file(value) {
        let leaf = Path::new(target_file.as_str())
          .file_name()
          .and_then(|name| name.to_str())
          .unwrap_or(target_file.as_str());
        format!("{leaf} ({diff_lines} lines)")
      } else {
        format!("diff ({diff_lines} lines)")
      }
    }
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

fn flush_shell_segment(
  buffer: &mut String,
  segments: &mut Vec<ApprovalPreviewSegment>,
  pending_operator: &mut Option<String>,
) {
  let trimmed = buffer.trim();
  if trimmed.is_empty() {
    buffer.clear();
    return;
  }

  let leading_operator = if segments.is_empty() {
    None
  } else {
    pending_operator.clone()
  };
  segments.push(ApprovalPreviewSegment {
    command: trimmed.to_string(),
    leading_operator,
  });
  buffer.clear();
  *pending_operator = None;
}

pub(crate) fn shell_segments_for_preview(command: &str) -> Vec<ApprovalPreviewSegment> {
  let chars: Vec<char> = command.chars().collect();
  let mut segments: Vec<ApprovalPreviewSegment> = Vec::new();
  let mut buffer = String::new();
  let mut pending_operator: Option<String> = None;

  let mut in_single_quote = false;
  let mut in_double_quote = false;
  let mut in_backtick = false;
  let mut escaped = false;
  let mut paren_depth: usize = 0;
  let mut heredoc_delimiter: Option<String> = None;

  let mut index = 0;
  while index < chars.len() {
    let ch = chars[index];

    if let Some(ref delimiter) = heredoc_delimiter {
      buffer.push(ch);
      if ch == '\n' {
        let remaining: String = chars[index + 1..].iter().collect();
        let next_line = remaining.split('\n').next().unwrap_or("");
        if next_line.trim() == delimiter.as_str() {
          for &dc in &chars[index + 1..] {
            buffer.push(dc);
            if dc == '\n' {
              break;
            }
          }
          let delim_line_len = next_line.len();
          index += 1 + delim_line_len;
          if index < chars.len() && chars[index] == '\n' {
            index += 1;
          }
          heredoc_delimiter = None;
          flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
          pending_operator = Some(";".to_string());
          continue;
        }
      } else if index + 1 == chars.len() {
        heredoc_delimiter = None;
      }
      index += 1;
      continue;
    }

    if escaped {
      buffer.push(ch);
      escaped = false;
      index += 1;
      continue;
    }

    if ch == '\\' {
      if !in_single_quote {
        escaped = true;
      }
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_double_quote && !in_backtick && ch == '\'' {
      in_single_quote = !in_single_quote;
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_single_quote && !in_backtick && ch == '"' {
      in_double_quote = !in_double_quote;
      buffer.push(ch);
      index += 1;
      continue;
    }

    if !in_single_quote && !in_double_quote && ch == '`' {
      in_backtick = !in_backtick;
      buffer.push(ch);
      index += 1;
      continue;
    }

    let can_split = !in_single_quote && !in_double_quote && !in_backtick && paren_depth == 0;

    if !in_single_quote && !in_double_quote && !in_backtick {
      if ch == '(' {
        paren_depth += 1;
      } else if ch == ')' {
        paren_depth = paren_depth.saturating_sub(1);
      }
    }

    if can_split && ch == '<' && index + 1 < chars.len() && chars[index + 1] == '<' {
      buffer.push(ch);
      buffer.push(chars[index + 1]);
      let mut hd_index = index + 2;

      if hd_index < chars.len() && chars[hd_index] == '-' {
        buffer.push(chars[hd_index]);
        hd_index += 1;
      }

      while hd_index < chars.len() && chars[hd_index] == ' ' {
        buffer.push(chars[hd_index]);
        hd_index += 1;
      }

      let quote_char =
        if hd_index < chars.len() && (chars[hd_index] == '\'' || chars[hd_index] == '"') {
          let q = Some(chars[hd_index]);
          buffer.push(chars[hd_index]);
          hd_index += 1;
          q
        } else {
          None
        };

      let delim_start = hd_index;
      while hd_index < chars.len() {
        let c = chars[hd_index];
        if let Some(q) = quote_char {
          if c == q {
            break;
          }
        } else if !c.is_alphanumeric() && c != '_' {
          break;
        }
        buffer.push(c);
        hd_index += 1;
      }

      let delim: String = chars[delim_start..hd_index].iter().collect();

      if let Some(q) = quote_char {
        if hd_index < chars.len() && chars[hd_index] == q {
          buffer.push(chars[hd_index]);
          hd_index += 1;
        }
      }

      if !delim.is_empty() {
        heredoc_delimiter = Some(delim);
      }
      index = hd_index;
      continue;
    }

    if can_split {
      if ch == '|' {
        let is_double = (index + 1) < chars.len() && chars[index + 1] == '|';
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some(if is_double { "||" } else { "|" }.to_string());
        index += if is_double { 2 } else { 1 };
        continue;
      }

      if ch == '&' && (index + 1) < chars.len() && chars[index + 1] == '&' {
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some("&&".to_string());
        index += 2;
        continue;
      }

      if ch == ';' || ch == '\n' {
        flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
        pending_operator = Some(";".to_string());
        index += 1;
        continue;
      }
    }

    buffer.push(ch);
    index += 1;
  }

  flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
  segments
}
