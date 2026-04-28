use serde_json::{Map as JsonMap, Value as JsonValue};

use super::{trim_non_empty, trim_non_empty_str};

const APPROVAL_DIFF_PREVIEW_MAX_CHARS: usize = 12_000;

pub(super) fn diff_preview_from_patch_input(
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
    .or_else(|| trim_non_empty(fallback_file_path))
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

pub(super) fn normalize_diff_preview(diff: &str) -> String {
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

pub(super) fn diff_target_file(diff: &str) -> Option<String> {
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

pub(super) fn diff_manifest_lines(value: &str) -> Vec<String> {
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

pub(super) fn diff_compact_summary(value: &str) -> String {
  let diff_lines = value.lines().count();
  if let Some(target_file) = diff_target_file(value) {
    let leaf = std::path::Path::new(target_file.as_str())
      .file_name()
      .and_then(|name| name.to_str())
      .unwrap_or(target_file.as_str());
    format!("{leaf} ({diff_lines} lines)")
  } else {
    format!("diff ({diff_lines} lines)")
  }
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
