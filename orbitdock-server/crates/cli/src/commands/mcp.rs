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

#[derive(Debug, Serialize)]
struct McpToolsSummary {
  session_id: String,
  server_count: usize,
  tool_count: usize,
  resource_count: usize,
  resource_template_count: usize,
  auth_server_count: usize,
}

#[derive(Debug, Serialize)]
struct McpToolsJsonResponse {
  kind: &'static str,
  summary: McpToolsSummary,
  tools: McpToolsResponse,
}

#[derive(Debug, Serialize)]
struct McpRefreshJsonResponse {
  ok: bool,
  action: &'static str,
  session_id: String,
  accepted: bool,
}

fn auth_status_str(status: &McpAuthStatus) -> &'static str {
  match status {
    McpAuthStatus::Unsupported => "unsupported",
    McpAuthStatus::NotLoggedIn => "not_logged_in",
    McpAuthStatus::BearerToken => "bearer_token",
    McpAuthStatus::OAuth => "oauth",
  }
}

fn summarize_mcp_tools(resp: &McpToolsResponse) -> McpToolsSummary {
  let server_count = resp
    .tools
    .keys()
    .chain(resp.resources.keys())
    .chain(resp.resource_templates.keys())
    .chain(resp.auth_statuses.keys())
    .collect::<std::collections::BTreeSet<_>>()
    .len();
  let resource_count = resp.resources.values().map(Vec::len).sum();
  let resource_template_count = resp.resource_templates.values().map(Vec::len).sum();
  let tool_count = resp.tools.len();
  let auth_server_count = resp.auth_statuses.len();

  McpToolsSummary {
    session_id: resp.session_id.clone(),
    server_count,
    tool_count,
    resource_count,
    resource_template_count,
    auth_server_count,
  }
}

fn build_mcp_tools_json_response(resp: McpToolsResponse) -> McpToolsJsonResponse {
  let summary = summarize_mcp_tools(&resp);

  McpToolsJsonResponse {
    kind: "mcp_tools",
    summary,
    tools: resp,
  }
}

pub async fn run(action: &McpAction, rest: &RestClient, output: &Output) -> i32 {
  match action {
    McpAction::Tools { session_id } => tools(rest, output, session_id).await,
    McpAction::Refresh { session_id } => refresh(rest, output, session_id).await,
  }
}

async fn tools(rest: &RestClient, output: &Output, session_id: &str) -> i32 {
  let path = format!("/api/sessions/{session_id}/mcp");
  match rest.get::<McpToolsResponse>(&path).await.into_result() {
    Ok(resp) => {
      if output.json {
        output.print_json_pretty(&build_mcp_tools_json_response(resp));
      } else {
        let summary = summarize_mcp_tools(&resp);
        println!(
          "MCP Tools for {session_id}: {} server(s), {} tool(s), {} resource(s), {} template(s)",
          summary.server_count,
          summary.tool_count,
          summary.resource_count,
          summary.resource_template_count
        );
        for (key, tool) in &resp.tools {
          let desc = tool.description.as_deref().unwrap_or("no description");
          println!("  {key}: {} — {desc}", tool.name);
        }
        if !resp.auth_statuses.is_empty() {
          println!("\nAuth:");
          for (server, status) in &resp.auth_statuses {
            println!("  [{server}] {}", auth_status_str(status));
          }
        }
        if !resp.resources.is_empty() {
          println!("\nResources:");
          for (server, resources) in &resp.resources {
            for r in resources {
              println!("  [{server}] {} ({})", r.name, r.uri);
            }
          }
        }
        if !resp.resource_templates.is_empty() {
          println!("\nResource templates:");
          for (server, templates) in &resp.resource_templates {
            for template in templates {
              println!("  [{server}] {} ({})", template.name, template.uri_template);
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
        output.print_json_pretty(&McpRefreshJsonResponse {
          ok: resp.accepted,
          action: "refresh_requested",
          session_id: session_id.to_string(),
          accepted: resp.accepted,
        });
      } else {
        println!("MCP server refresh requested for session {session_id}.");
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}
