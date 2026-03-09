use super::*;
use std::fs::File;
use std::io::{BufRead, BufReader};

struct ParsedItem {
    message_type: MessageType,
    content: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    tool_output: Option<String>,
    tool_use_id: Option<String>,
    images: Vec<orbitdock_protocol::ImageInput>,
}

fn role_to_message_type(role: &str) -> MessageType {
    if role == "user" {
        MessageType::User
    } else {
        MessageType::Assistant
    }
}

fn extract_content_items(content: &Value, role: &str) -> Vec<ParsedItem> {
    if let Some(text) = content.as_str() {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return vec![ParsedItem {
                message_type: role_to_message_type(role),
                content: trimmed.to_string(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                tool_use_id: None,
                images: vec![],
            }];
        }
        return vec![];
    }

    let Some(items_array) = content.as_array() else {
        return vec![];
    };

    let mut parsed_items = Vec::new();
    let mut text_parts = Vec::new();
    let mut images = Vec::new();

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
            "image" => {
                if let Some(source) = item.get("source") {
                    let source_type = source
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    if source_type == "base64" {
                        let media_type = source
                            .get("media_type")
                            .and_then(Value::as_str)
                            .unwrap_or("image/png");
                        if let Some(data) = source.get("data").and_then(Value::as_str) {
                            images.push(orbitdock_protocol::ImageInput {
                                input_type: "url".to_string(),
                                value: format!("data:{media_type};base64,{data}"),
                                ..Default::default()
                            });
                        }
                    } else if source_type == "url" {
                        if let Some(url) = source.get("url").and_then(Value::as_str) {
                            images.push(orbitdock_protocol::ImageInput {
                                input_type: "url".to_string(),
                                value: url.to_string(),
                                ..Default::default()
                            });
                        }
                    }
                }
            }
            "input_image" => {
                if let Some(url) = item.get("image_url").and_then(Value::as_str) {
                    images.push(orbitdock_protocol::ImageInput {
                        input_type: "url".to_string(),
                        value: url.to_string(),
                        ..Default::default()
                    });
                }
            }
            "thinking" => {
                if let Some(text) = item.get("thinking").and_then(Value::as_str) {
                    let trimmed = text.trim();
                    if !trimmed.is_empty() {
                        parsed_items.push(ParsedItem {
                            message_type: MessageType::Thinking,
                            content: trimmed.to_string(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            tool_use_id: None,
                            images: vec![],
                        });
                    }
                }
            }
            "tool_use" => {
                parsed_items.push(ParsedItem {
                    message_type: MessageType::Tool,
                    content: String::new(),
                    tool_name: item
                        .get("name")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| Some("unknown".to_string())),
                    tool_input: item.get("input").map(|value| value.to_string()),
                    tool_output: None,
                    tool_use_id: item.get("id").and_then(Value::as_str).map(str::to_string),
                    images: vec![],
                });
            }
            "tool_result" => {
                parsed_items.push(ParsedItem {
                    message_type: MessageType::Tool,
                    content: String::new(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: Some(
                        item.get("content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    ),
                    tool_use_id: item
                        .get("tool_use_id")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    images: vec![],
                });
            }
            _ => {}
        }
    }

    if !text_parts.is_empty() || !images.is_empty() {
        parsed_items.insert(
            0,
            ParsedItem {
                message_type: role_to_message_type(role),
                content: text_parts.join("\n\n"),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                tool_use_id: None,
                images,
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
) -> Result<Vec<Message>, anyhow::Error> {
    let file = match File::open(transcript_path) {
        Ok(file) => file,
        Err(_) => return Ok(Vec::new()),
    };
    let reader = BufReader::new(file);

    let mut messages: Vec<Message> = Vec::new();
    let mut message_counter: usize = 0;
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
            .unwrap_or("0")
            .to_string();

        for item in items {
            if item.tool_output.is_some() && item.tool_name.is_none() {
                if let Some(tool_use_id) = &item.tool_use_id {
                    if let Some(&index) = tool_use_index.get(tool_use_id) {
                        messages[index].tool_output = item.tool_output;
                        continue;
                    }
                }
            }

            let message_index = messages.len();
            if item.tool_name.is_some() {
                if let Some(tool_use_id) = &item.tool_use_id {
                    tool_use_index.insert(tool_use_id.clone(), message_index);
                }
            }

            messages.push(Message {
                id: format!("{session_id}:transcript:{message_counter}"),
                session_id: session_id.to_string(),
                sequence: Some(message_counter as u64),
                message_type: item.message_type,
                content: item.content,
                timestamp: timestamp.clone(),
                tool_name: item.tool_name,
                tool_input: item.tool_input,
                tool_output: item.tool_output,
                duration_ms: None,
                is_error: false,
                is_in_progress: false,
                images: item.images,
            });
            message_counter += 1;
        }
    }

    Ok(messages)
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
) -> Result<Vec<Message>, anyhow::Error> {
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
