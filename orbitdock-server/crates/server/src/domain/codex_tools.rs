//! Codex-oriented workspace tools exposed as dynamic tools for direct sessions.

use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use codex_protocol::dynamic_tools::DynamicToolSpec;
use serde_json::{json, Value};

const MAX_FILE_READ_BYTES: usize = 512 * 1024;

#[derive(Debug, Clone)]
pub struct CodexWorkspaceToolDef {
  pub name: String,
  pub description: String,
  pub input_schema: Value,
}

#[derive(Debug, Clone)]
pub struct CodexWorkspaceToolContext {
  pub project_path: String,
  pub current_cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CodexWorkspaceToolResult {
  pub success: bool,
  pub output: String,
}

pub fn codex_workspace_tool_definitions() -> Vec<CodexWorkspaceToolDef> {
  vec![
    CodexWorkspaceToolDef {
      name: "file_read".to_string(),
      description: "Read a UTF-8 text file within the current project.".to_string(),
      input_schema: json!({
        "type": "object",
        "required": ["path"],
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative path to the file."
          }
        },
        "additionalProperties": false
      }),
    },
    CodexWorkspaceToolDef {
      name: "file_write".to_string(),
      description: "Write UTF-8 text content to a file within the current project.".to_string(),
      input_schema: json!({
        "type": "object",
        "required": ["path", "content"],
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative path to the target file."
          },
          "content": {
            "type": "string",
            "description": "Entire file contents to write."
          }
        },
        "additionalProperties": false
      }),
    },
    CodexWorkspaceToolDef {
      name: "file_edit".to_string(),
      description: "Edit a file by replacing exact text matches.".to_string(),
      input_schema: json!({
        "type": "object",
        "required": ["path", "old_string", "new_string"],
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute or relative path to the target file."
          },
          "old_string": {
            "type": "string",
            "description": "Exact text to find."
          },
          "new_string": {
            "type": "string",
            "description": "Replacement text."
          },
          "replace_all": {
            "type": "boolean",
            "description": "When true, replace every occurrence. When false, require a unique match."
          }
        },
        "additionalProperties": false
      }),
    },
    CodexWorkspaceToolDef {
      name: "plan_write".to_string(),
      description: "Write markdown plan content to a file under plans/.".to_string(),
      input_schema: json!({
        "type": "object",
        "required": ["path", "content"],
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative path under plans/, or absolute path within plans/."
          },
          "content": {
            "type": "string",
            "description": "Full markdown content for the plan document."
          },
          "overwrite": {
            "type": "boolean",
            "description": "When true, overwrite an existing file. Defaults to false."
          }
        },
        "additionalProperties": false
      }),
    },
  ]
}

pub fn codex_workspace_dynamic_tool_specs() -> Vec<DynamicToolSpec> {
  codex_workspace_tool_definitions()
    .into_iter()
    .map(|tool| DynamicToolSpec {
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema,
      defer_loading: false,
    })
    .collect()
}

pub fn has_mission_context(mission_id: Option<&str>, issue_identifier: Option<&str>) -> bool {
  mission_id.is_some_and(|value| !value.trim().is_empty())
    && issue_identifier.is_some_and(|value| !value.trim().is_empty())
}

pub fn default_codex_dynamic_tool_specs(include_mission_tools: bool) -> Vec<DynamicToolSpec> {
  let mut tools = with_default_codex_workspace_tools(Vec::new());
  if include_mission_tools {
    tools.extend(
      crate::domain::mission_control::tools::mission_tool_definitions()
        .into_iter()
        .map(|tool| DynamicToolSpec {
          name: tool.name,
          description: tool.description,
          input_schema: tool.input_schema,
          defer_loading: false,
        }),
    );
  }
  tools
}

pub fn default_codex_dynamic_tools_json(include_mission_tools: bool) -> Vec<Value> {
  default_codex_dynamic_tool_specs(include_mission_tools)
    .into_iter()
    .filter_map(|tool| serde_json::to_value(tool).ok())
    .collect()
}

