//! Codex-oriented workspace tools exposed as dynamic tools for direct sessions.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

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

pub fn default_codex_workspace_tools_json() -> Vec<Value> {
  with_default_codex_workspace_tools(Vec::new())
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

  let bytes = match fs::read(&resolved) {
    Ok(bytes) => bytes,
    Err(error) => return tool_error(format!("failed to read file: {error}")),
  };

  let text = match std::str::from_utf8(bytes.as_slice()) {
    Ok(text) => text,
    Err(_) => return tool_error("file_read supports UTF-8 text files only".to_string()),
  };
  let truncated = bytes.len() > MAX_FILE_READ_BYTES;
  let content = if truncated {
    let mut cutoff = MAX_FILE_READ_BYTES.min(text.len());
    while cutoff > 0 && !text.is_char_boundary(cutoff) {
      cutoff -= 1;
    }
    text[..cutoff].to_string()
  } else {
    text.to_string()
  };

  tool_ok(json!({
    "path": resolved.to_string_lossy(),
    "content": content,
    "truncated": truncated
  }))
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

fn resolve_unscoped_path(ctx: &CodexWorkspaceToolContext, input_path: &str) -> PathBuf {
  let candidate = PathBuf::from(input_path);
  if candidate.is_absolute() {
    return candidate;
  }

  let base = ctx.current_cwd.as_deref().unwrap_or(&ctx.project_path);
  Path::new(base).join(candidate)
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
  fn dynamic_tool_specs_include_three_workspace_tools() {
    let specs = codex_workspace_dynamic_tool_specs();
    let names: Vec<String> = specs.into_iter().map(|spec| spec.name).collect();
    assert_eq!(names, vec!["file_read", "file_write", "file_edit"]);
  }

  #[test]
  fn default_workspace_tools_are_appended_when_missing() {
    let merged = with_default_codex_workspace_tools(Vec::new());
    let names: Vec<String> = merged.into_iter().map(|spec| spec.name).collect();
    assert_eq!(names, vec!["file_read", "file_write", "file_edit"]);
  }

  #[test]
  fn default_workspace_tools_json_contains_all_three_tools() {
    let tools = default_codex_workspace_tools_json();
    let names: Vec<String> = tools
      .iter()
      .filter_map(|tool| tool.get("name").and_then(Value::as_str))
      .map(ToOwned::to_owned)
      .collect();
    assert_eq!(names, vec!["file_read", "file_write", "file_edit"]);
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
    assert_eq!(names, vec!["file_read", "file_write", "file_edit"]);
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
}
