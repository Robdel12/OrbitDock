use super::flatten_mcp_tools;
use codex_app_server_protocol::{McpAuthStatus, McpServerStatus};
use codex_protocol::mcp::{Resource as McpResource, ResourceTemplate as McpResourceTemplate};
use std::collections::HashMap;

#[test]
fn flatten_mcp_tools_uses_qualified_tool_keys() {
  let status = McpServerStatus {
    name: "docs".to_string(),
    tools: HashMap::from([(
      "docs__search".to_string(),
      codex_protocol::mcp::Tool {
        name: "search".to_string(),
        title: Some("Search Docs".to_string()),
        description: Some("Search docs".to_string()),
        input_schema: serde_json::json!({ "type": "object" }),
        output_schema: None,
        annotations: None,
        icons: None,
        meta: None,
      },
    )]),
    resources: vec![McpResource {
      name: "overview".to_string(),
      uri: "docs://overview".to_string(),
      description: Some("Docs overview".to_string()),
      mime_type: Some("text/markdown".to_string()),
      title: None,
      size: None,
      annotations: None,
      icons: None,
      meta: None,
    }],
    resource_templates: vec![McpResourceTemplate {
      name: "topic".to_string(),
      uri_template: "docs://topics/{name}".to_string(),
      title: Some("Topic".to_string()),
      description: Some("Topic template".to_string()),
      mime_type: Some("text/markdown".to_string()),
      annotations: None,
    }],
    auth_status: McpAuthStatus::OAuth,
  };

  let tools = flatten_mcp_tools(&[status]).expect("tools should flatten");

  assert_eq!(tools.len(), 1);
  assert_eq!(
    tools.get("docs__search").map(|tool| tool.name.as_str()),
    Some("search")
  );
}
