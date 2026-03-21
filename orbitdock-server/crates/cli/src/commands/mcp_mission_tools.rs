//! MCP stdio server providing mission tools to agent sessions.
//!
//! Launched as `orbitdock mcp-mission-tools` by Claude Code when it discovers
//! the `.mcp.json` written into the worktree by mission dispatch.
//!
//! Env vars:
//!   ORBITDOCK_TRACKER_KIND     — Tracker kind: "linear" (default) or "github"
//!   LINEAR_API_KEY             — Linear API key (when tracker_kind = linear)
//!   GITHUB_TOKEN               — GitHub token (when tracker_kind = github)
//!   ORBITDOCK_ISSUE_ID         — Tracker internal issue ID
//!   ORBITDOCK_ISSUE_IDENTIFIER — Human-readable identifier (e.g. VIZ-240 or owner/repo#42)
//!   ORBITDOCK_MISSION_ID       — OrbitDock mission ID

use std::io::{self, BufRead, Write};
use std::sync::Arc;

use serde_json::{json, Value};

use orbitdock_server::linear::LinearClient;
use orbitdock_server::mission_tools::{
    execute_mission_tool, mission_tool_definitions, MissionToolContext,
};
use orbitdock_server::tracker::Tracker;

/// Build the appropriate tracker client based on env vars.
fn build_tracker() -> anyhow::Result<Arc<dyn Tracker>> {
    let tracker_kind = std::env::var("ORBITDOCK_TRACKER_KIND").unwrap_or_else(|_| "linear".into());

    match tracker_kind.as_str() {
        "linear" => {
            let api_key = std::env::var("LINEAR_API_KEY")
                .map_err(|_| anyhow::anyhow!("LINEAR_API_KEY not set"))?;
            Ok(Arc::new(LinearClient::new(api_key)))
        }
        "github" => {
            let token = std::env::var("GITHUB_TOKEN")
                .map_err(|_| anyhow::anyhow!("GITHUB_TOKEN not set"))?;
            // GitHubClient will be added in a later step — for now fall through
            // to avoid blocking the refactor
            Ok(Arc::new(orbitdock_server::github::GitHubClient::new(token)))
        }
        other => anyhow::bail!("Unknown tracker kind: {other}"),
    }
}

/// Entry point — runs a blocking JSON-RPC loop on stdin/stdout.
pub fn run() -> anyhow::Result<()> {
    let tracker = build_tracker()?;
    let issue_id = std::env::var("ORBITDOCK_ISSUE_ID")
        .map_err(|_| anyhow::anyhow!("ORBITDOCK_ISSUE_ID not set"))?;
    let issue_identifier = std::env::var("ORBITDOCK_ISSUE_IDENTIFIER")
        .map_err(|_| anyhow::anyhow!("ORBITDOCK_ISSUE_IDENTIFIER not set"))?;
    let mission_id =
        std::env::var("ORBITDOCK_MISSION_ID").unwrap_or_else(|_| "unknown".to_string());

    let ctx = MissionToolContext {
        issue_id,
        issue_identifier,
        mission_id,
    };

    let rt = tokio::runtime::Runtime::new()?;

    let stdin = io::stdin();
    let stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let id = msg.get("id").cloned();

        // Notifications (no id) — acknowledge silently
        if id.is_none() {
            continue;
        }

        let response = match method {
            "initialize" => handle_initialize(),
            "tools/list" => handle_tools_list(),
            "tools/call" => rt.block_on(handle_tools_call(tracker.as_ref(), &ctx, &msg)),
            "ping" => json!({ "jsonrpc": "2.0", "id": id, "result": {} }),
            _ => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("Method not found: {method}") }
            }),
        };

        let mut resp = response;
        if let Some(id_val) = id {
            resp["id"] = id_val;
        }

        let mut out = stdout.lock();
        serde_json::to_writer(&mut out, &resp)?;
        out.write_all(b"\n")?;
        out.flush()?;
    }

    Ok(())
}

fn handle_initialize() -> Value {
    json!({
        "jsonrpc": "2.0",
        "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "orbitdock-mission",
                "version": env!("CARGO_PKG_VERSION")
            }
        }
    })
}

fn handle_tools_list() -> Value {
    let tools: Vec<Value> = mission_tool_definitions()
        .into_iter()
        .map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "inputSchema": t.input_schema,
            })
        })
        .collect();

    json!({
        "jsonrpc": "2.0",
        "result": { "tools": tools }
    })
}

async fn handle_tools_call(tracker: &dyn Tracker, ctx: &MissionToolContext, msg: &Value) -> Value {
    let params = msg.get("params").cloned().unwrap_or(json!({}));
    let tool_name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
    let arguments = params.get("arguments").cloned().unwrap_or(json!({}));

    let result = execute_mission_tool(tracker, ctx, tool_name, arguments).await;

    if result.success {
        json!({
            "jsonrpc": "2.0",
            "result": {
                "content": [{
                    "type": "text",
                    "text": result.output
                }]
            }
        })
    } else {
        json!({
            "jsonrpc": "2.0",
            "result": {
                "content": [{
                    "type": "text",
                    "text": result.output
                }],
                "isError": true
            }
        })
    }
}
