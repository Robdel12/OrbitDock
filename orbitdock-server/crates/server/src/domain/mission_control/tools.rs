//! Mission tool definitions shared by the MCP server (Claude) and dynamic tool handler (Codex).

use serde_json::{json, Value};

/// A mission tool definition with its JSON Schema input.
#[derive(Debug, Clone)]
pub struct MissionToolDef {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

/// Context injected into every mission tool call.
#[derive(Debug, Clone)]
pub struct MissionToolContext {
    pub issue_id: String,
    pub issue_identifier: String,
    pub mission_id: String,
}

/// Returns the canonical list of mission tools.
pub fn mission_tool_definitions() -> Vec<MissionToolDef> {
    vec![
        MissionToolDef {
            name: "mission_get_issue".into(),
            description: "Fetch the current issue's details including title, description, status, labels, and URL.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_post_update".into(),
            description: "Post a comment on the current issue. Use this for workpad updates, progress notes, and handoff summaries.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["body"],
                "properties": {
                    "body": {
                        "type": "string",
                        "description": "Markdown comment body to post on the issue."
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_update_comment".into(),
            description: "Edit an existing comment by ID. Use this to update a workpad comment in-place rather than posting a new one.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["comment_id", "body"],
                "properties": {
                    "comment_id": {
                        "type": "string",
                        "description": "The comment ID to update."
                    },
                    "body": {
                        "type": "string",
                        "description": "New markdown body for the comment."
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_get_comments".into(),
            description: "List comments on the current issue. Use this to find an existing workpad comment before creating a new one.".into(),
            input_schema: json!({
                "type": "object",
                "properties": {
                    "first": {
                        "type": "integer",
                        "description": "Number of comments to fetch (default: 20, max: 50).",
                        "default": 20
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_set_status".into(),
            description: "Move the current issue to a workflow state (e.g. \"In Progress\", \"In Review\", \"Done\").".into(),
            input_schema: json!({
                "type": "object",
                "required": ["state"],
                "properties": {
                    "state": {
                        "type": "string",
                        "description": "Human-readable workflow state name."
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_link_pr".into(),
            description: "Attach a pull request URL to the current issue.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["url"],
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "GitHub PR URL (e.g. https://github.com/org/repo/pull/123)."
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional display title for the attachment."
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_create_followup".into(),
            description: "Create a new backlog issue for out-of-scope work discovered during execution. The new issue is automatically linked to the current issue and placed in Backlog.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["title", "description"],
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "Title for the follow-up issue."
                    },
                    "description": {
                        "type": "string",
                        "description": "Markdown description with context and acceptance criteria."
                    },
                    "labels": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "Optional label names to apply."
                    }
                },
                "additionalProperties": false,
            }),
        },
        MissionToolDef {
            name: "mission_report_blocked".into(),
            description: "Signal that you are blocked and cannot continue. Use this when missing required auth, permissions, secrets, or tools that prevent completion.".into(),
            input_schema: json!({
                "type": "object",
                "required": ["reason"],
                "properties": {
                    "reason": {
                        "type": "string",
                        "description": "Clear explanation of what is blocking progress and what human action is needed."
                    }
                },
                "additionalProperties": false,
            }),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_eight_tools_are_defined() {
        let tools = mission_tool_definitions();
        assert_eq!(tools.len(), 8);
    }

    #[test]
    fn every_tool_has_a_mission_prefix() {
        for tool in mission_tool_definitions() {
            assert!(
                tool.name.starts_with("mission_"),
                "Tool '{}' should start with 'mission_'",
                tool.name
            );
        }
    }

    #[test]
    fn tool_names_are_unique() {
        let tools = mission_tool_definitions();
        let mut names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), 8, "Duplicate tool names detected");
    }

    #[test]
    fn every_schema_is_a_json_object() {
        for tool in mission_tool_definitions() {
            assert_eq!(
                tool.input_schema.get("type").and_then(|v| v.as_str()),
                Some("object"),
                "Tool '{}' schema must have type: object",
                tool.name
            );
        }
    }

    #[test]
    fn required_fields_match_properties() {
        for tool in mission_tool_definitions() {
            let required = tool
                .input_schema
                .get("required")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let properties = tool
                .input_schema
                .get("properties")
                .and_then(|v| v.as_object());

            for req in &required {
                let name = req.as_str().unwrap_or("");
                assert!(
                    properties.map(|p| p.contains_key(name)).unwrap_or(false),
                    "Tool '{}' lists required field '{}' that doesn't exist in properties",
                    tool.name,
                    name
                );
            }
        }
    }

    #[test]
    fn expected_tools_present() {
        let tools = mission_tool_definitions();
        let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
        let expected = [
            "mission_get_issue",
            "mission_post_update",
            "mission_update_comment",
            "mission_get_comments",
            "mission_set_status",
            "mission_link_pr",
            "mission_create_followup",
            "mission_report_blocked",
        ];
        for name in expected {
            assert!(names.contains(&name), "Missing tool: {name}");
        }
    }
}
