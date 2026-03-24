use super::*;
use std::fs::File;
use std::io::{BufRead, BufReader};

use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::tool_display::{
    classify_tool_name, compute_tool_display, ToolDisplayInput,
};
use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;

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

/// Classify a tool name — delegates to the shared classifier in orbitdock_protocol.
fn classify_tool(name: &str) -> (ToolFamily, ToolKind) {
    classify_tool_name(name)
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
            // Images are not modelled in ConversationRow message content;
            // skip them for now (they were only used for the old Message.images field).
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
            if payload.get("type").and_then(Value::as_str) == Some("message") {
                let role = payload
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("assistant");
                if let Some(content) = payload.get("content") {
                    return extract_content_items(content, role);
                }
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
                    // Try to attach the result to the matching tool row.
                    if let Some(id) = &tool_use_id {
                        if let Some(&index) = tool_use_index.get(id) {
                            if let ConversationRow::Tool(ref mut tool_row) = rows[index].row {
                                let tool_name = tool_row
                                    .invocation
                                    .get("tool_name")
                                    .and_then(|v| v.as_str())
                                    .map(str::to_string)
                                    .unwrap_or_else(|| tool_row.title.clone());
                                tool_row.result = Some(serde_json::json!({
                                    "tool_name": tool_name,
                                    "raw_output": tool_output,
                                }));
                                // Recompute tool_display with result data
                                let input = tool_row.invocation.get("raw_input");
                                tool_row.tool_display =
                                    Some(compute_tool_display(ToolDisplayInput {
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
                    // No matching tool_use found — create a standalone tool row.
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
                    let conversation_row = crate::domain::conversation_semantics::upgrade_row(
                        Provider::Claude,
                        conversation_row,
                    );
                    rows.push(ConversationRowEntry {
                        session_id: String::new(),
                        sequence,
                        turn_id: None,
                        row: conversation_row,
                    });
                    sequence += 1;
                }
            }
        }
    }

    Ok(rows)
}

pub(crate) fn extract_summary_from_transcript(transcript_path: &str) -> Option<String> {
    let file = File::open(transcript_path).ok()?;
    let reader = BufReader::new(file);
    let mut last_summary = None;

    for line_result in reader.lines() {
        let line = match line_result {
            Ok(line) => line,
            Err(_) => continue,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() || !trimmed.contains("\"type\":\"summary\"") {
            continue;
        }

        let value: Value = match serde_json::from_str(trimmed) {
            Ok(value) => value,
            Err(_) => continue,
        };

        if value.get("type").and_then(Value::as_str) == Some("summary") {
            if let Some(summary) = value.get("summary").and_then(Value::as_str) {
                if !summary.is_empty() {
                    last_summary = Some(summary.to_string());
                }
            }
        }
    }

    last_summary
}

pub async fn extract_summary_from_transcript_path(transcript_path: &str) -> Option<String> {
    let transcript_path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || extract_summary_from_transcript(&transcript_path))
        .await
        .ok()
        .flatten()
}

fn value_to_u64(value: Option<&Value>) -> u64 {
    match value {
        Some(Value::Number(number)) => number
            .as_u64()
            .or_else(|| number.as_i64().map(|value| value.max(0) as u64))
            .unwrap_or(0),
        Some(Value::String(text)) => text.parse::<u64>().unwrap_or(0),
        _ => 0,
    }
}

fn load_token_usage_from_transcript(
    transcript_path: &str,
) -> Result<Option<TokenUsage>, anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok(None),
    };
    let reader = BufReader::new(file);

    let mut claude_usage = TokenUsage::default();
    let mut saw_claude_usage = false;
    let mut codex_usage = None;

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

        let entry_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();

        if entry_type == "assistant" {
            if let Some(usage) = value
                .get("message")
                .and_then(|message| message.get("usage"))
                .and_then(Value::as_object)
            {
                saw_claude_usage = true;
                claude_usage.input_tokens = value_to_u64(usage.get("input_tokens"));
                claude_usage.output_tokens += value_to_u64(usage.get("output_tokens"));
                claude_usage.cached_tokens = value_to_u64(usage.get("cache_read_input_tokens"))
                    + value_to_u64(usage.get("cache_creation_input_tokens"));
            }
            continue;
        }

        if entry_type == "event_msg" {
            let payload = match value.get("payload").and_then(Value::as_object) {
                Some(payload) => payload,
                None => continue,
            };
            if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                continue;
            }

            let info = match payload.get("info").and_then(Value::as_object) {
                Some(info) => info,
                None => continue,
            };

            let usage_object = info
                .get("last_token_usage")
                .or_else(|| info.get("total_token_usage"))
                .and_then(Value::as_object);

            if let Some(usage) = usage_object {
                codex_usage = Some(TokenUsage {
                    input_tokens: value_to_u64(usage.get("input_tokens")),
                    output_tokens: value_to_u64(usage.get("output_tokens")),
                    cached_tokens: value_to_u64(usage.get("cached_input_tokens")),
                    context_window: value_to_u64(info.get("model_context_window")),
                });
            }
        }
    }

    if let Some(usage) = codex_usage {
        return Ok(Some(usage));
    }

    if saw_claude_usage {
        return Ok(Some(claude_usage));
    }

    Ok(None)
}

