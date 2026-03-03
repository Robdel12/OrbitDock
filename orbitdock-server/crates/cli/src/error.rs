use serde::{Deserialize, Serialize};

/// Exit codes for the CLI.
pub const EXIT_SUCCESS: i32 = 0;
pub const EXIT_CLIENT_ERROR: i32 = 1;
pub const EXIT_SERVER_ERROR: i32 = 2;
pub const EXIT_CONNECTION_ERROR: i32 = 3;

/// Structured error from the server API.
#[derive(Debug, Deserialize, Serialize)]
pub struct ApiError {
    pub code: String,
    pub error: String,
}

/// Unified CLI error for JSON output.
#[derive(Debug, Serialize)]
pub struct CliError {
    pub error: bool,
    pub code: String,
    pub message: String,
}

impl CliError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            error: true,
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn connection(message: impl Into<String>) -> Self {
        Self::new("connection_error", message)
    }
}
