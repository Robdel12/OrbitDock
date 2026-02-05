//! Codex connector
//!
//! Connects to Codex via the app-server JSON-RPC protocol.
//! For now, uses subprocess. Future: direct codex-rs integration.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use crate::{ConnectorError, ConnectorEvent};

/// Codex subprocess connector
///
/// Spawns `codex app-server` and communicates via JSON-RPC over stdio.
pub struct CodexConnector {
    process: Child,
    stdin: ChildStdin,
    request_id: Arc<AtomicU64>,
    event_tx: mpsc::Sender<ConnectorEvent>,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
}

impl CodexConnector {
    /// Spawn a new Codex app-server process
    pub async fn spawn(cwd: &str) -> Result<Self, ConnectorError> {
        info!("Spawning codex app-server for {}", cwd);

        let mut process = Command::new("codex")
            .args(["app-server", "--cwd", cwd])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| ConnectorError::SpawnError(e.to_string()))?;

        let stdin = process.stdin.take().ok_or_else(|| {
            ConnectorError::SpawnError("Failed to capture stdin".into())
        })?;

        let stdout = process.stdout.take().ok_or_else(|| {
            ConnectorError::SpawnError("Failed to capture stdout".into())
        })?;

        let (event_tx, event_rx) = mpsc::channel(100);
        let request_id = Arc::new(AtomicU64::new(1));

        // Spawn reader task
        let tx = event_tx.clone();
        tokio::task::spawn_blocking(move || {
            Self::read_events(stdout, tx);
        });

        Ok(Self {
            process,
            stdin,
            request_id,
            event_tx,
            event_rx: Some(event_rx),
        })
    }

    /// Send a JSON-RPC request
    fn send_request(&mut self, method: &str, params: Value) -> Result<u64, ConnectorError> {
        let id = self.request_id.fetch_add(1, Ordering::SeqCst);
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });

        let line = serde_json::to_string(&request)? + "\n";
        self.stdin.write_all(line.as_bytes())?;
        self.stdin.flush()?;

        debug!("Sent request {}: {}", id, method);
        Ok(id)
    }

    /// Read events from stdout (runs in blocking thread)
    fn read_events(stdout: ChildStdout, tx: mpsc::Sender<ConnectorEvent>) {
        let reader = BufReader::new(stdout);

        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(e) => {
                    error!("Error reading stdout: {}", e);
                    break;
                }
            };

            if line.is_empty() {
                continue;
            }

            // Parse as JSON-RPC notification or response
            let value: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Failed to parse JSON: {} - {}", e, line);
                    continue;
                }
            };

            // Handle notifications (events)
            if let Some(method) = value.get("method").and_then(|m| m.as_str()) {
                let params = value.get("params").cloned().unwrap_or(Value::Null);

                if let Some(event) = Self::translate_event(method, params) {
                    if tx.blocking_send(event).is_err() {
                        debug!("Event channel closed, stopping reader");
                        break;
                    }
                }
            }
        }

        info!("Codex event reader finished");
    }

    /// Translate a Codex event to a ConnectorEvent
    fn translate_event(method: &str, params: Value) -> Option<ConnectorEvent> {
        match method {
            "turn/started" => Some(ConnectorEvent::TurnStarted),
            "turn/completed" => Some(ConnectorEvent::TurnCompleted),
            "turn/aborted" => {
                let reason = params
                    .get("reason")
                    .and_then(|r| r.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                Some(ConnectorEvent::TurnAborted { reason })
            }
            "turn/diff/updated" => {
                let diff = params
                    .get("diff")
                    .and_then(|d| d.as_str())
                    .unwrap_or("")
                    .to_string();
                Some(ConnectorEvent::DiffUpdated(diff))
            }
            "turn/plan/updated" => {
                let plan = params
                    .get("plan")
                    .and_then(|p| p.as_str())
                    .unwrap_or("")
                    .to_string();
                Some(ConnectorEvent::PlanUpdated(plan))
            }
            "thread/tokenUsage/updated" => {
                // Parse token usage
                let usage = orbitdock_protocol::TokenUsage {
                    input_tokens: params
                        .get("last")
                        .and_then(|l| l.get("inputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    output_tokens: params
                        .get("last")
                        .and_then(|l| l.get("outputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    cached_tokens: params
                        .get("last")
                        .and_then(|l| l.get("cachedInputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    context_window: params
                        .get("contextWindow")
                        .and_then(|c| c.as_u64())
                        .unwrap_or(200_000),
                };
                Some(ConnectorEvent::TokensUpdated(usage))
            }
            // TODO: Handle item events, approval requests, etc.
            _ => {
                debug!("Unhandled Codex event: {}", method);
                None
            }
        }
    }

    /// Get the event receiver (can only be called once)
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
    }

    /// Create a new thread
    pub async fn create_thread(&mut self) -> Result<String, ConnectorError> {
        self.send_request("thread/create", json!({}))?;
        // For now, return a placeholder. In practice, we'd wait for the response.
        Ok(format!("thread-{}", uuid::Uuid::new_v4()))
    }

    /// Send a user message
    pub async fn send_message(&mut self, content: &str) -> Result<(), ConnectorError> {
        self.send_request("turn/submit", json!({ "content": content }))?;
        Ok(())
    }

    /// Approve an exec request
    pub async fn approve_exec(&mut self, approved: bool) -> Result<(), ConnectorError> {
        let method = if approved {
            "exec/approve"
        } else {
            "exec/reject"
        };
        self.send_request(method, json!({}))?;
        Ok(())
    }

    /// Approve a patch request
    pub async fn approve_patch(&mut self, approved: bool) -> Result<(), ConnectorError> {
        let method = if approved {
            "patch/approve"
        } else {
            "patch/reject"
        };
        self.send_request(method, json!({}))?;
        Ok(())
    }

    /// Interrupt the current turn
    pub async fn interrupt(&mut self) -> Result<(), ConnectorError> {
        self.send_request("turn/interrupt", json!({}))?;
        Ok(())
    }
}

impl Drop for CodexConnector {
    fn drop(&mut self) {
        // Try to kill the process gracefully
        let _ = self.process.kill();
    }
}
