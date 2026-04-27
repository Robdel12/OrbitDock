pub mod human;
pub mod json;

use chrono::{DateTime, TimeZone, Utc};

use crate::client::config::ClientConfig;
use crate::error::CliError;

/// Truncate a string to `max_chars` characters, appending "..." if truncated.
/// Safe for multi-byte UTF-8 — never splits a character boundary.
pub fn truncate(s: &str, max_chars: usize) -> String {
  let suffix = "...";
  let limit = max_chars.saturating_sub(suffix.len());
  let char_count = s.chars().count();
  if char_count <= max_chars {
    s.to_string()
  } else {
    let truncated: String = s.chars().take(limit).collect();
    format!("{truncated}{suffix}")
  }
}

pub fn relative_time_label(value: Option<&str>) -> Option<String> {
  relative_time_label_at(Utc::now(), value)
}

fn relative_time_label_at(now: DateTime<Utc>, value: Option<&str>) -> Option<String> {
  let timestamp = parse_timestamp(value?)?;
  Some(format_relative_time(now, timestamp))
}

fn parse_timestamp(value: &str) -> Option<DateTime<Utc>> {
  if let Ok(timestamp) = DateTime::parse_from_rfc3339(value) {
    return Some(timestamp.with_timezone(&Utc));
  }

  let stripped = value.strip_suffix('Z')?;
  if let Ok(seconds) = stripped.parse::<i64>() {
    return Utc.timestamp_opt(seconds, 0).single();
  }

  let seconds = stripped.parse::<f64>().ok()?;
  let whole_seconds = seconds.trunc() as i64;
  let nanos = ((seconds.fract() * 1_000_000_000.0).round() as u32).min(999_999_999);
  Utc.timestamp_opt(whole_seconds, nanos).single()
}

fn format_relative_time(now: DateTime<Utc>, timestamp: DateTime<Utc>) -> String {
  let delta = now.signed_duration_since(timestamp);
  if delta.num_seconds() < 0 {
    return "soon".to_string();
  }

  let seconds = delta.num_seconds();
  if seconds < 60 {
    "just now".to_string()
  } else if seconds < 3_600 {
    format!("{}m ago", seconds / 60)
  } else if seconds < 86_400 {
    format!("{}h ago", seconds / 3_600)
  } else if seconds < 604_800 {
    format!("{}d ago", seconds / 86_400)
  } else if seconds < 2_592_000 {
    format!("{}w ago", seconds / 604_800)
  } else if seconds < 31_536_000 {
    format!("{}mo ago", seconds / 2_592_000)
  } else {
    format!("{}y ago", seconds / 31_536_000)
  }
}

/// Determines output mode and provides helpers.
pub struct Output {
  pub json: bool,
}

impl Output {
  pub fn new(config: &ClientConfig) -> Self {
    Self { json: config.json }
  }

  /// Print a value as JSON.
  pub fn print_json<T: serde::Serialize>(&self, value: &T) {
    // Keep compact JSON for stream-style output where one object per line matters.
    let stdout = std::io::stdout();
    let _ = serde_json::to_writer(stdout.lock(), value);
    println!();
  }

  /// Print a value as pretty JSON for one-shot responses.
  pub fn print_json_pretty<T: serde::Serialize>(&self, value: &T) {
    let stdout = std::io::stdout();
    let _ = serde_json::to_writer_pretty(stdout.lock(), value);
    println!();
  }

  /// Print a CLI error (JSON mode or stderr).
  pub fn print_error(&self, err: &CliError) {
    if self.json {
      self.print_json(err);
    } else {
      let style = console::Style::new().red().bold();
      eprintln!("{}: {}", style.apply_to("error"), err.message);
    }
  }
}

#[cfg(test)]
mod tests;
