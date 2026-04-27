use super::*;

fn test_context(root: &std::path::Path) -> CodexWorkspaceToolContext {
  CodexWorkspaceToolContext {
    project_path: root.to_string_lossy().to_string(),
    current_cwd: None,
  }
}

#[test]
fn dynamic_tool_specs_include_workspace_tools() {
  let specs = codex_workspace_dynamic_tool_specs();
  let names: Vec<String> = specs.into_iter().map(|spec| spec.name).collect();
  assert_eq!(
    names,
    vec!["file_read", "file_write", "file_edit", "plan_write"]
  );
}

#[test]
fn default_workspace_tools_are_appended_when_missing() {
  let merged = with_default_codex_workspace_tools(Vec::new());
  let names: Vec<String> = merged.into_iter().map(|spec| spec.name).collect();
  assert_eq!(
    names,
    vec!["file_read", "file_write", "file_edit", "plan_write"]
  );
}

#[test]
fn default_workspace_tools_json_contains_all_workspace_tools() {
  let tools = default_codex_dynamic_tools_json(false);
  let names: Vec<String> = tools
    .iter()
    .filter_map(|tool| tool.get("name").and_then(Value::as_str))
    .map(ToOwned::to_owned)
    .collect();
  assert_eq!(
    names,
    vec!["file_read", "file_write", "file_edit", "plan_write"]
  );
}

#[test]
fn has_mission_context_requires_both_values() {
  assert!(!has_mission_context(None, None));
  assert!(!has_mission_context(Some("mission-1"), None));
  assert!(!has_mission_context(None, Some("ISSUE-1")));
  assert!(!has_mission_context(Some(" "), Some("ISSUE-1")));
  assert!(has_mission_context(Some("mission-1"), Some("ISSUE-1")));
}

#[test]
fn default_dynamic_tools_include_mission_tools_when_requested() {
  let tools = default_codex_dynamic_tools_json(true);
  let names: Vec<String> = tools
    .iter()
    .filter_map(|tool| tool.get("name").and_then(Value::as_str))
    .map(ToOwned::to_owned)
    .collect();

  assert!(names.contains(&"file_read".to_string()));
  assert!(names.contains(&"mission_get_issue".to_string()));
}

#[test]
fn default_workspace_tools_do_not_duplicate_existing_names() {
  let merged = with_default_codex_workspace_tools(vec![DynamicToolSpec {
    name: "file_read".to_string(),
    namespace: None,
    description: "custom read".to_string(),
    input_schema: json!({
      "type": "object",
      "required": ["path"],
      "properties": { "path": { "type": "string" } },
      "additionalProperties": false
    }),
    defer_loading: false,
  }]);
  let names: Vec<&str> = merged.iter().map(|tool| tool.name.as_str()).collect();
  assert_eq!(
    names,
    vec!["file_read", "file_write", "file_edit", "plan_write"]
  );
  assert_eq!(merged[0].description, "custom read");
}

#[test]
fn file_write_and_read_round_trip() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let target = temp.path().join("note.txt");
  let target_str = target.to_string_lossy().to_string();

  let write = execute_codex_workspace_tool(
    &ctx,
    "file_write",
    json!({ "path": target_str, "content": "hello world" }),
  )
  .expect("file_write tool result");
  assert!(write.success);

  let read = execute_codex_workspace_tool(&ctx, "file_read", json!({ "path": target_str }))
    .expect("file_read tool result");
  assert!(read.success);
  let payload: Value = serde_json::from_str(&read.output).expect("read output json");
  assert_eq!(payload["content"], "hello world");
}

#[test]
fn file_edit_requires_unique_match_by_default() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let target = temp.path().join("note.txt");
  fs::write(&target, "x x").expect("seed file");

  let result = execute_codex_workspace_tool(
    &ctx,
    "file_edit",
    json!({
      "path": target.to_string_lossy().to_string(),
      "old_string": "x",
      "new_string": "y"
    }),
  )
  .expect("file_edit tool result");
  assert!(!result.success);
  assert!(result.output.contains("must be unique"));
}

#[test]
fn file_edit_replace_all_updates_every_match() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let target = temp.path().join("note.txt");
  fs::write(&target, "x x").expect("seed file");

  let result = execute_codex_workspace_tool(
    &ctx,
    "file_edit",
    json!({
      "path": target.to_string_lossy().to_string(),
      "old_string": "x",
      "new_string": "y",
      "replace_all": true
    }),
  )
  .expect("file_edit tool result");
  assert!(result.success);
  let final_content = fs::read_to_string(&target).expect("read final file");
  assert_eq!(final_content, "y y");
}