/// Ensure Codex workspace tools are always present while preserving caller-provided
/// tool definitions for matching names.
pub fn with_default_codex_workspace_tools(mut tools: Vec<DynamicToolSpec>) -> Vec<DynamicToolSpec> {
  let mut seen: HashSet<String> = tools.iter().map(|tool| tool.name.clone()).collect();
  for default_tool in codex_workspace_dynamic_tool_specs() {
    if seen.insert(default_tool.name.clone()) {
      tools.push(default_tool);
    }
  }
  tools
}

pub fn execute_codex_workspace_tool(
  ctx: &CodexWorkspaceToolContext,
  tool_name: &str,
  arguments: Value,
) -> Option<CodexWorkspaceToolResult> {
  let result = match tool_name {
    "file_read" => exec_file_read(ctx, &arguments),
    "file_write" => exec_file_write(ctx, &arguments),
    "file_edit" => exec_file_edit(ctx, &arguments),
    "plan_write" => exec_plan_write(ctx, &arguments),
    _ => return None,
  };

  Some(result)
}

fn exec_file_read(ctx: &CodexWorkspaceToolContext, args: &Value) -> CodexWorkspaceToolResult {
  let path = match required_string(args, "path") {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };
  let resolved = match resolve_read_or_edit_path(ctx, path) {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };

  let mut bytes = match read_file_prefix_bytes(&resolved, MAX_FILE_READ_BYTES) {
    Ok(bytes) => bytes,
    Err(error) => return tool_error(format!("failed to read file: {error}")),
  };
  let truncated = bytes.len() > MAX_FILE_READ_BYTES;
  if truncated {
    bytes.truncate(MAX_FILE_READ_BYTES);
  }

  let content = match std::str::from_utf8(bytes.as_slice()) {
    Ok(text) => text.to_string(),
    Err(error) if truncated && error.error_len().is_none() => {
      let cutoff = error.valid_up_to();
      let safe_prefix = bytes
        .get(..cutoff)
        .expect("UTF-8 valid_up_to always within source bytes");
      match std::str::from_utf8(safe_prefix) {
        Ok(text) => text.to_string(),
        Err(_) => return tool_error("file_read supports UTF-8 text files only".to_string()),
      }
    }
    Err(_) => return tool_error("file_read supports UTF-8 text files only".to_string()),
  };

  tool_ok(json!({
    "path": resolved.to_string_lossy(),
    "content": content,
    "truncated": truncated
  }))
}

fn read_file_prefix_bytes(path: &Path, max_bytes: usize) -> std::io::Result<Vec<u8>> {
  let mut file = fs::File::open(path)?;
  let mut limited_reader = file.by_ref().take((max_bytes.saturating_add(1)) as u64);
  let mut bytes = Vec::with_capacity(max_bytes.saturating_add(1));
  limited_reader.read_to_end(&mut bytes)?;
  Ok(bytes)
}

fn exec_file_write(ctx: &CodexWorkspaceToolContext, args: &Value) -> CodexWorkspaceToolResult {
  let path = match required_string(args, "path") {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };
  let content = match required_string(args, "content") {
    Ok(content) => content,
    Err(error) => return tool_error(error),
  };
  let resolved = match resolve_write_path(ctx, path) {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };

  if resolved.is_dir() {
    return tool_error("target path is a directory".to_string());
  }

  if let Err(error) = fs::write(&resolved, content) {
    return tool_error(format!("failed to write file: {error}"));
  }

  tool_ok(json!({
    "path": resolved.to_string_lossy(),
    "bytes_written": content.len()
  }))
}