fn load_latest_codex_turn_context_settings_from_transcript(
    transcript_path: &str,
) -> Result<(Option<String>, Option<String>), anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok((None, None)),
    };
    let reader = BufReader::new(file);

    let mut model = None;
    let mut effort = None;

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

        if value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            != "turn_context"
        {
            continue;
        }

        let payload = match value.get("payload").and_then(Value::as_object) {
            Some(payload) => payload,
            None => continue,
        };

        if let Some(payload_model) = payload
            .get("model")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            model = Some(payload_model.to_string());
        }

        let effort_from_payload = payload
            .get("effort")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);

        let effort_from_collaboration_mode = payload
            .get("collaboration_mode")
            .and_then(|value| value.get("settings"))
            .and_then(|value| value.get("reasoning_effort"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);

        if let Some(payload_effort) = effort_from_payload.or(effort_from_collaboration_mode) {
            effort = Some(payload_effort);
        }
    }

    Ok((model, effort))
}

pub async fn load_messages_from_transcript_path(
    transcript_path: &str,
    session_id: &str,
) -> Result<Vec<ConversationRowEntry>, anyhow::Error> {
    let transcript_path = transcript_path.to_string();
    let session_id = session_id.to_string();
    tokio::task::spawn_blocking(move || {
        load_messages_from_transcript(&transcript_path, &session_id)
    })
    .await?
}

pub async fn load_token_usage_from_transcript_path(
    transcript_path: &str,
) -> Result<Option<TokenUsage>, anyhow::Error> {
    let transcript_path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || load_token_usage_from_transcript(&transcript_path)).await?
}

pub struct TranscriptCapabilities {
    pub slash_commands: Vec<String>,
    pub skills: Vec<String>,
    pub tools: Vec<String>,
}

pub async fn load_capabilities_from_transcript_path(
    transcript_path: &str,
) -> Option<TranscriptCapabilities> {
    let transcript_path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || {
        let file = File::open(&transcript_path).ok()?;
        let reader = BufReader::new(file);

        for line_result in reader.lines() {
            let line = line_result.ok()?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let value: Value = match serde_json::from_str(trimmed) {
                Ok(value) => value,
                Err(_) => continue,
            };

            if value.get("type").and_then(Value::as_str) != Some("system")
                || value.get("subtype").and_then(Value::as_str) != Some("init")
            {
                continue;
            }

            let parse_array = |key: &str| -> Vec<String> {
                value
                    .get(key)
                    .and_then(Value::as_array)
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|item| item.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default()
            };

            return Some(TranscriptCapabilities {
                slash_commands: parse_array("slash_commands"),
                skills: parse_array("skills"),
                tools: parse_array("tools"),
            });
        }

        None
    })
    .await
    .ok()
    .flatten()
}

pub async fn load_latest_codex_turn_context_settings_from_transcript_path(
    transcript_path: &str,
) -> Result<(Option<String>, Option<String>), anyhow::Error> {
    let transcript_path = transcript_path.to_string();
    tokio::task::spawn_blocking(move || {
        load_latest_codex_turn_context_settings_from_transcript(&transcript_path)
    })
    .await?
}
