use crate::domain_events::ToolKind;

use super::tool_display_shared::{joined_preview_text, preview_lines_from_text, truncate};
use super::{DiffLine, DiffLineKind, ToolDiffPreview};

const DIFF_PREVIEW_MAX_LINES: usize = 4;
const DIFF_PREVIEW_MAX_CHARS: usize = 120;

pub(super) fn compute_diff_preview(
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

  let old_string = input.get("old_string").and_then(|value| value.as_str());
  let new_string = input.get("new_string").and_then(|value| value.as_str());

  match (old_string, new_string) {
    (Some(old), Some(new)) => {
      let additions = new.lines().count() as u32;
      let deletions = old.lines().count() as u32;
      let is_addition = deletions == 0 || additions >= deletions;
      let preview_lines = if is_addition {
        preview_lines_from_text(new, DIFF_PREVIEW_MAX_LINES, DIFF_PREVIEW_MAX_CHARS)
      } else {
        preview_lines_from_text(old, DIFF_PREVIEW_MAX_LINES, DIFF_PREVIEW_MAX_CHARS)
      };
      let snippet = if is_addition {
        new.lines().next().unwrap_or("")
      } else {
        old.lines().next().unwrap_or("")
      };
      let prefix = if is_addition { "+" } else { "-" };
      Some(ToolDiffPreview {
        context_line: None,
        snippet_text: joined_preview_text(&preview_lines, snippet, 240),
        preview_lines,
        snippet_prefix: prefix.to_string(),
        is_addition,
        additions,
        deletions,
      })
    }
    _ => {
      if let Some(content) = input.get("content").and_then(|value| value.as_str()) {
        let lines = content.lines().count() as u32;
        let preview_lines =
          preview_lines_from_text(content, DIFF_PREVIEW_MAX_LINES, DIFF_PREVIEW_MAX_CHARS);
        let first_line = content.lines().next().unwrap_or("");
        return Some(ToolDiffPreview {
          context_line: None,
          snippet_text: joined_preview_text(&preview_lines, first_line, 240),
          preview_lines,
          snippet_prefix: "+".to_string(),
          is_addition: true,
          additions: lines,
          deletions: 0,
        });
      }

      let diff_str = input
        .get("unified_diff")
        .or_else(|| input.get("diff"))
        .and_then(|value| value.as_str())
        .filter(|value| !value.is_empty())?;
      let parsed = parse_unified_diff_string(diff_str);
      if parsed.is_empty() {
        return None;
      }

      let additions = parsed
        .iter()
        .filter(|line| line.kind == DiffLineKind::Addition)
        .count() as u32;
      let deletions = parsed
        .iter()
        .filter(|line| line.kind == DiffLineKind::Deletion)
        .count() as u32;
      let is_addition = additions > 0 || deletions == 0;
      let preview_lines = preview_lines_from_diff_lines(&parsed, is_addition);
      let snippet = preview_lines.first().map(String::as_str).unwrap_or("");
      let prefix = if is_addition { "+" } else { "-" };
      Some(ToolDiffPreview {
        context_line: None,
        snippet_text: joined_preview_text(&preview_lines, snippet, 240),
        preview_lines,
        snippet_prefix: prefix.to_string(),
        is_addition,
        additions,
        deletions,
      })
    }
  }
}

fn preview_lines_from_diff_lines(lines: &[DiffLine], prefer_additions: bool) -> Vec<String> {
  let preferred_kind = if prefer_additions {
    DiffLineKind::Addition
  } else {
    DiffLineKind::Deletion
  };

  let mut preview_lines = consecutive_preview_lines(lines, preferred_kind);
  if preview_lines.is_empty() {
    let fallback_kind = if prefer_additions {
      DiffLineKind::Deletion
    } else {
      DiffLineKind::Addition
    };
    preview_lines = consecutive_preview_lines(lines, fallback_kind);
  }
  preview_lines
}

fn consecutive_preview_lines(lines: &[DiffLine], kind: DiffLineKind) -> Vec<String> {
  let Some(start_index) = lines.iter().position(|line| line.kind == kind) else {
    return Vec::new();
  };

  lines[start_index..]
    .iter()
    .take_while(|line| line.kind == kind)
    .map(|line| truncate(&line.content, DIFF_PREVIEW_MAX_CHARS))
    .filter(|line| !line.trim().is_empty())
    .take(DIFF_PREVIEW_MAX_LINES)
    .collect()
}

