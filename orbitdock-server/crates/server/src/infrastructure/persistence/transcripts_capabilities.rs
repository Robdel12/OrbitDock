use std::fs::File;
use std::io::{BufRead, BufReader};

use serde_json::Value;

pub struct TranscriptCapabilities {
  pub slash_commands: Vec<String>,
  pub skills: Vec<String>,
  pub tools: Vec<String>,
}

pub(crate) fn load_capabilities_from_transcript(
  transcript_path: &str,
) -> Option<TranscriptCapabilities> {
  let file = File::open(transcript_path).ok()?;
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
}

pub async fn load_capabilities_from_transcript_path(
  transcript_path: &str,
) -> Option<TranscriptCapabilities> {
  let transcript_path = transcript_path.to_string();
  tokio::task::spawn_blocking(move || load_capabilities_from_transcript(&transcript_path))
    .await
    .ok()
    .flatten()
}

pub(crate) fn load_latest_codex_turn_context_settings_from_transcript(
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

pub async fn load_latest_codex_turn_context_settings_from_transcript_path(
  transcript_path: &str,
) -> Result<(Option<String>, Option<String>), anyhow::Error> {
  let transcript_path = transcript_path.to_string();
  tokio::task::spawn_blocking(move || {
    load_latest_codex_turn_context_settings_from_transcript(&transcript_path)
  })
  .await?
}
