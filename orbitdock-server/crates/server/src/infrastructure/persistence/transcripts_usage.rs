use std::fs::File;
use std::io::{BufRead, BufReader};

use orbitdock_protocol::TokenUsage;
use serde_json::Value;

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

pub(crate) fn load_token_usage_from_transcript(
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

pub async fn load_token_usage_from_transcript_path(
  transcript_path: &str,
) -> Result<Option<TokenUsage>, anyhow::Error> {
  let transcript_path = transcript_path.to_string();
  tokio::task::spawn_blocking(move || load_token_usage_from_transcript(&transcript_path)).await?
}
