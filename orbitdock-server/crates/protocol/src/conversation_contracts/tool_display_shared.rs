pub(super) fn truncate(s: &str, max_chars: usize) -> String {
  if s.chars().count() <= max_chars {
    return s.to_string();
  }
  let truncated: String = s.chars().take(max_chars).collect();
  format!("{truncated}…")
}

pub(super) fn preview_lines_from_text(
  text: &str,
  max_lines: usize,
  max_chars: usize,
) -> Vec<String> {
  text
    .lines()
    .map(|line| truncate(line, max_chars))
    .filter(|line| !line.trim().is_empty())
    .take(max_lines)
    .collect()
}

pub(super) fn joined_preview_text(lines: &[String], fallback: &str, max_chars: usize) -> String {
  if lines.is_empty() {
    truncate(fallback, max_chars)
  } else {
    lines.join("\n")
  }
}
