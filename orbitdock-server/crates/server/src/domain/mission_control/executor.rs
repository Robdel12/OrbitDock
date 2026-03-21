//! Shared mission tool executor — used by both the MCP server (Claude) and
//! the dynamic tool handler (Codex).

use serde_json::Value;

use crate::domain::mission_control::tracker::Tracker;

use super::tools::MissionToolContext;

/// Result of executing a mission tool.
pub struct MissionToolResult {
    pub success: bool,
    /// JSON string returned to the agent.
    pub output: String,
    /// True when the agent signalled a blocker via `mission_report_blocked`.
    pub blocked: bool,
}

/// Execute a mission tool call against the tracker API.
pub async fn execute_mission_tool(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    tool_name: &str,
    arguments: Value,
) -> MissionToolResult {
    match tool_name {
        "mission_get_issue" => exec_get_issue(tracker, ctx).await,
        "mission_post_update" => exec_post_update(tracker, ctx, &arguments).await,
        "mission_update_comment" => exec_update_comment(tracker, &arguments).await,
        "mission_get_comments" => exec_get_comments(tracker, ctx, &arguments).await,
        "mission_set_status" => exec_set_status(tracker, ctx, &arguments).await,
        "mission_link_pr" => exec_link_pr(tracker, ctx, &arguments).await,
        "mission_create_followup" => exec_create_followup(tracker, ctx, &arguments).await,
        "mission_report_blocked" => exec_report_blocked(tracker, ctx, &arguments).await,
        _ => MissionToolResult {
            success: false,
            output: serde_json::json!({ "error": format!("Unknown tool: {tool_name}") })
                .to_string(),
            blocked: false,
        },
    }
}

// ── Individual tool handlers ────────────────────────────────────────

async fn exec_get_issue(tracker: &dyn Tracker, ctx: &MissionToolContext) -> MissionToolResult {
    match tracker
        .fetch_issue_by_identifier(&ctx.issue_identifier)
        .await
    {
        Ok(Some(issue)) => MissionToolResult {
            success: true,
            output: serde_json::json!({
                "identifier": issue.identifier,
                "title": issue.title,
                "description": issue.description,
                "state": issue.state,
                "url": issue.url,
                "labels": issue.labels,
                "priority": issue.priority,
            })
            .to_string(),
            blocked: false,
        },
        Ok(None) => MissionToolResult {
            success: false,
            output:
                serde_json::json!({ "error": format!("Issue {} not found", ctx.issue_identifier) })
                    .to_string(),
            blocked: false,
        },
        Err(e) => err(e),
    }
}

async fn exec_post_update(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let body = match args.get("body").and_then(|v| v.as_str()) {
        Some(b) => b,
        None => return missing_field("body"),
    };

    match tracker.create_comment(&ctx.issue_id, body).await {
        Ok(()) => ok_json(serde_json::json!({ "posted": true })),
        Err(e) => err(e),
    }
}

async fn exec_update_comment(tracker: &dyn Tracker, args: &Value) -> MissionToolResult {
    let comment_id = match args.get("comment_id").and_then(|v| v.as_str()) {
        Some(id) => id,
        None => return missing_field("comment_id"),
    };
    let body = match args.get("body").and_then(|v| v.as_str()) {
        Some(b) => b,
        None => return missing_field("body"),
    };

    match tracker.update_comment(comment_id, body).await {
        Ok(()) => ok_json(serde_json::json!({ "updated": true })),
        Err(e) => err(e),
    }
}

async fn exec_get_comments(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let first = args
        .get("first")
        .and_then(|v| v.as_u64())
        .unwrap_or(20)
        .min(50) as u32;

    match tracker.list_comments(&ctx.issue_id, first).await {
        Ok(comments) => ok_json(serde_json::json!({ "comments": comments })),
        Err(e) => err(e),
    }
}