pub fn compute_expanded_output(kind: ToolKind, result_output: Option<&str>) -> Option<String> {
  let output = result_output?;
  if output.is_empty() {
    return None;
  }

  if kind == ToolKind::Read {
    return Some(strip_cat_n_prefixes(output));
  }

  if kind == ToolKind::GuardianAssessment {
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(output) {
      let mut parts = Vec::new();

      if let Some(status) = parsed.get("status_label").and_then(|value| value.as_str()) {
        parts.push(format!("Verdict: {status}"));
      }
      if let Some(level) = parsed.get("risk_level").and_then(|value| value.as_str()) {
        let score_part = parsed
          .get("risk_score")
          .and_then(|value| value.as_u64())
          .map(|score| format!(" ({score}/100)"))
          .unwrap_or_default();
        parts.push(format!("Risk: {level}{score_part}"));
      }
      if let Some(rationale) = parsed.get("rationale").and_then(|value| value.as_str()) {
        parts.push(format!("Rationale: {rationale}"));
      }
      if !parts.is_empty() {
        return Some(parts.join("\n"));
      }
    }
    return Some(output.to_string());
  }

  Some(output.to_string())
}

pub fn extract_start_line(kind: ToolKind, result_output: Option<&str>) -> Option<u32> {
  if kind != ToolKind::Read {
    return None;
  }
  let output = result_output?;
  let first_line = output.lines().next()?;
  parse_cat_n_line_number(first_line)
}

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

  if let Some(diff_str) = input
    .get("unified_diff")
    .or_else(|| input.get("diff"))
    .and_then(|value| value.as_str())
  {
    if !diff_str.is_empty() {
      return Some(parse_unified_diff_string(diff_str));
    }
  }

  let old_string = input.get("old_string").and_then(|value| value.as_str());
  let new_string = input.get("new_string").and_then(|value| value.as_str());

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
      let content = input.get("content").and_then(|value| value.as_str())?;
      let lines: Vec<DiffLine> = content
        .lines()
        .enumerate()
        .map(|(index, line)| DiffLine {
          kind: DiffLineKind::Addition,
          old_line: None,
          new_line: Some((index + 1) as u32),
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

fn compute_similar_diff(old: &str, new: &str) -> Vec<DiffLine> {
  use similar::{ChangeTag, TextDiff};

  let text_diff = TextDiff::from_lines(old, new);
  let mut lines = Vec::new();

  for change in text_diff.iter_all_changes() {
    let content = change.value().trim_end_matches('\n').to_string();
    match change.tag() {
      ChangeTag::Equal => lines.push(DiffLine {
        kind: DiffLineKind::Context,
        old_line: change.old_index().map(|index| (index + 1) as u32),
        new_line: change.new_index().map(|index| (index + 1) as u32),
        content,
      }),
      ChangeTag::Delete => lines.push(DiffLine {
        kind: DiffLineKind::Deletion,
        old_line: change.old_index().map(|index| (index + 1) as u32),
        new_line: None,
        content,
      }),
      ChangeTag::Insert => lines.push(DiffLine {
        kind: DiffLineKind::Addition,
        old_line: None,
        new_line: change.new_index().map(|index| (index + 1) as u32),
        content,
      }),
    }
  }

  lines
}

fn parse_unified_diff_string(diff: &str) -> Vec<DiffLine> {
  let mut lines = Vec::new();
  let mut old_line = 1;
  let mut new_line = 1;

  for raw in diff.lines() {
    if raw.starts_with("@@") {
      if let Some((parsed_old, parsed_new)) = parse_hunk_header(raw) {
        old_line = parsed_old;
        new_line = parsed_new;
      }
      continue;
    }
    if raw.starts_with("---") || raw.starts_with("+++") {
      continue;
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

fn strip_cat_n_prefixes(output: &str) -> String {
  let lines: Vec<&str> = output.lines().collect();
  if !has_consecutive_line_numbers(&lines) {
    return output.to_string();
  }
  lines
    .iter()
    .map(|line| {
      split_line_number(line)
        .map(|(_, content)| content)
        .unwrap_or(*line)
    })
    .collect::<Vec<_>>()
    .join("\n")
}

fn parse_cat_n_line_number(line: &str) -> Option<u32> {
  split_line_number(line).map(|(number, _)| number)
}

fn has_consecutive_line_numbers(lines: &[&str]) -> bool {
  let mut prev_num = None;
  let mut consecutive_count = 0;

  for line in lines.iter().take(10) {
    if line.trim().is_empty() {
      continue;
    }
    match split_line_number(line) {
      Some((number, _)) => {
        if let Some(prev) = prev_num {
          if number == prev + 1 {
            consecutive_count += 1;
            if consecutive_count >= 2 {
              return true;
            }
          } else {
            return false;
          }
        }
        prev_num = Some(number);
      }
      None => return false,
    }
  }

  consecutive_count >= 2
}

pub(super) fn split_line_number(line: &str) -> Option<(u32, &str)> {
  let trimmed = line.trim_start();
  if trimmed.is_empty() {
    return None;
  }

  let digit_end = trimmed.find(|c: char| !c.is_ascii_digit()).unwrap_or(0);
  if digit_end == 0 {
    return None;
  }

  let number: u32 = trimmed[..digit_end].parse().ok()?;
  let rest = &trimmed[digit_end..];
  let separator = rest.chars().next()?;
  if separator.is_alphanumeric() || separator == ' ' {
    return None;
  }

  let content_start = separator.len_utf8();
  Some((number, &rest[content_start..]))
}
