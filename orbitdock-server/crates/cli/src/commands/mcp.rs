use std::collections::HashMap;

use orbitdock_protocol::{McpAuthStatus, McpResource, McpResourceTemplate, McpTool};
use serde::{Deserialize, Serialize};

use crate::cli::McpAction;
use crate::client::rest::RestClient;
use crate::error::EXIT_SUCCESS;
use crate::output::Output;

#[derive(Debug, Deserialize, Serialize)]
struct McpToolsResponse {
    session_id: String,
    tools: HashMap<String, McpTool>,
    resources: HashMap<String, Vec<McpResource>>,
    resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
    auth_statuses: HashMap<String, McpAuthStatus>,
}

#[derive(Debug, Deserialize, Serialize)]
struct AcceptedResponse {
    accepted: bool,
}

pub async fn run(action: &McpAction, rest: &RestClient, output: &Output) -> i32 {
    match action {
        McpAction::Tools { session_id } => tools(rest, output, session_id).await,
        McpAction::Refresh { session_id } => refresh(rest, output, session_id).await,
    }
}

async fn tools(rest: &RestClient, output: &Output, session_id: &str) -> i32 {
    let path = format!("/api/sessions/{session_id}/mcp/tools");
    match rest.get::<McpToolsResponse>(&path).await.into_result() {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("MCP Tools ({} servers):", resp.tools.len());
                for (key, tool) in &resp.tools {
                    let desc = tool.description.as_deref().unwrap_or("no description");
                    println!("  {key}: {} — {desc}", tool.name);
                }
                if !resp.resources.is_empty() {
                    println!("\nResources:");
                    for (server, resources) in &resp.resources {
                        for r in resources {
                            println!("  [{server}] {} ({})", r.name, r.uri);
                        }
                    }
                }
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}

async fn refresh(rest: &RestClient, output: &Output, session_id: &str) -> i32 {
    let path = format!("/api/sessions/{session_id}/mcp/refresh");
    let body = serde_json::json!({});
    match rest
        .post_json::<_, AcceptedResponse>(&path, &body)
        .await
        .into_result()
    {
        Ok(resp) => {
            if output.json {
                output.print_json(&resp);
            } else {
                println!("MCP servers refresh requested.");
            }
            EXIT_SUCCESS
        }
        Err((code, err)) => {
            output.print_error(&err);
            code
        }
    }
}
