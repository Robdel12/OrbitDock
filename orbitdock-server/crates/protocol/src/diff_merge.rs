//! Cumulative diff computation.
//!
//! Merges per-turn unified diffs into a single diff where each file appears
//! exactly once, with hunks from all turns concatenated in order.

use crate::TurnDiff;
use std::collections::HashMap;

/// Build a cumulative diff from completed turn diffs and an optional in-progress
/// current diff.  Same-file hunks are merged under a single file header so
/// clients receive a clean unified diff without duplicate file entries.
pub fn compute_cumulative_diff(
  turn_diffs: &[TurnDiff],
  current_diff: Option<&str>,
) -> Option<String> {
  let mut parts: Vec<&str> = turn_diffs.iter().map(|td| td.diff.as_str()).collect();
  if let Some(cd) = current_diff {
    if !cd.is_empty() {
      parts.push(cd);
    }
  }

  if parts.is_empty() {
    return None;
  }

  let combined = parts.join("\n");
  if combined.trim().is_empty() {
    return None;
  }

  // Split into per-file chunks by "diff --git" boundaries
  let chunks = split_into_file_chunks(&combined);
  if chunks.is_empty() {
    return Some(combined);
  }

  // Group by file path, merging hunks for repeated files
  let mut seen: HashMap<String, usize> = HashMap::new();
  let mut merged: Vec<String> = Vec::new();

  for chunk in &chunks {
    let path = extract_file_path(chunk);
    if let Some(&idx) = seen.get(&path) {
      // Append only the hunk content (@@ lines and their content)
      let hunk_content = extract_hunk_content(chunk);
      if !hunk_content.is_empty() {
        merged[idx].push('\n');
        merged[idx].push_str(&hunk_content);
      }
    } else {
      seen.insert(path, merged.len());
      merged.push(chunk.to_string());
    }
  }

  let result = merged.join("\n");
  if result.trim().is_empty() {
    None
  } else {
    Some(result)
  }
}

/// Split a unified diff into per-file chunks at `diff --git` boundaries.
fn split_into_file_chunks(diff: &str) -> Vec<String> {
  let mut chunks: Vec<String> = Vec::new();
  let mut current_lines: Vec<&str> = Vec::new();

  for line in diff.lines() {
    if line.starts_with("diff --git ") {
      if !current_lines.is_empty() {
        chunks.push(current_lines.join("\n"));
      }
      current_lines = vec![line];
    } else {
      current_lines.push(line);
    }
  }

  if !current_lines.is_empty() {
    chunks.push(current_lines.join("\n"));
  }

  chunks
}

/// Extract the file path from a diff chunk (prefers +++ line, falls back to
/// diff --git header).
fn extract_file_path(chunk: &str) -> String {
  for line in chunk.lines() {
    if let Some(path) = line.strip_prefix("+++ ") {
      let path = if path == "/dev/null" {
        // For deletions, use the --- line instead
        continue;
      } else {
        path
      };
      return path.strip_prefix("b/").unwrap_or(path).to_string();
    }
  }

  // Fallback: parse "diff --git a/path b/path"
  if let Some(first_line) = chunk.lines().next() {
    if let Some(rest) = first_line.strip_prefix("diff --git ") {
      let parts: Vec<&str> = rest.split(' ').collect();
      if parts.len() >= 2 {
        let b_path = parts[parts.len() - 1];
        return b_path.strip_prefix("b/").unwrap_or(b_path).to_string();
      }
    }
  }

  "unknown".to_string()
}

/// Extract hunk content from a chunk — everything from the first `@@` line
/// onwards, skipping file-level headers.
fn extract_hunk_content(chunk: &str) -> String {
  let mut lines: Vec<&str> = Vec::new();
  let mut in_hunks = false;

  for line in chunk.lines() {
    if line.starts_with("@@ ") {
      in_hunks = true;
    }
    if in_hunks {
      lines.push(line);
    }
  }

  lines.join("\n")
}

#[cfg(test)]
#[path = "diff_merge_tests.rs"]
mod tests;
