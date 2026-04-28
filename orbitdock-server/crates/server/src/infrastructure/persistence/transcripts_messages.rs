use std::fs::File;
use std::io::{BufRead, BufReader};

use codex_protocol::models::FunctionCallOutputPayload;
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::tool_display::{
  classify_tool_name, compute_tool_display, ToolDisplayInput,
};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::Value;

enum ParsedItem {
  Message {
    role: ParsedRole,
    content: String,
  },
  Tool {
    tool_name: String,
    tool_input: Option<serde_json::Value>,
    tool_use_id: Option<String>,
  },
  ToolResult {
    tool_use_id: Option<String>,
    tool_output: String,
  },
}

#[derive(Clone, Copy)]
enum ParsedRole {
  User,
  Assistant,
  Thinking,
}

fn role_from_str(role: &str) -> ParsedRole {
  if role == "user" {
    ParsedRole::User
  } else {
    ParsedRole::Assistant
  }
}

fn classify_tool(name: &str) -> (ToolFamily, ToolKind) {
  classify_tool_name(name)
}

fn normalize_function_arguments(arguments: &str) -> serde_json::Value {
  serde_json::from_str(arguments).unwrap_or_else(|_| serde_json::json!({ "raw": arguments }))
}

fn extract_function_call_output_text(output: &Value) -> String {
  serde_json::from_value::<FunctionCallOutputPayload>(output.clone())
    .ok()
    .and_then(|payload| payload.body.to_text())
    .filter(|text| !text.trim().is_empty())
    .or_else(|| match output {
      Value::String(text) => Some(text.clone()),
      Value::Array(items) => {
        let text = items
          .iter()
          .filter_map(|item| {
            let kind = item.get("type").and_then(Value::as_str).unwrap_or_default();
            match kind {
              "text" | "input_text" | "output_text" | "summary_text" => item
                .get("text")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(str::to_string),
              _ => None,
            }
          })
          .collect::<Vec<_>>()
          .join("\n");
        (!text.is_empty()).then_some(text)
      }
      _ => None,
    })
    .unwrap_or_else(|| serde_json::to_string(output).unwrap_or_default())
}

fn extract_content_items(content: &Value, role: &str) -> Vec<ParsedItem> {
  if let Some(text) = content.as_str() {
    let trimmed = text.trim();
    if !trimmed.is_empty() {
      return vec![ParsedItem::Message {
        role: role_from_str(role),
        content: trimmed.to_string(),
      }];
    }
    return vec![];
  }

  let Some(items_array) = content.as_array() else {
    return vec![];
  };

  let mut parsed_items = Vec::new();
  let mut text_parts = Vec::new();

  for item in items_array {
    let kind = item.get("type").and_then(Value::as_str).unwrap_or_default();
    match kind {
      "text" | "input_text" | "output_text" | "summary_text" => {
        if let Some(text) = item.get("text").and_then(Value::as_str) {
          let trimmed = text.trim();
          if !trimmed.is_empty() {
            text_parts.push(trimmed.to_string());
          }
        }
      }
      "image" | "input_image" => {}
      "thinking" => {
        if let Some(text) = item.get("thinking").and_then(Value::as_str) {
          let trimmed = text.trim();
          if !trimmed.is_empty() {
            parsed_items.push(ParsedItem::Message {
              role: ParsedRole::Thinking,
              content: trimmed.to_string(),
            });
          }
        }
      }
      "tool_use" => {
        let tool_name = item
          .get("name")
          .and_then(Value::as_str)
          .unwrap_or("unknown")
          .to_string();
        let tool_input = item.get("input").cloned();
        let tool_use_id = item.get("id").and_then(Value::as_str).map(str::to_string);
        parsed_items.push(ParsedItem::Tool {
          tool_name,
          tool_input,
          tool_use_id,
        });
      }
      "tool_result" => {
        let tool_output = item
          .get("content")
          .and_then(Value::as_str)
          .unwrap_or("")
          .to_string();
        let tool_use_id = item
          .get("tool_use_id")
          .and_then(Value::as_str)
          .map(str::to_string);
        parsed_items.push(ParsedItem::ToolResult {
          tool_use_id,
          tool_output,
        });
      }
      _ => {}
    }
  }

  if !text_parts.is_empty() {
    parsed_items.insert(
      0,
      ParsedItem::Message {
        role: role_from_str(role),
        content: text_parts.join("\n\n"),
      },
    );
  }

  parsed_items
}