fn exec_file_edit(ctx: &CodexWorkspaceToolContext, args: &Value) -> CodexWorkspaceToolResult {
  let path = match required_string(args, "path") {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };
  let old_string = match required_string(args, "old_string") {
    Ok(value) => value,
    Err(error) => return tool_error(error),
  };
  let new_string = match required_string(args, "new_string") {
    Ok(value) => value,
    Err(error) => return tool_error(error),
  };
  let replace_all = args
    .get("replace_all")
    .and_then(Value::as_bool)
    .unwrap_or(false);

  if old_string.is_empty() {
    return tool_error("old_string must not be empty".to_string());
  }

  let resolved = match resolve_read_or_edit_path(ctx, path) {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };
  let existing = match fs::read_to_string(&resolved) {
    Ok(content) => content,
    Err(error) => return tool_error(format!("failed to read file for edit: {error}")),
  };

  let occurrences = existing.match_indices(old_string).count();
  if occurrences == 0 {
    return tool_error("old_string not found in file".to_string());
  }
  if !replace_all && occurrences != 1 {
    return tool_error(format!(
      "old_string must be unique when replace_all is false (found {occurrences} matches)"
    ));
  }

  let updated = if replace_all {
    existing.replace(old_string, new_string)
  } else {
    existing.replacen(old_string, new_string, 1)
  };

  if let Err(error) = fs::write(&resolved, updated) {
    return tool_error(format!("failed to write edited file: {error}"));
  }

  tool_ok(json!({
    "path": resolved.to_string_lossy(),
    "replacements": if replace_all { occurrences } else { 1 }
  }))
}

fn exec_plan_write(ctx: &CodexWorkspaceToolContext, args: &Value) -> CodexWorkspaceToolResult {
  let path = match required_string(args, "path") {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };
  let content = match required_string(args, "content") {
    Ok(content) => content,
    Err(error) => return tool_error(error),
  };
  let overwrite = args
    .get("overwrite")
    .and_then(Value::as_bool)
    .unwrap_or(false);

  let resolved = match write_plan_markdown(ctx, path, content, overwrite) {
    Ok(path) => path,
    Err(error) => return tool_error(error),
  };

  tool_ok(json!({
    "path": resolved.to_string_lossy(),
    "bytes_written": content.len(),
    "plan_written": true
  }))
}

pub(crate) fn write_plan_markdown(
  ctx: &CodexWorkspaceToolContext,
  path: &str,
  content: &str,
  overwrite: bool,
) -> Result<PathBuf, String> {
  let resolved = resolve_plan_write_path(ctx, path)?;
  if resolved.is_dir() {
    return Err("target path is a directory".to_string());
  }
  if resolved.exists() && !overwrite {
    return Err("target file already exists; set overwrite=true to replace it".to_string());
  }
  fs::write(&resolved, content).map_err(|error| format!("failed to write plan file: {error}"))?;
  Ok(resolved)
}

fn required_string<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
  args
    .get(key)
    .and_then(Value::as_str)
    .ok_or_else(|| format!("missing required string field: {key}"))
}

fn resolve_read_or_edit_path(
  ctx: &CodexWorkspaceToolContext,
  input_path: &str,
) -> Result<PathBuf, String> {
  let unresolved = resolve_unscoped_path(ctx, input_path);
  let canonical = fs::canonicalize(&unresolved)
    .map_err(|error| format!("path does not resolve to an existing file: {error}"))?;
  if !canonical.is_file() {
    return Err("path must point to an existing file".to_string());
  }
  ensure_path_within_project(ctx, &canonical)?;
  Ok(canonical)
}

fn resolve_write_path(
  ctx: &CodexWorkspaceToolContext,
  input_path: &str,
) -> Result<PathBuf, String> {
  let unresolved = resolve_unscoped_path(ctx, input_path);
  if unresolved.exists() {
    let canonical =
      fs::canonicalize(&unresolved).map_err(|error| format!("failed to resolve path: {error}"))?;
    ensure_path_within_project(ctx, &canonical)?;
    return Ok(canonical);
  }

  let file_name = unresolved
    .file_name()
    .ok_or_else(|| "path must include a file name".to_string())?
    .to_owned();
  let parent = unresolved
    .parent()
    .ok_or_else(|| "path must have a parent directory".to_string())?;
  let canonical_parent =
    fs::canonicalize(parent).map_err(|error| format!("parent directory must exist: {error}"))?;
  ensure_path_within_project(ctx, &canonical_parent)?;
  Ok(canonical_parent.join(file_name))
}

