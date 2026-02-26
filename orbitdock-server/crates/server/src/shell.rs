//! Shell executor for user-initiated commands.
//!
//! Runs commands in a session's working directory and captures output.
//! Provider-independent - works alongside any AI session.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Instant;

use dashmap::{mapref::entry::Entry, DashMap};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;

/// Terminal shell command outcome.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellOutcome {
    Completed,
    Failed,
    TimedOut,
    Canceled,
}

/// Result of a shell command execution.
pub struct ShellResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
    pub outcome: ShellOutcome,
}

/// Incremental shell output chunk.
#[derive(Debug, Clone)]
pub struct ShellChunk {
    pub stdout: String,
    pub stderr: String,
}

/// Live shell execution channels returned by the runtime service.
pub struct ShellExecution {
    pub chunk_rx: mpsc::UnboundedReceiver<ShellChunk>,
    pub completion_rx: oneshot::Receiver<ShellResult>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellCancelStatus {
    Canceled,
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellStartError {
    DuplicateRequestId,
}

#[derive(Clone, Default)]
pub struct ShellService {
    active: Arc<DashMap<String, ActiveShellExecution>>,
}

#[derive(Clone)]
struct ActiveShellExecution {
    session_id: String,
    cancel_tx: watch::Sender<bool>,
}

impl ShellService {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start(
        &self,
        request_id: String,
        session_id: String,
        command: String,
        cwd: String,
        timeout_secs: u64,
    ) -> Result<ShellExecution, ShellStartError> {
        let (chunk_tx, chunk_rx) = mpsc::unbounded_channel();
        let (completion_tx, completion_rx) = oneshot::channel();
        let (cancel_tx, cancel_rx) = watch::channel(false);

        match self.active.entry(request_id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(ActiveShellExecution {
                    session_id,
                    cancel_tx,
                });
            }
            Entry::Occupied(_) => return Err(ShellStartError::DuplicateRequestId),
        }

        let active = self.active.clone();
        tokio::spawn(async move {
            let result = execute_with_stream_cancelable(
                &command,
                &cwd,
                timeout_secs,
                Some(chunk_tx),
                cancel_rx,
            )
            .await;
            active.remove(&request_id);
            let _ = completion_tx.send(result);
        });

        Ok(ShellExecution {
            chunk_rx,
            completion_rx,
        })
    }

    pub fn cancel(&self, session_id: &str, request_id: &str) -> ShellCancelStatus {
        let Some(entry) = self.active.get(request_id) else {
            return ShellCancelStatus::NotFound;
        };

        if entry.session_id != session_id {
            return ShellCancelStatus::NotFound;
        }

        if entry.cancel_tx.send(true).is_ok() {
            ShellCancelStatus::Canceled
        } else {
            drop(entry);
            self.active.remove(request_id);
            ShellCancelStatus::NotFound
        }
    }

    pub fn cancel_session(&self, session_id: &str) -> usize {
        let request_ids: Vec<String> = self
            .active
            .iter()
            .filter(|entry| entry.value().session_id == session_id)
            .map(|entry| entry.key().clone())
            .collect();

        let mut canceled = 0usize;
        for request_id in request_ids {
            if self.cancel(session_id, &request_id) == ShellCancelStatus::Canceled {
                canceled += 1;
            }
        }

        canceled
    }
}

/// Execute a shell command and optionally stream incremental output chunks.
#[allow(dead_code)]
pub async fn execute_with_stream(
    command: &str,
    cwd: &str,
    timeout_secs: u64,
    chunk_tx: Option<mpsc::UnboundedSender<ShellChunk>>,
) -> ShellResult {
    let (_cancel_tx, cancel_rx) = watch::channel(false);
    execute_with_stream_cancelable(command, cwd, timeout_secs, chunk_tx, cancel_rx).await
}

async fn execute_with_stream_cancelable(
    command: &str,
    cwd: &str,
    timeout_secs: u64,
    chunk_tx: Option<mpsc::UnboundedSender<ShellChunk>>,
    mut cancel_rx: watch::Receiver<bool>,
) -> ShellResult {
    let start = Instant::now();

    let result = run_command(command, cwd, timeout_secs, chunk_tx, &mut cancel_rx).await;
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok((stdout, stderr, exit_code)) => {
            let outcome = if exit_code == 0 {
                ShellOutcome::Completed
            } else {
                ShellOutcome::Failed
            };
            ShellResult {
                stdout,
                stderr,
                exit_code: Some(exit_code),
                duration_ms,
                outcome,
            }
        }
        Err(RunCommandError::Io(e)) => ShellResult {
            stdout: String::new(),
            stderr: format!("Failed to execute command: {e}"),
            exit_code: None,
            duration_ms,
            outcome: ShellOutcome::Failed,
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
                outcome: ShellOutcome::TimedOut,
            }
        }
        Err(RunCommandError::Canceled { stdout, stderr }) => {
            let cancel_msg = "Command canceled by user";
            let stderr = if stderr.is_empty() {
                cancel_msg.to_string()
            } else {
                format!("{stderr}\n{cancel_msg}")
            };
            ShellResult {
                stdout,
                stderr,
                exit_code: None,
                duration_ms,
                outcome: ShellOutcome::Canceled,
            }
        }
    }
}