#[test]
fn file_tools_reject_paths_outside_project() {
  let root = tempfile::tempdir().expect("tempdir");
  let outside = tempfile::tempdir().expect("outside");
  let outside_file = outside.path().join("outside.txt");
  fs::write(&outside_file, "outside").expect("outside file");
  let ctx = test_context(root.path());

  let read = execute_codex_workspace_tool(
    &ctx,
    "file_read",
    json!({ "path": outside_file.to_string_lossy().to_string() }),
  )
  .expect("file_read tool result");
  assert!(!read.success);
  assert!(read.output.contains("escapes project root"));
}

#[test]
fn plan_write_writes_markdown_within_plans_directory() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let result = execute_codex_workspace_tool(
    &ctx,
    "plan_write",
    json!({
      "path": "roadmaps/plan-write.md",
      "content": "# Plan Write\n\n- [ ] Implement tool\n"
    }),
  )
  .expect("plan_write tool result");
  assert!(result.success);

  let payload: Value = serde_json::from_str(&result.output).expect("plan output json");
  assert_eq!(payload["plan_written"], true);
  let path = payload["path"].as_str().expect("plan path");
  assert!(path.ends_with("plans/roadmaps/plan-write.md"));
  let written = fs::read_to_string(path).expect("read plan file");
  assert!(written.contains("# Plan Write"));
}

#[test]
fn plan_write_rejects_paths_outside_plans_directory() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let result = execute_codex_workspace_tool(
    &ctx,
    "plan_write",
    json!({
      "path": "../outside.md",
      "content": "oops"
    }),
  )
  .expect("plan_write tool result");
  assert!(!result.success);
  assert!(result.output.contains("must not contain '..'"));
}

#[test]
fn plan_write_requires_overwrite_to_replace_existing_file() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let plans = temp.path().join("plans");
  fs::create_dir_all(&plans).expect("create plans");
  let target = plans.join("existing.md");
  fs::write(&target, "initial").expect("seed existing plan");

  let denied = execute_codex_workspace_tool(
    &ctx,
    "plan_write",
    json!({
      "path": "existing.md",
      "content": "next"
    }),
  )
  .expect("plan_write tool result");
  assert!(!denied.success);
  assert!(denied.output.contains("overwrite=true"));

  let allowed = execute_codex_workspace_tool(
    &ctx,
    "plan_write",
    json!({
      "path": "existing.md",
      "content": "next",
      "overwrite": true
    }),
  )
  .expect("plan_write overwrite result");
  assert!(allowed.success);
  let final_content = fs::read_to_string(target).expect("read overwritten plan");
  assert_eq!(final_content, "next");
}

#[cfg(unix)]
#[test]
fn plan_write_rejects_symlinked_plans_root_outside_project() {
  use std::os::unix::fs::symlink;

  let project = tempfile::tempdir().expect("tempdir");
  let outside = tempfile::tempdir().expect("outside");
  let linked_plans_root = project.path().join("plans");
  symlink(outside.path(), &linked_plans_root).expect("create plans symlink");

  let ctx = test_context(project.path());
  let result = execute_codex_workspace_tool(
    &ctx,
    "plan_write",
    json!({
      "path": "escaped.md",
      "content": "# Escaped"
    }),
  )
  .expect("plan_write tool result");

  assert!(!result.success);
  assert!(result
    .output
    .contains("plans directory must resolve within project root"));
  assert!(
    !outside.path().join("escaped.md").exists(),
    "plan file must not be written outside the project root"
  );
}

#[test]
fn file_read_handles_multibyte_boundary_when_truncated() {
  let temp = tempfile::tempdir().expect("tempdir");
  let ctx = test_context(temp.path());
  let target = temp.path().join("utf8-boundary.txt");
  let content = format!("{}éz", "a".repeat(MAX_FILE_READ_BYTES - 1));
  fs::write(&target, content).expect("seed file");

  let read = execute_codex_workspace_tool(
    &ctx,
    "file_read",
    json!({ "path": target.to_string_lossy().to_string() }),
  )
  .expect("file_read tool result");
  assert!(read.success);

  let payload: Value = serde_json::from_str(&read.output).expect("read output json");
  assert_eq!(payload["truncated"], true);
  let rendered = payload
    .get("content")
    .and_then(Value::as_str)
    .expect("content string");
  assert_eq!(rendered.len(), MAX_FILE_READ_BYTES - 1);
  assert!(rendered.chars().all(|ch| ch == 'a'));
}

#[test]
fn file_read_only_reads_prefix_budget() {
  let temp = tempfile::tempdir().expect("tempdir");
  let target = temp.path().join("large.txt");
  let content = "a".repeat(MAX_FILE_READ_BYTES + 1024);
  fs::write(&target, content).expect("seed file");

  let bytes = read_file_prefix_bytes(&target, MAX_FILE_READ_BYTES).expect("prefix read");
  assert_eq!(bytes.len(), MAX_FILE_READ_BYTES + 1);
}
