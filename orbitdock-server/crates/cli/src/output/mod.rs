pub mod human;
pub mod json;

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
        // serde_json::to_writer is faster than to_string for stdout
        let stdout = std::io::stdout();
        let _ = serde_json::to_writer(stdout.lock(), value);
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
