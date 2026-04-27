use super::{create_tool_summary, extract_tool_result_content, shorten_path};

#[test]
fn shorten_path_keeps_short_inputs_unchanged() {
  assert_eq!(shorten_path("/a/b/c/d/e.rs"), ".../d/e.rs");
  assert_eq!(shorten_path("a/b/c"), "a/b/c");
  assert_eq!(shorten_path("file.rs"), "file.rs");
}

#[test]
fn create_tool_summary_handles_common_inputs() {
  let read = serde_json::json!({"file_path": "/Users/me/project/src/main.rs"});
  let bash = serde_json::json!({"command": "echo hello"});
  let grep = serde_json::json!({"pattern": "fn main"});

  assert_eq!(create_tool_summary("Read", Some(&read)), ".../src/main.rs");
  assert_eq!(create_tool_summary("Bash", Some(&bash)), "echo hello");
  assert_eq!(create_tool_summary("Grep", Some(&grep)), "Pattern: fn main");
  assert_eq!(create_tool_summary("Unknown", None), "Unknown");
}

#[test]
fn extract_tool_result_content_handles_strings_and_arrays() {
  let string_item = serde_json::json!({"content": "hello world", "type": "tool_result"});
  let array_item = serde_json::json!({
    "type": "tool_result",
    "content": [
      {"type": "text", "text": "line 1"},
      {"type": "text", "text": "line 2"}
    ]
  });

  assert_eq!(extract_tool_result_content(&string_item), "hello world");
  assert_eq!(extract_tool_result_content(&array_item), "line 1\nline 2");
}
