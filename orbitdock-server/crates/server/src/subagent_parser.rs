//! Subagent transcript JSONL parser
//!
//! Parses tool calls from subagent transcript files.
//! Two-pass approach: first collect tool_result outputs, then build tool list.

use std::collections::HashMap;
use std::path::Path;

use orbitdock_protocol::SubagentTool;
use serde_json::Value;

/// Parse tool calls from a subagent transcript JSONL file.
/// Returns a list of tools with their summaries and outputs.
pub fn parse_tools(path: &Path) -> Vec<SubagentTool> {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();

    // Pass 1: collect tool_result content by tool_use_id
    let mut tool_results: HashMap<String, String> = HashMap::new();

    for line in &lines {
        let json: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        if json.get("type").and_then(|t| t.as_str()) != Some("user") {
            continue;
        }

        if let Some(content_array) = json
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_array())
        {
            for item in content_array {
                if item.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                    if let Some(tool_use_id) = item.get("tool_use_id").and_then(|id| id.as_str()) {
                        let result_text = extract_tool_result_content(item);
                        tool_results.insert(tool_use_id.to_string(), result_text);
                    }
                }
            }
        }
    }

    // Pass 2: build tool messages from assistant tool_use items
    let mut tools: Vec<SubagentTool> = Vec::new();

    for line in &lines {
        let json: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        if json.get("type").and_then(|t| t.as_str()) != Some("assistant") {
            continue;
        }

        let uuid = match json.get("uuid").and_then(|u| u.as_str()) {
            Some(u) => u,
            None => continue,
        };

        let content_array = match json
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_array())
        {
            Some(arr) => arr,
            None => continue,
        };

        for (index, item) in content_array.iter().enumerate() {
            if item.get("type").and_then(|t| t.as_str()) != Some("tool_use") {
                continue;
            }

            let tool_name = match item.get("name").and_then(|n| n.as_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };

            let tool_id = match item.get("id").and_then(|id| id.as_str()) {
                Some(id) => id.to_string(),
                None => continue,
            };

            let input = item.get("input");
            let summary = create_tool_summary(&tool_name, input);
            let output = tool_results.get(&tool_id).cloned();
            let is_in_progress = output.is_none();

            tools.push(SubagentTool {
                id: format!("{}-tool-{}", uuid, index),
                tool_name,
                summary,
                output,
                is_in_progress,
            });
        }
    }

    tools
}

/// Extract text content from a tool_result item.
fn extract_tool_result_content(item: &Value) -> String {
    // Simple string content
    if let Some(content) = item.get("content").and_then(|c| c.as_str()) {
        return content.to_string();
    }

    // Array of content blocks
    if let Some(content_array) = item.get("content").and_then(|c| c.as_array()) {
        let texts: Vec<&str> = content_array
            .iter()
            .filter_map(|block| {
                if block.get("type").and_then(|t| t.as_str()) == Some("text") {
                    block.get("text").and_then(|t| t.as_str())
                } else {
                    None
                }
            })
            .collect();
        return texts.join("\n");
    }

    String::new()
}

/// Create a human-readable summary for a tool call.
fn create_tool_summary(tool_name: &str, input: Option<&Value>) -> String {
    let input = match input {
        Some(v) => v,
        None => return tool_name.to_string(),
    };

    match tool_name.to_lowercase().as_str() {
        "read" => {
            if let Some(path) = input.get("file_path").and_then(|p| p.as_str()) {
                return shorten_path(path);
            }
        }
        "edit" => {
            if let Some(path) = input.get("file_path").and_then(|p| p.as_str()) {
                return shorten_path(path);
            }
            if let Some(patch) = input.get("patch").and_then(|p| p.as_str()) {
                for line in patch.lines() {
                    if line.starts_with("*** Add File:") || line.starts_with("*** Update File:") {
                        let path = line
                            .trim_start_matches("*** Add File:")
                            .trim_start_matches("*** Update File:")
                            .trim();
                        return shorten_path(path);
                    }
                }
            }
        }
        "write" => {
            if let Some(path) = input.get("file_path").and_then(|p| p.as_str()) {
                return shorten_path(path);
            }
        }
        "bash" => {
            let command = input
                .get("command")
                .or_else(|| input.get("cmd"))
                .and_then(|c| {
                    if let Some(s) = c.as_str() {
                        Some(s.to_string())
                    } else if let Some(arr) = c.as_array() {
                        Some(
                            arr.iter()
                                .filter_map(|v| v.as_str())
                                .collect::<Vec<_>>()
                                .join(" "),
                        )
                    } else {
                        None
                    }
                });
            if let Some(cmd) = command {
                let truncated = if cmd.len() > 60 {
                    format!("{}...", &cmd[..60])
                } else {
                    cmd
                };
                return truncated.replace('\n', " ");
            }
        }
        "glob" => {
            if let Some(pattern) = input.get("pattern").and_then(|p| p.as_str()) {
                return pattern.to_string();
            }
        }
        "grep" => {
            if let Some(pattern) = input.get("pattern").and_then(|p| p.as_str()) {
                return format!("Pattern: {}", pattern);
            }
        }
        "task" => {
            if let Some(prompt) = input.get("prompt").and_then(|p| p.as_str()) {
                if prompt.len() > 50 {
                    return format!("{}...", &prompt[..50]);
                }
                return prompt.to_string();
            }
        }
        _ => {}
    }

    tool_name.to_string()
}

/// Shorten a file path for display (show last 2 components with .../prefix).
fn shorten_path(path: &str) -> String {
    let components: Vec<&str> = path.split('/').collect();
    if components.len() > 3 {
        format!(".../{}", components[components.len() - 2..].join("/"))
    } else {
        path.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_shorten_path() {
        assert_eq!(shorten_path("/a/b/c/d/e.rs"), ".../d/e.rs");
        assert_eq!(shorten_path("a/b/c"), "a/b/c");
        assert_eq!(shorten_path("file.rs"), "file.rs");
    }

    #[test]
    fn test_create_tool_summary_read() {
        let input = serde_json::json!({"file_path": "/Users/me/project/src/main.rs"});
        assert_eq!(
            create_tool_summary("Read", Some(&input)),
            ".../src/main.rs"
        );
    }

    #[test]
    fn test_create_tool_summary_bash() {
        let input = serde_json::json!({"command": "echo hello"});
        assert_eq!(
            create_tool_summary("Bash", Some(&input)),
            "echo hello"
        );
    }

    #[test]
    fn test_create_tool_summary_grep() {
        let input = serde_json::json!({"pattern": "fn main"});
        assert_eq!(
            create_tool_summary("Grep", Some(&input)),
            "Pattern: fn main"
        );
    }

    #[test]
    fn test_create_tool_summary_no_input() {
        assert_eq!(create_tool_summary("Unknown", None), "Unknown");
    }

    #[test]
    fn test_extract_tool_result_string() {
        let item = serde_json::json!({"content": "hello world", "type": "tool_result"});
        assert_eq!(extract_tool_result_content(&item), "hello world");
    }

    #[test]
    fn test_extract_tool_result_array() {
        let item = serde_json::json!({
            "type": "tool_result",
            "content": [
                {"type": "text", "text": "line 1"},
                {"type": "text", "text": "line 2"}
            ]
        });
        assert_eq!(extract_tool_result_content(&item), "line 1\nline 2");
    }
}
