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

  assert_eq!(
    result.matches("diff --git a/app.swift").count(),
    1,
    "expected single file header, got:\n{result}"
  );
  assert!(result.contains("@@ -1,3 +1,3 @@"), "missing turn 1 hunk");
  assert!(result.contains("@@ -10,2 +10,3 @@"), "missing turn 2 hunk");
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
  let current = "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -5,1 +5,2 @@\n ctx\n+added";

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