enum RunCommandError {
    Io(std::io::Error),
    Timeout { stdout: String, stderr: String },
    Canceled { stdout: String, stderr: String },
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
    cancel_rx: &mut watch::Receiver<bool>,
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

    let status = tokio::select! {
        status = tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), child.wait()) => {
            match status {
                Ok(Ok(status)) => Some(status),
                Ok(Err(e)) => return Err(RunCommandError::Io(e)),
                Err(_) => {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                    None
                }
            }
        }
        _ = wait_for_cancel(cancel_rx) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return finalize_canceled(stdout_task, stderr_task).await;
        }
    };

    let stdout = join_reader(stdout_task).await?;
    let stderr = join_reader(stderr_task).await?;

    match status {
        Some(status) => Ok((stdout, stderr, status.code().unwrap_or(-1))),
        None => Err(RunCommandError::Timeout { stdout, stderr }),
    }
}

async fn finalize_canceled(
    stdout_task: JoinHandle<Result<String, std::io::Error>>,
    stderr_task: JoinHandle<Result<String, std::io::Error>>,
) -> Result<(String, String, i32), RunCommandError> {
    let stdout = join_reader(stdout_task).await?;
    let stderr = join_reader(stderr_task).await?;
    Err(RunCommandError::Canceled { stdout, stderr })
}

async fn wait_for_cancel(cancel_rx: &mut watch::Receiver<bool>) {
    loop {
        if *cancel_rx.borrow() {
            return;
        }

        if cancel_rx.changed().await.is_err() {
            // Sender dropped unexpectedly; treat it as a cancellation signal so the
            // child process does not outlive server-owned lifecycle state.
            return;
        }
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

#[cfg(test)]
mod tests {
    use super::{
        execute_with_stream, ShellCancelStatus, ShellOutcome, ShellService, ShellStartError,
    };
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn execute_with_stream_completes_successfully() {
        let result = execute_with_stream("printf 'hello'", "/tmp", 5, None).await;
        assert_eq!(result.stdout, "hello");
        assert_eq!(result.exit_code, Some(0));
        assert_eq!(result.outcome, ShellOutcome::Completed);
    }

    #[tokio::test]
    async fn execute_with_stream_times_out() {
        let result = execute_with_stream("sleep 2", "/tmp", 1, None).await;
        assert_eq!(result.exit_code, None);
        assert_eq!(result.outcome, ShellOutcome::TimedOut);
        assert!(result.stderr.contains("timed out"));
    }

    #[tokio::test]
    async fn shell_service_can_cancel_running_command() {
        let service = ShellService::new();
        let request_id = "req-cancel".to_string();
        let session_id = "sess-cancel".to_string();

        let execution = service
            .start(
                request_id.clone(),
                session_id.clone(),
                "sleep 30".to_string(),
                "/tmp".to_string(),
                60,
            )
            .expect("start");

        assert_eq!(
            service.cancel(&session_id, &request_id),
            ShellCancelStatus::Canceled
        );

        let result = timeout(Duration::from_secs(3), execution.completion_rx)
            .await
            .expect("completion timeout")
            .expect("completion result");
        assert_eq!(result.outcome, ShellOutcome::Canceled);
        assert!(result.stderr.contains("canceled"));
    }

    #[tokio::test]
    async fn shell_service_rejects_duplicate_request_id() {
        let service = ShellService::new();
        let request_id = "req-dup".to_string();

        let _first = service
            .start(
                request_id.clone(),
                "sess-a".to_string(),
                "sleep 10".to_string(),
                "/tmp".to_string(),
                30,
            )
            .expect("first start");

        let second = service.start(
            request_id,
            "sess-b".to_string(),
            "echo nope".to_string(),
            "/tmp".to_string(),
            30,
        );
        assert_eq!(second.err(), Some(ShellStartError::DuplicateRequestId));
    }
}