fn extract_entry_messages(entry: &Value) -> Vec<ParsedItem> {
  let entry_type = match entry.get("type").and_then(Value::as_str) {
    Some(entry_type) => entry_type,
    None => return vec![],
  };

  if entry_type == "response_item" {
    if let Some(payload) = entry.get("payload") {
      match payload.get("type").and_then(Value::as_str) {
        Some("message") => {
          let role = payload
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("assistant");
          if let Some(content) = payload.get("content") {
            return extract_content_items(content, role);
          }
        }
        Some("function_call") => {
          let tool_name = payload
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
          let tool_input = payload
            .get("arguments")
            .and_then(Value::as_str)
            .map(normalize_function_arguments)
            .or_else(|| payload.get("arguments").cloned());
          let tool_use_id = payload
            .get("call_id")
            .and_then(Value::as_str)
            .map(str::to_string);
          return vec![ParsedItem::Tool {
            tool_name,
            tool_input,
            tool_use_id,
          }];
        }
        Some("function_call_output") => {
          let tool_use_id = payload
            .get("call_id")
            .and_then(Value::as_str)
            .map(str::to_string);
          let tool_output = payload
            .get("output")
            .map(extract_function_call_output_text)
            .unwrap_or_default();
          return vec![ParsedItem::ToolResult {
            tool_use_id,
            tool_output,
          }];
        }
        Some("tool_search_call") => {
          let tool_use_id = payload
            .get("call_id")
            .and_then(Value::as_str)
            .map(str::to_string);
          let tool_input = payload.get("arguments").cloned();
          return vec![ParsedItem::Tool {
            tool_name: "ToolSearch".to_string(),
            tool_input,
            tool_use_id,
          }];
        }
        Some("tool_search_output") => {
          let tool_use_id = payload
            .get("call_id")
            .and_then(Value::as_str)
            .map(str::to_string);
          let tool_output = payload
            .get("tools")
            .map(|tools| {
              serde_json::to_string_pretty(tools)
                .or_else(|_| serde_json::to_string(tools))
                .unwrap_or_default()
            })
            .unwrap_or_default();
          return vec![ParsedItem::ToolResult {
            tool_use_id,
            tool_output,
          }];
        }
        _ => {}
      }
    }
    return vec![];
  }

  if entry_type == "message" {
    let role = match entry.get("role").and_then(Value::as_str) {
      Some(role) => role,
      None => return vec![],
    };
    if let Some(content) = entry.get("content") {
      return extract_content_items(content, role);
    }
    return vec![];
  }

  let message = match entry.get("message") {
    Some(message) => message,
    None => return vec![],
  };
  let role = match message.get("role").and_then(Value::as_str) {
    Some(role) => role,
    None => return vec![],
  };
  let content = match message.get("content") {
    Some(content) => content,
    None => return vec![],
  };
  extract_content_items(content, role)
}

