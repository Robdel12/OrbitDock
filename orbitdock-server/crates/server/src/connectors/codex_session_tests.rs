use std::fs;

use super::*;
use serde_json::json;

#[test]
fn dynamic_workspace_tracker_renders_diff_for_existing_file_write() {
  let temp = tempfile::tempdir().expect("tempdir");
  let root = temp.path();
  let target = root.join("note.txt");
  fs::write(&target, "before\n").expect("seed file");

  let ctx = CodexWorkspaceToolContext {
    project_path: root.to_string_lossy().to_string(),
    current_cwd: None,
  };
  let mut tracker = DynamicWorkspaceDiffTracker::default();
  tracker.capture_baseline_if_workspace_file_tool(
    &ctx,
    "file_write",
    &json!({
      "path": "note.txt",
      "content": "after\n",
    }),
  );

  fs::write(&target, "after\n").expect("update file");

  let diff = tracker.render_unified_diff(&ctx).expect("diff");
  assert!(diff.contains("diff --git a/note.txt b/note.txt"));
  assert!(diff.contains("-before"));
  assert!(diff.contains("+after"));
}

#[test]
fn dynamic_workspace_tracker_renders_addition_for_new_file() {
  let temp = tempfile::tempdir().expect("tempdir");
  let root = temp.path();
  let target = root.join("new.txt");

  let ctx = CodexWorkspaceToolContext {
    project_path: root.to_string_lossy().to_string(),
    current_cwd: None,
  };
  let mut tracker = DynamicWorkspaceDiffTracker::default();
  tracker.capture_baseline_if_workspace_file_tool(
    &ctx,
    "file_write",
    &json!({
      "path": "new.txt",
      "content": "hello\n",
    }),
  );

  fs::write(&target, "hello\n").expect("write file");

  let diff = tracker.render_unified_diff(&ctx).expect("diff");
  assert!(diff.contains("diff --git a/new.txt b/new.txt"));
  assert!(diff.contains("--- /dev/null"));
  assert!(diff.contains("+++ b/new.txt"));
  assert!(diff.contains("+hello"));
}

#[test]
fn resolve_dynamic_tool_path_rejects_project_escape() {
  let temp = tempfile::tempdir().expect("tempdir");
  let root = temp.path();
  let ctx = CodexWorkspaceToolContext {
    project_path: root.to_string_lossy().to_string(),
    current_cwd: None,
  };

  let resolved = resolve_dynamic_tool_path(&ctx, &json!({ "path": "../outside.txt" }));
  assert!(resolved.is_none());
}

#[test]
fn dynamic_workspace_tracker_keeps_full_diff_content() {
  let temp = tempfile::tempdir().expect("tempdir");
  let root = temp.path();
  let target = root.join("big.txt");
  let before = "a\n".repeat(5_000);
  let after = "b\n".repeat(5_000);
  fs::write(&target, &before).expect("seed file");

  let ctx = CodexWorkspaceToolContext {
    project_path: root.to_string_lossy().to_string(),
    current_cwd: None,
  };
  let mut tracker = DynamicWorkspaceDiffTracker::default();
  tracker.capture_baseline_if_workspace_file_tool(
    &ctx,
    "file_write",
    &json!({
      "path": "big.txt",
      "content": after,
    }),
  );

  fs::write(&target, &after).expect("update file");
  let diff = tracker.render_unified_diff(&ctx).expect("diff");
  assert!(!diff.contains("dynamic turn diff truncated"));
  assert!(diff.contains("diff --git a/big.txt b/big.txt"));
}