fn resolve_plan_write_path(
  ctx: &CodexWorkspaceToolContext,
  input_path: &str,
) -> Result<PathBuf, String> {
  let canonical_project_root = fs::canonicalize(&ctx.project_path)
    .map_err(|error| format!("failed to resolve project root: {error}"))?;
  let plans_root = canonical_project_root.join("plans");
  fs::create_dir_all(&plans_root)
    .map_err(|error| format!("failed to create plans directory: {error}"))?;
  let canonical_plans_root = fs::canonicalize(&plans_root)
    .map_err(|error| format!("failed to resolve plans root: {error}"))?;
  if !canonical_plans_root.starts_with(&canonical_project_root) {
    return Err("plans directory must resolve within project root".to_string());
  }

  let parsed_input = PathBuf::from(input_path);
  if parsed_input.as_os_str().is_empty() {
    return Err("path must not be empty".to_string());
  }
  if has_parent_dir_component(&parsed_input) {
    return Err("path must not contain '..' segments".to_string());
  }

  let candidate = if parsed_input.is_absolute() {
    parsed_input
  } else {
    canonical_plans_root.join(parsed_input)
  };
  if candidate.file_name().is_none() {
    return Err("path must include a file name".to_string());
  }
  ensure_path_within_root(&candidate, &canonical_plans_root, "plans")?;

  if candidate.exists() {
    let canonical_candidate =
      fs::canonicalize(&candidate).map_err(|error| format!("failed to resolve path: {error}"))?;
    ensure_path_within_root(&canonical_candidate, &canonical_plans_root, "plans")?;
    return Ok(canonical_candidate);
  }

  let file_name = candidate
    .file_name()
    .ok_or_else(|| "path must include a file name".to_string())?
    .to_owned();
  let parent = candidate
    .parent()
    .ok_or_else(|| "path must have a parent directory".to_string())?;
  fs::create_dir_all(parent)
    .map_err(|error| format!("failed to create parent directory: {error}"))?;
  let canonical_parent = fs::canonicalize(parent)
    .map_err(|error| format!("failed to resolve parent directory: {error}"))?;
  ensure_path_within_root(&canonical_parent, &canonical_plans_root, "plans")?;
  Ok(canonical_parent.join(file_name))
}

fn resolve_unscoped_path(ctx: &CodexWorkspaceToolContext, input_path: &str) -> PathBuf {
  let candidate = PathBuf::from(input_path);
  if candidate.is_absolute() {
    return candidate;
  }

  let base = ctx.current_cwd.as_deref().unwrap_or(&ctx.project_path);
  Path::new(base).join(candidate)
}

fn has_parent_dir_component(path: &Path) -> bool {
  path
    .components()
    .any(|component| matches!(component, Component::ParentDir))
}

fn ensure_path_within_root(candidate: &Path, root: &Path, root_name: &str) -> Result<(), String> {
  if candidate.starts_with(root) {
    return Ok(());
  }
  Err(format!(
    "path escapes {root_name} directory: {}",
    root.to_string_lossy()
  ))
}

fn ensure_path_within_project(
  ctx: &CodexWorkspaceToolContext,
  candidate: &Path,
) -> Result<(), String> {
  let canonical_project_root = fs::canonicalize(&ctx.project_path)
    .map_err(|error| format!("failed to resolve project root: {error}"))?;
  if candidate.starts_with(&canonical_project_root) {
    return Ok(());
  }
  Err(format!(
    "path escapes project root: {}",
    canonical_project_root.to_string_lossy()
  ))
}

fn tool_ok(payload: Value) -> CodexWorkspaceToolResult {
  CodexWorkspaceToolResult {
    success: true,
    output: payload.to_string(),
  }
}

fn tool_error(message: String) -> CodexWorkspaceToolResult {
  CodexWorkspaceToolResult {
    success: false,
    output: json!({ "error": message }).to_string(),
  }
}

#[cfg(test)]
mod tests {
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
}
