use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum StdinMessage {
  User {
    session_id: String,
    message: UserMessagePayload,
    #[serde(skip_serializing_if = "Option::is_none")]
    parent_tool_use_id: Option<String>,
  },
  ControlRequest {
    request_id: String,
    request: ControlRequestBody,
  },
  ControlResponse {
    response: ControlResponsePayload,
  },
}

#[derive(Debug, Serialize)]
pub(crate) struct UserMessagePayload {
  pub(crate) role: &'static str,
  pub(crate) content: Vec<UserContentBlock>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum UserContentBlock {
  Text { text: String },
  Image { source: ImageSource },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum ImageSource {
  Base64 {
    media_type: String,
    data: String,
  },
  #[serde(rename = "url")]
  Url {
    url: String,
  },
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
pub(crate) enum ControlRequestBody {
  Initialize {
    #[serde(skip_serializing_if = "Option::is_none")]
    system_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    append_system_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_suggestions: Option<bool>,
    /// Hook callback registrations: `{ hookEvent: [{ matcher?, hookCallbackIds, timeout? }] }`
    #[serde(skip_serializing_if = "Option::is_none")]
    hooks: Option<Value>,
    /// MCP servers registered by the SDK host (server names)
    #[serde(rename = "sdkMcpServers", skip_serializing_if = "Option::is_none")]
    sdk_mcp_servers: Option<Vec<String>>,
    /// Custom JSON schemas
    #[serde(rename = "jsonSchema", skip_serializing_if = "Option::is_none")]
    json_schema: Option<Value>,
    /// Agent definitions
    #[serde(skip_serializing_if = "Option::is_none")]
    agents: Option<Value>,
  },
  Interrupt,
  SetModel {
    model: Option<String>,
  },
  SetMaxThinkingTokens {
    max_thinking_tokens: Option<u64>,
  },
  SetPermissionMode {
    mode: String,
  },
  RewindFiles {
    user_message_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    dry_run: Option<bool>,
  },
  StopTask {
    task_id: String,
  },
  McpStatus {},
  McpReconnect {
    #[serde(rename = "serverName")]
    server_name: String,
  },
  McpToggle {
    #[serde(rename = "serverName")]
    server_name: String,
    enabled: bool,
  },
  McpAuthenticate {
    #[serde(rename = "serverName")]
    server_name: String,
  },
  McpClearAuth {
    #[serde(rename = "serverName")]
    server_name: String,
  },
  McpSetServers {
    servers: Value,
  },
  ApplyFlagSettings {
    settings: Value,
  },
  GetSettings {},
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
#[allow(dead_code)]
pub(crate) enum ControlResponsePayload {
  Success { request_id: String, response: Value },
  Error { request_id: String, error: String },
}

/// Format structured question answers for the Claude SDK.
///
/// The SDK's `AskUserQuestion` expects the deny message to contain the user's
/// answer. For simple single-answer cases, send the answer text directly.
/// For structured multi-question answers, format as JSON matching
/// `AskUserQuestionOutput.answers` format: `{ question_text: "value" }`.
pub(crate) fn format_question_answers(answers: &HashMap<String, Vec<String>>) -> String {
  if answers.len() == 1 {
    if let Some(values) = answers.values().next() {
      if values.len() == 1 {
        return values[0].clone();
      }
      if !values.is_empty() {
        return values.join(", ");
      }
    }
  }

  let mut answers_map = serde_json::Map::new();
  for (key, values) in answers {
    answers_map.insert(key.clone(), Value::String(values.join(", ")));
  }
  serde_json::to_string(&answers_map).unwrap_or_default()
}
