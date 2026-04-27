use super::*;

fn turn_diff(turn_id: &str, diff: &str) -> TurnDiff {
  TurnDiff {
    turn_id: turn_id.to_string(),
    diff: diff.to_string(),
    token_usage: None,
    snapshot_kind: None,
  }
}

#[test]
fn builds_preview_from_archived_turn_diffs() {
  let preview = build_dashboard_diff_preview(
    None,
    &[turn_diff(
      "turn-1",
      "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -1,2 +1,3 @@\n-old\n+new\n+extra",
    )],
  )
  .expect("archived diff should produce preview");

  assert_eq!(preview.file_count, 1);
  assert_eq!(preview.additions, 2);
  assert_eq!(preview.deletions, 1);
  assert_eq!(preview.file_paths, vec!["app.rs"]);
}

#[test]
fn combines_archived_and_current_diff_preview() {
  let preview = build_dashboard_diff_preview(
    Some(
      "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -8,1 +8,2 @@\n ctx\n+current",
    ),
    &[turn_diff(
      "turn-1",
      "diff --git a/lib.rs b/lib.rs\n--- a/lib.rs\n+++ b/lib.rs\n@@ -1,1 +1,1 @@\n-old\n+new",
    )],
  )
  .expect("combined diffs should produce preview");

  assert_eq!(preview.file_count, 2);
  assert_eq!(preview.additions, 2);
  assert_eq!(preview.deletions, 1);
  assert_eq!(preview.file_paths, vec!["lib.rs", "app.rs"]);
}

#[test]
fn deduplicates_paths_across_turns() {
  let preview = build_dashboard_diff_preview(
    None,
    &[
      turn_diff(
        "turn-1",
        "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -1,1 +1,1 @@\n-a\n+b",
      ),
      turn_diff(
        "turn-2",
        "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -4,1 +4,2 @@\n ctx\n+c",
      ),
    ],
  )
  .expect("duplicate path diff should produce preview");

  assert_eq!(preview.file_count, 1);
  assert_eq!(preview.file_paths, vec!["app.rs"]);
  assert_eq!(preview.additions, 2);
  assert_eq!(preview.deletions, 1);
}

#[test]
fn ignores_empty_diffs() {
  assert!(build_dashboard_diff_preview(Some(" \n"), &[]).is_none());
}
