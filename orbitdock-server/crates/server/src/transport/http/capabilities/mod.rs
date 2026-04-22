use std::collections::HashMap;

use orbitdock_protocol::{
  McpAuthStatus, McpResource, McpResourceTemplate, McpTool, SkillErrorInfo, SkillsListEntry,
};
use serde::{Deserialize, Serialize};

mod common;
mod flags;
mod instructions;
mod mcp;
mod plugins;
mod skills;

pub use flags::apply_flag_settings;
pub use instructions::get_session_instructions;
pub use mcp::{
  list_mcp_tools_endpoint, mcp_authenticate, mcp_clear_auth, mcp_set_servers, refresh_mcp_servers,
  toggle_mcp_server,
};
pub use plugins::{install_plugin, list_plugins_endpoint, uninstall_plugin};
pub use skills::list_skills_endpoint;

#[derive(Debug, Serialize)]
pub struct SkillsResponse {
  pub session_id: String,
  pub skills: Vec<SkillsListEntry>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub claude_skill_names: Vec<String>,
  pub errors: Vec<SkillErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct McpToolsResponse {
  pub session_id: String,
  pub tools: HashMap<String, McpTool>,
  pub resources: HashMap<String, Vec<McpResource>>,
  pub resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
  pub auth_statuses: HashMap<String, McpAuthStatus>,
}

#[derive(Debug, Serialize)]
pub struct SessionInstructionsResponse {
  pub session_id: String,
  pub provider: orbitdock_protocol::Provider,
  pub instructions: SessionInstructionsPayload,
}

#[derive(Debug, Serialize, Default)]
pub struct SessionInstructionsPayload {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub claude_md: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub system_prompt: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RefreshMcpServerRequest {
  pub server_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct McpToggleRequest {
  pub server_name: String,
  pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct McpServerNameRequest {
  pub server_name: String,
}

#[derive(Debug, Deserialize)]
pub struct McpSetServersRequest {
  pub servers: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct ApplyFlagSettingsRequest {
  pub settings: serde_json::Value,
}

#[derive(Debug, Deserialize, Default)]
pub struct SkillsQuery {
  #[serde(default)]
  pub cwd: Vec<String>,
  #[serde(default)]
  pub force_reload: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PluginsQuery {
  #[serde(default)]
  pub cwd: Vec<String>,
}

#[cfg(test)]
mod tests;
