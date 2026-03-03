pub mod human;
pub mod json;

use crate::client::config::ClientConfig;
use crate::error::CliError;

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
