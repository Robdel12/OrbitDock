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
mod tests {
    use super::*;

    fn make_turn_diff(turn_id: &str, diff: &str) -> TurnDiff {
        TurnDiff {
            turn_id: turn_id.to_string(),
            diff: diff.to_string(),
            token_usage: None,
            snapshot_kind: None,
        }
    }

    #[test]
    fn merges_same_file_across_turns() {
        let turn1 = make_turn_diff(
            "t1",
            "diff --git a/app.swift b/app.swift\n--- a/app.swift\n+++ b/app.swift\n@@ -1,3 +1,3 @@\n let a = 1\n-let b = 2\n+let b = 42\n let c = 3",
        );
        let turn2 = make_turn_diff(
            "t2",
            "diff --git a/app.swift b/app.swift\n--- a/app.swift\n+++ b/app.swift\n@@ -10,2 +10,3 @@\n let x = 10\n+let y = 11\n let z = 12",
        );

        let result = compute_cumulative_diff(&[turn1, turn2], None).unwrap();

        // Should contain one "diff --git" header for app.swift
        assert_eq!(
            result.matches("diff --git a/app.swift").count(),
            1,
            "expected single file header, got:\n{result}"
        );

        // Should contain both hunks
        assert!(result.contains("@@ -1,3 +1,3 @@"), "missing turn 1 hunk");
        assert!(result.contains("@@ -10,2 +10,3 @@"), "missing turn 2 hunk");

        // Should contain changes from both turns
        assert!(result.contains("+let b = 42"));
        assert!(result.contains("+let y = 11"));
    }

    #[test]
    fn keeps_different_files_separate() {
        let turn1 = make_turn_diff(
            "t1",
            "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1,1 +1,1 @@\n-old\n+new",
        );
        let turn2 = make_turn_diff(
            "t2",
            "diff --git a/b.rs b/b.rs\n--- a/b.rs\n+++ b/b.rs\n@@ -1,1 +1,1 @@\n-old\n+new",
        );

        let result = compute_cumulative_diff(&[turn1, turn2], None).unwrap();
        assert!(result.contains("diff --git a/a.rs"));
        assert!(result.contains("diff --git a/b.rs"));
    }

    #[test]
    fn includes_current_diff() {
        let turn1 = make_turn_diff(
            "t1",
            "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1,1 +1,1 @@\n-old\n+new",
        );
        let current =
            "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -5,1 +5,2 @@\n ctx\n+added";

        let result = compute_cumulative_diff(&[turn1], Some(current)).unwrap();
        assert_eq!(result.matches("diff --git a/a.rs").count(), 1);
        assert!(result.contains("+new"));
        assert!(result.contains("+added"));
    }

    #[test]
    fn returns_none_for_empty() {
        assert!(compute_cumulative_diff(&[], None).is_none());
        assert!(compute_cumulative_diff(&[], Some("")).is_none());
    }

    #[test]
    fn handles_interleaved_files() {
        let turn1 = make_turn_diff(
            "t1",
            "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1,1 +1,1 @@\n-a1\n+a2\ndiff --git a/b.rs b/b.rs\n--- a/b.rs\n+++ b/b.rs\n@@ -1,1 +1,1 @@\n-b1\n+b2",
        );
        let turn2 = make_turn_diff(
            "t2",
            "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -10,1 +10,2 @@\n ctx\n+a3",
        );

        let result = compute_cumulative_diff(&[turn1, turn2], None).unwrap();
        assert_eq!(result.matches("diff --git a/a.rs").count(), 1);
        assert_eq!(result.matches("diff --git a/b.rs").count(), 1);
        assert!(result.contains("+a2"));
        assert!(result.contains("+a3"));
        assert!(result.contains("+b2"));
    }
}
