//! Shell executor for user-initiated commands.
//!
//! Runs commands in a session's working directory and captures output.
//! Provider-independent — works alongside any AI session.

use std::process::Stdio;
use std::time::Instant;

use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// Result of a shell command execution
pub struct ShellResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
}

/// Incremental shell output chunk.
#[derive(Debug, Clone)]
pub struct ShellChunk {
    pub stdout: String,
    pub stderr: String,
}

/// Execute a shell command and optionally stream incremental output chunks.
pub async fn execute_with_stream(
    command: &str,
    cwd: &str,
    timeout_secs: u64,
    chunk_tx: Option<mpsc::UnboundedSender<ShellChunk>>,
) -> ShellResult {
    let start = Instant::now();

    let result = run_command(command, cwd, timeout_secs, chunk_tx).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok((stdout, stderr, exit_code)) => ShellResult {
            stdout,
            stderr,
            exit_code: Some(exit_code),
            duration_ms,
        },
        Err(RunCommandError::Io(e)) => ShellResult {
            stdout: String::new(),
            stderr: format!("Failed to execute command: {e}"),
            exit_code: None,
            duration_ms,
        },
        Err(RunCommandError::Timeout { stdout, stderr }) => {
            let timeout_msg = format!("Command timed out after {timeout_secs}s");
            let stderr = if stderr.is_empty() {
                timeout_msg
            } else {
                format!("{stderr}\n{timeout_msg}")
            };
            ShellResult {
                stdout,
                stderr,
                exit_code: None,
                duration_ms,
            }
        }
    }
}

enum RunCommandError {
    Io(std::io::Error),
    Timeout { stdout: String, stderr: String },
}

enum StreamKind {
    Stdout,
    Stderr,
}

async fn run_command(
    command: &str,
    cwd: &str,
    timeout_secs: u64,
    chunk_tx: Option<mpsc::UnboundedSender<ShellChunk>>,
) -> Result<(String, String, i32), RunCommandError> {
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(command)
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(RunCommandError::Io)?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| RunCommandError::Io(std::io::Error::other("stdout pipe unavailable")))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| RunCommandError::Io(std::io::Error::other("stderr pipe unavailable")))?;

    let stdout_task = tokio::spawn(read_stream(stdout, StreamKind::Stdout, chunk_tx.clone()));
    let stderr_task = tokio::spawn(read_stream(stderr, StreamKind::Stderr, chunk_tx));

    let status = match tokio::time::timeout(
        std::time::Duration::from_secs(timeout_secs),
        child.wait(),
    )
    .await
    {
        Ok(Ok(status)) => Some(status),
        Ok(Err(e)) => return Err(RunCommandError::Io(e)),
        Err(_) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            None
        }
    };

    let stdout = join_reader(stdout_task).await?;
    let stderr = join_reader(stderr_task).await?;

    match status {
        Some(status) => Ok((stdout, stderr, status.code().unwrap_or(-1))),
        None => Err(RunCommandError::Timeout { stdout, stderr }),
    }
}

async fn read_stream<R>(
    mut reader: R,
    stream_kind: StreamKind,
    chunk_tx: Option<mpsc::UnboundedSender<ShellChunk>>,
) -> Result<String, std::io::Error>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut full_output = String::new();
    let mut buf = [0u8; 4096];

    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            break;
        }

        let chunk = String::from_utf8_lossy(&buf[..n]).into_owned();
        full_output.push_str(&chunk);

        if let Some(tx) = &chunk_tx {
            let _ = match stream_kind {
                StreamKind::Stdout => tx.send(ShellChunk {
                    stdout: chunk,
                    stderr: String::new(),
                }),
                StreamKind::Stderr => tx.send(ShellChunk {
                    stdout: String::new(),
                    stderr: chunk,
                }),
            };
        }
    }

    Ok(full_output)
}

async fn join_reader(
    handle: JoinHandle<Result<String, std::io::Error>>,
) -> Result<String, RunCommandError> {
    match handle.await {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(err)) => Err(RunCommandError::Io(err)),
        Err(join_err) => Err(RunCommandError::Io(std::io::Error::other(format!(
            "shell stream task failed: {join_err}"
        )))),
    }
}
