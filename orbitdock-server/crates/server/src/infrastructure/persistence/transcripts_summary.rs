use std::fs::File;
use std::io::{BufRead, BufReader};

use serde_json::Value;

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