async fn exec_set_status(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let state = match args.get("state").and_then(|v| v.as_str()) {
        Some(s) => s,
        None => return missing_field("state"),
    };

    match tracker.update_issue_state(&ctx.issue_id, state).await {
        Ok(()) => ok_json(serde_json::json!({ "state": state, "updated": true })),
        Err(e) => err(e),
    }
}

async fn exec_link_pr(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let url = match args.get("url").and_then(|v| v.as_str()) {
        Some(u) => u,
        None => return missing_field("url"),
    };
    let title = args
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("Pull Request");

    match tracker.link_url(&ctx.issue_id, url, title).await {
        Ok(()) => ok_json(serde_json::json!({ "linked": true, "url": url })),
        Err(e) => err(e),
    }
}

async fn exec_create_followup(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let title = match args.get("title").and_then(|v| v.as_str()) {
        Some(t) => t,
        None => return missing_field("title"),
    };
    let description = match args.get("description").and_then(|v| v.as_str()) {
        Some(d) => d,
        None => return missing_field("description"),
    };

    let desc_with_link = format!(
        "{description}\n\n---\nFollow-up from {}: {}",
        ctx.issue_identifier, ctx.issue_id
    );

    match tracker
        .create_issue(&ctx.issue_id, title, &desc_with_link)
        .await
    {
        Ok(created) => ok_json(serde_json::json!({
            "created": true,
            "identifier": created.identifier,
            "url": created.url,
        })),
        Err(e) => err(e),
    }
}

async fn exec_report_blocked(
    tracker: &dyn Tracker,
    ctx: &MissionToolContext,
    args: &Value,
) -> MissionToolResult {
    let reason = match args.get("reason").and_then(|v| v.as_str()) {
        Some(r) => r,
        None => return missing_field("reason"),
    };

    let comment = format!("**Blocked** — agent reported a blocker:\n\n{reason}");

    // Best-effort: post the blocker as a comment on the issue
    let _ = tracker.create_comment(&ctx.issue_id, &comment).await;

    MissionToolResult {
        success: true,
        output: serde_json::json!({ "blocked": true, "reason": reason }).to_string(),
        blocked: true,
    }
}

// ── Helpers ─────────────────────────────────────────────────────────

fn ok_json(value: Value) -> MissionToolResult {
    MissionToolResult {
        success: true,
        output: value.to_string(),
        blocked: false,
    }
}

fn err(e: anyhow::Error) -> MissionToolResult {
    MissionToolResult {
        success: false,
        output: serde_json::json!({ "error": e.to_string() }).to_string(),
        blocked: false,
    }
}

fn missing_field(field: &str) -> MissionToolResult {
    MissionToolResult {
        success: false,
        output: serde_json::json!({ "error": format!("Missing required field: {field}") })
            .to_string(),
        blocked: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrastructure::linear::client::LinearClient;
    use serde_json::json;

    fn test_ctx() -> MissionToolContext {
        MissionToolContext {
            issue_id: "issue-abc-123".into(),
            issue_identifier: "TEST-42".into(),
            mission_id: "mission-xyz".into(),
        }
    }

    #[tokio::test]
    async fn unknown_tool_returns_error() {
        let client = LinearClient::new("fake-key".into());
        let result =
            execute_mission_tool(&client, &test_ctx(), "nonexistent_tool", json!({})).await;

        assert!(!result.success);
        assert!(!result.blocked);
        let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
        assert!(output["error"].as_str().unwrap().contains("Unknown tool"));
    }

    #[test]
    fn missing_field_helper_reports_field_name() {
        let result = missing_field("body");
        assert!(!result.success);
        let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
        assert!(output["error"].as_str().unwrap().contains("body"));
    }

    #[test]
    fn ok_json_helper_produces_success() {
        let result = ok_json(json!({"test": true}));
        assert!(result.success);
        assert!(!result.blocked);
        let output: serde_json::Value = serde_json::from_str(&result.output).unwrap();
        assert_eq!(output["test"], true);
    }
}
