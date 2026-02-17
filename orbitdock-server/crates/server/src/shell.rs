//! Shell executor for user-initiated commands.
//!
//! Runs commands in a session's working directory and captures output.
//! Provider-independent — works alongside any AI session.

use std::time::Instant;

use tokio::process::Command;

/// Result of a shell command execution
pub struct ShellResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
}

/// Execute a shell command with timeout.
///
/// Spawns `sh -c <command>` in the given `cwd` directory and captures
/// stdout + stderr. Returns after the process exits or the timeout fires.
pub async fn execute(command: &str, cwd: &str, timeout_secs: u64) -> ShellResult {
    let start = Instant::now();

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(timeout_secs),
        run_command(command, cwd),
    )
    .await;

    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(Ok((stdout, stderr, exit_code))) => ShellResult {
            stdout,
            stderr,
            exit_code: Some(exit_code),
            duration_ms,
        },
        Ok(Err(e)) => ShellResult {
            stdout: String::new(),
            stderr: format!("Failed to execute command: {e}"),
            exit_code: None,
            duration_ms,
        },
        Err(_) => ShellResult {
            stdout: String::new(),
            stderr: format!("Command timed out after {timeout_secs}s"),
            exit_code: None,
            duration_ms,
        },
    }
}

async fn run_command(command: &str, cwd: &str) -> Result<(String, String, i32), std::io::Error> {
    let output = Command::new("sh")
        .arg("-c")
        .arg(command)
        .current_dir(cwd)
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let exit_code = output.status.code().unwrap_or(-1);

    Ok((stdout, stderr, exit_code))
}