pub(crate) fn load_messages_from_transcript(
  transcript_path: &str,
  session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
  let file = match File::open(transcript_path) {
    Ok(file) => file,
    Err(_) => return Ok(Vec::new()),
  };
  let reader = BufReader::new(file);

  let mut rows: Vec<ConversationRowEntry> = Vec::new();
  let mut sequence: u64 = 0;
  let mut tool_use_index: std::collections::HashMap<String, usize> =
    std::collections::HashMap::new();

  for line_result in reader.lines() {
    let line = match line_result {
      Ok(line) => line,
      Err(_) => continue,
    };
    let trimmed = line.trim();
    if trimmed.is_empty() {
      continue;
    }

    let value: Value = match serde_json::from_str(trimmed) {
      Ok(value) => value,
      Err(_) => continue,
    };

    let items = extract_entry_messages(&value);
    if items.is_empty() {
      continue;
    }

    let timestamp = value
      .get("timestamp")
      .and_then(Value::as_str)
      .map(str::to_string);

    for item in items {
      match item {
        ParsedItem::ToolResult {
          tool_use_id,
          tool_output,
        } => {
          if let Some(id) = &tool_use_id {
            if let Some(&index) = tool_use_index.get(id) {
              if let ConversationRow::Tool(ref mut tool_row) = rows[index].row {
                let tool_name = tool_row
                  .invocation
                  .get("tool_name")
                  .and_then(|value| value.as_str())
                  .map(str::to_string)
                  .unwrap_or_else(|| tool_row.title.clone());
                tool_row.result = Some(serde_json::json!({
                    "tool_name": tool_name,
                    "raw_output": tool_output,
                }));
                let input = tool_row.invocation.get("raw_input");
                tool_row.tool_display = Some(compute_tool_display(ToolDisplayInput {
                  kind: tool_row.kind,
                  family: tool_row.family,
                  status: ToolStatus::Completed,
                  title: &tool_row.title,
                  subtitle: None,
                  summary: None,
                  duration_ms: None,
                  invocation_input: input,
                  result_output: Some(&tool_output),
                }));
                continue;
              }
            }
          }

          let row_id = tool_use_id
            .clone()
            .unwrap_or_else(|| format!("{session_id}:transcript:{sequence}"));
          let row_index = rows.len();
          if let Some(id) = &tool_use_id {
            tool_use_index.insert(id.clone(), row_index);
          }
          let td = Some(compute_tool_display(ToolDisplayInput {
            kind: ToolKind::Generic,
            family: ToolFamily::Generic,
            status: ToolStatus::Completed,
            title: "Tool",
            subtitle: None,
            summary: None,
            duration_ms: None,
            invocation_input: None,
            result_output: Some(&tool_output),
          }));
          rows.push(ConversationRowEntry {
            session_id: String::new(),
            sequence,
            turn_id: None,
            turn_status: Default::default(),
            row: ConversationRow::Tool(ToolRow {
              id: row_id,
              provider: Provider::Claude,
              family: ToolFamily::Generic,
              kind: ToolKind::Generic,
              status: ToolStatus::Completed,
              title: "unknown".to_string(),
              subtitle: None,
              summary: None,
              preview: None,
              started_at: None,
              ended_at: None,
              duration_ms: None,
              grouping_key: None,
              invocation: serde_json::json!({
                  "tool_name": "unknown",
              }),
              result: Some(serde_json::json!({
                  "tool_name": "unknown",
                  "raw_output": tool_output,
              })),
              render_hints: RenderHints::default(),
              tool_display: td,
              shell_execution: None,
            }),
          });
          sequence += 1;
        }
        ParsedItem::Tool {
          tool_name,
          tool_input,
          tool_use_id,
        } => {
          let (family, kind) = classify_tool(&tool_name);
          let row_id = tool_use_id
            .clone()
            .unwrap_or_else(|| format!("{session_id}:transcript:{sequence}"));
          let row_index = rows.len();
          if let Some(id) = &tool_use_id {
            tool_use_index.insert(id.clone(), row_index);
          }
          let td = Some(compute_tool_display(ToolDisplayInput {
            kind,
            family,
            status: ToolStatus::Completed,
            title: &tool_name,
            subtitle: None,
            summary: None,
            duration_ms: None,
            invocation_input: tool_input.as_ref(),
            result_output: None,
          }));
          rows.push(ConversationRowEntry {
            session_id: String::new(),
            sequence,
            turn_id: None,
            turn_status: Default::default(),
            row: ConversationRow::Tool(ToolRow {
              id: row_id,
              provider: Provider::Claude,
              family,
              kind,
              status: ToolStatus::Completed,
              title: tool_name.clone(),
              subtitle: None,
              summary: None,
              preview: None,
              started_at: None,
              ended_at: None,
              duration_ms: None,
              grouping_key: None,
              invocation: serde_json::json!({
                  "tool_name": tool_name,
                  "raw_input": tool_input,
              }),
              result: None,
              render_hints: RenderHints::default(),
              tool_display: td,
              shell_execution: None,
            }),
          });
          sequence += 1;
        }
        ParsedItem::Message { role, content } => {
          let row_id = format!("{session_id}:transcript:{sequence}");
          let msg = MessageRowContent {
            id: row_id,
            content,
            turn_id: None,
            timestamp: timestamp.clone(),
            is_streaming: false,
            images: vec![],
            memory_citation: None,
            delivery_status: None,
          };
          let conversation_row = match role {
            ParsedRole::User => ConversationRow::User(msg),
            ParsedRole::Assistant => ConversationRow::Assistant(msg),
            ParsedRole::Thinking => ConversationRow::Thinking(msg),
          };
          let conversation_row =
            crate::domain::conversation_semantics::upgrade_row(Provider::Claude, conversation_row);
          rows.push(ConversationRowEntry {
            session_id: String::new(),
            sequence,
            turn_id: None,
            turn_status: Default::default(),
            row: conversation_row,
          });
          sequence += 1;
        }
      }
    }
  }

  Ok(rows)
}

pub async fn load_messages_from_transcript_path(
  transcript_path: &str,
  session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
  let transcript_path = transcript_path.to_string();
  let session_id = session_id.to_string();
  tokio::task::spawn_blocking(move || load_messages_from_transcript(&transcript_path, &session_id))
    .await?
}
