//! Codex connector
//!
//! Connects to Codex via the app-server JSON-RPC protocol.
//! For now, uses subprocess. Future: direct codex-rs integration.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, error, info, warn};

use crate::{ApprovalType, ConnectorError, ConnectorEvent};

/// Codex subprocess connector
///
/// Spawns `codex app-server` and communicates via JSON-RPC over stdio.
pub struct CodexConnector {
    process: Child,
    stdin: Mutex<ChildStdin>,
    request_id: AtomicU64,
    pending_requests: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>>,
    event_tx: mpsc::Sender<ConnectorEvent>,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    thread_id: Option<String>,
    is_initialized: bool,
}

impl CodexConnector {
    /// Spawn a new Codex app-server process
    pub async fn spawn(cwd: &str) -> Result<Self, ConnectorError> {
        info!("Spawning codex app-server for {}", cwd);

        // Find codex binary
        let codex_path = Self::find_codex_binary()
            .ok_or_else(|| ConnectorError::SpawnError("Codex binary not found".into()))?;

        let mut process = Command::new(&codex_path)
            .args(["app-server"])
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| ConnectorError::SpawnError(format!("Failed to spawn: {}", e)))?;

        let stdin = process.stdin.take().ok_or_else(|| {
            ConnectorError::SpawnError("Failed to capture stdin".into())
        })?;

        let stdout = process.stdout.take().ok_or_else(|| {
            ConnectorError::SpawnError("Failed to capture stdout".into())
        })?;

        let (event_tx, event_rx) = mpsc::channel(100);
        let pending_requests = Arc::new(Mutex::new(HashMap::new()));

        // Spawn reader task
        let tx = event_tx.clone();
        let pending = pending_requests.clone();
        tokio::task::spawn_blocking(move || {
            Self::read_events(stdout, tx, pending);
        });

        let mut connector = Self {
            process,
            stdin: Mutex::new(stdin),
            request_id: AtomicU64::new(1),
            pending_requests,
            event_tx,
            event_rx: Some(event_rx),
            thread_id: None,
            is_initialized: false,
        };

        // Initialize the connection
        connector.initialize().await?;

        Ok(connector)
    }

    /// Find the codex binary
    fn find_codex_binary() -> Option<String> {
        let paths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ];

        for path in paths {
            if std::fs::metadata(path).is_ok() {
                return Some(path.to_string());
            }
        }

        // Try which
        if let Ok(output) = std::process::Command::new("which")
            .arg("codex")
            .output()
        {
            if output.status.success() {
                if let Ok(path) = String::from_utf8(output.stdout) {
                    let path = path.trim();
                    if !path.is_empty() {
                        return Some(path.to_string());
                    }
                }
            }
        }

        None
    }

    /// Initialize the connection
    async fn initialize(&mut self) -> Result<(), ConnectorError> {
        info!("Initializing codex connection");

        let params = json!({
            "clientInfo": {
                "name": "orbitdock-server",
                "title": "OrbitDock Server",
                "version": "0.1.0"
            }
        });

        let _result = self.send_request("initialize", params).await?;

        // Send initialized notification
        self.send_notification("initialized", json!({}))?;

        self.is_initialized = true;
        info!("Codex connection initialized");

        Ok(())
    }

    /// Send a JSON-RPC request and wait for response
    pub async fn send_request(&self, method: &str, params: Value) -> Result<Value, ConnectorError> {
        let id = self.request_id.fetch_add(1, Ordering::SeqCst);

        let request = json!({
            "id": id,
            "method": method,
            "params": params,
        });

        let (tx, rx) = oneshot::channel();

        // Register pending request
        {
            let mut pending = self.pending_requests.lock().unwrap();
            pending.insert(id, tx);
        }

        // Send request
        {
            let line = serde_json::to_string(&request)? + "\n";
            let mut stdin = self.stdin.lock().unwrap();
            stdin.write_all(line.as_bytes())?;
            stdin.flush()?;
        }

        debug!("Sent request {}: {}", id, method);

        // Wait for response (with timeout)
        match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
            Ok(Ok(Ok(result))) => Ok(result),
            Ok(Ok(Err(msg))) => Err(ConnectorError::ProviderError(msg)),
            Ok(Err(_)) => Err(ConnectorError::ChannelClosed),
            Err(_) => {
                // Timeout - remove pending request
                let mut pending = self.pending_requests.lock().unwrap();
                pending.remove(&id);
                Err(ConnectorError::ProviderError("Request timeout".into()))
            }
        }
    }

    /// Send a JSON-RPC notification (no response expected)
    fn send_notification(&self, method: &str, params: Value) -> Result<(), ConnectorError> {
        let notification = json!({
            "method": method,
            "params": params,
        });

        let line = serde_json::to_string(&notification)? + "\n";
        let mut stdin = self.stdin.lock().unwrap();
        stdin.write_all(line.as_bytes())?;
        stdin.flush()?;

        debug!("Sent notification: {}", method);
        Ok(())
    }

    /// Read events from stdout (runs in blocking thread)
    fn read_events(
        stdout: ChildStdout,
        tx: mpsc::Sender<ConnectorEvent>,
        pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>>,
    ) {
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

            // Parse as JSON
            let value: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    warn!("Failed to parse JSON: {} - {}", e, &line[..100.min(line.len())]);
                    continue;
                }
            };

            // Check if it's a response (has id and result/error)
            if let Some(id) = value.get("id").and_then(|i| i.as_u64()) {
                let result = if let Some(err) = value.get("error") {
                    let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error");
                    Err(msg.to_string())
                } else {
                    Ok(value.get("result").cloned().unwrap_or(Value::Null))
                };

                let mut pending_guard = pending.lock().unwrap();
                if let Some(tx) = pending_guard.remove(&id) {
                    let _ = tx.send(result);
                }
                continue;
            }

            // Handle notifications (events)
            if let Some(method) = value.get("method").and_then(|m| m.as_str()) {
                let params = value.get("params").cloned().unwrap_or(Value::Null);

                if let Some(event) = Self::translate_event(method, &params) {
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
    fn translate_event(method: &str, params: &Value) -> Option<ConnectorEvent> {
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
                // Serialize the plan to a string
                let plan = serde_json::to_string(&params.get("plan")).unwrap_or_default();
                Some(ConnectorEvent::PlanUpdated(plan))
            }

            "thread/tokenUsage/updated" => {
                let token_usage = params.get("tokenUsage");
                let last = token_usage.and_then(|tu| tu.get("last"));
                let context_window = token_usage
                    .and_then(|tu| tu.get("modelContextWindow"))
                    .and_then(|c| c.as_u64())
                    .unwrap_or(200_000);

                let usage = orbitdock_protocol::TokenUsage {
                    input_tokens: last
                        .and_then(|l| l.get("inputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    output_tokens: last
                        .and_then(|l| l.get("outputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    cached_tokens: last
                        .and_then(|l| l.get("cachedInputTokens"))
                        .and_then(|t| t.as_u64())
                        .unwrap_or(0),
                    context_window,
                };
                Some(ConnectorEvent::TokensUpdated(usage))
            }

            "item/created" | "item/started" => {
                // Parse item and create message
                if let Some(item) = params.get("item") {
                    Self::translate_item_event(item, true)
                } else {
                    None
                }
            }

            "item/completed" | "item/updated" => {
                // Parse item and update message
                if let Some(item) = params.get("item") {
                    Self::translate_item_event(item, false)
                } else {
                    None
                }
            }

            "item/commandExecution/requestApproval" => {
                let item_id = params.get("itemId").and_then(|i| i.as_str()).unwrap_or("");
                let command = params.get("command").and_then(|c| c.as_str());
                let cwd = params.get("cwd").and_then(|c| c.as_str());

                Some(ConnectorEvent::ApprovalRequested {
                    request_id: item_id.to_string(),
                    approval_type: ApprovalType::Exec,
                    command: command.map(String::from),
                    file_path: cwd.map(String::from),
                    diff: None,
                    question: None,
                })
            }

            "item/fileChange/requestApproval" => {
                let item_id = params.get("itemId").and_then(|i| i.as_str()).unwrap_or("");

                Some(ConnectorEvent::ApprovalRequested {
                    request_id: item_id.to_string(),
                    approval_type: ApprovalType::Patch,
                    command: None,
                    file_path: None,
                    diff: None,
                    question: None,
                })
            }

            "tool/requestUserInput" => {
                let id = params.get("id").and_then(|i| i.as_str()).unwrap_or("");
                let questions = params.get("questions");
                let question_text = questions
                    .and_then(|q| q.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|q| q.get("question"))
                    .and_then(|q| q.as_str());

                Some(ConnectorEvent::ApprovalRequested {
                    request_id: id.to_string(),
                    approval_type: ApprovalType::Question,
                    command: None,
                    file_path: None,
                    diff: None,
                    question: question_text.map(String::from),
                })
            }

            // Ignore streaming deltas and other high-frequency events
            _ if method.contains("_delta") || method.contains("/delta") => None,

            _ => {
                debug!("Unhandled Codex event: {}", method);
                None
            }
        }
    }

    /// Translate an item to a ConnectorEvent
    fn translate_item_event(item: &Value, is_new: bool) -> Option<ConnectorEvent> {
        let id = item.get("id").and_then(|i| i.as_str())?;
        let item_type = item.get("type").and_then(|t| t.as_str())?;
        let status = item.get("status").and_then(|s| s.as_str()).unwrap_or("unknown");

        let message_type = match item_type {
            "userMessage" => orbitdock_protocol::MessageType::User,
            "agentMessage" => orbitdock_protocol::MessageType::Assistant,
            "reasoning" => orbitdock_protocol::MessageType::Thinking,
            "commandExecution" | "mcpToolCall" | "fileChange" | "webSearch" => {
                orbitdock_protocol::MessageType::Tool
            }
            _ => return None,
        };

        // Extract content based on item type
        let content = match item_type {
            "userMessage" => {
                item.get("content")
                    .and_then(|c| c.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|b| b.get("text"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_string()
            }
            "agentMessage" => {
                item.get("text").and_then(|t| t.as_str()).unwrap_or("").to_string()
            }
            "reasoning" => {
                item.get("summary")
                    .and_then(|s| s.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str())
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default()
            }
            "commandExecution" => {
                item.get("command").and_then(|c| c.as_str()).unwrap_or("").to_string()
            }
            "mcpToolCall" => {
                item.get("tool").and_then(|t| t.as_str()).unwrap_or("").to_string()
            }
            "fileChange" => "File changes".to_string(),
            "webSearch" => {
                item.get("query").and_then(|q| q.as_str()).unwrap_or("").to_string()
            }
            _ => "".to_string(),
        };

        // Extract tool-specific fields
        let tool_name = match item_type {
            "commandExecution" => Some("Bash".to_string()),
            "mcpToolCall" => item.get("tool").and_then(|t| t.as_str()).map(String::from),
            "fileChange" => Some("Edit".to_string()),
            "webSearch" => Some("WebSearch".to_string()),
            _ => None,
        };

        let tool_output = match item_type {
            "commandExecution" => {
                item.get("aggregatedOutput").and_then(|o| o.as_str()).map(String::from)
            }
            "mcpToolCall" => {
                item.get("result").map(|r| serde_json::to_string(r).unwrap_or_default())
            }
            _ => None,
        };

        let tool_input = match item_type {
            "commandExecution" => {
                let cmd = item.get("command").and_then(|c| c.as_str()).unwrap_or("");
                Some(json!({"command": cmd}))
            }
            "mcpToolCall" => item.get("arguments").cloned(),
            _ => None,
        };

        if is_new {
            let message = orbitdock_protocol::Message {
                id: id.to_string(),
                session_id: String::new(), // Will be filled by handler
                message_type,
                content,
                tool_name,
                tool_input,
                tool_output,
                is_error: false,
                timestamp: chrono_now(),
                duration_ms: None,
            };
            Some(ConnectorEvent::MessageCreated(message))
        } else {
            Some(ConnectorEvent::MessageUpdated {
                message_id: id.to_string(),
                content: Some(content),
                tool_output,
                is_error: Some(status == "failed"),
                duration_ms: None,
            })
        }
    }

    /// Get the event receiver (can only be called once)
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
    }

    /// Get the thread ID
    pub fn thread_id(&self) -> Option<&str> {
        self.thread_id.as_deref()
    }

    // MARK: - Thread Operations

    /// Start a new thread
    pub async fn start_thread(&mut self, cwd: &str, model: Option<&str>) -> Result<String, ConnectorError> {
        let mut params = json!({
            "cwd": cwd,
            "approvalPolicy": "untrusted"
        });

        if let Some(m) = model {
            params["model"] = json!(m);
        }

        let result = self.send_request("thread/start", params).await?;

        let thread_id = result
            .get("thread")
            .and_then(|t| t.get("id"))
            .and_then(|i| i.as_str())
            .ok_or_else(|| ConnectorError::ProviderError("No thread id in response".into()))?
            .to_string();

        self.thread_id = Some(thread_id.clone());
        info!("Started thread: {}", thread_id);

        Ok(thread_id)
    }

    /// Resume an existing thread
    pub async fn resume_thread(&mut self, thread_id: &str, cwd: Option<&str>) -> Result<String, ConnectorError> {
        let mut params = json!({
            "threadId": thread_id
        });

        if let Some(c) = cwd {
            params["cwd"] = json!(c);
        }

        let result = self.send_request("thread/resume", params).await?;

        let thread_id = result
            .get("thread")
            .and_then(|t| t.get("id"))
            .and_then(|i| i.as_str())
            .unwrap_or(thread_id)
            .to_string();

        self.thread_id = Some(thread_id.clone());
        info!("Resumed thread: {}", thread_id);

        Ok(thread_id)
    }

    // MARK: - Turn Operations

    /// Send a user message (starts a turn)
    pub async fn send_message(&mut self, content: &str) -> Result<String, ConnectorError> {
        let thread_id = self.thread_id.as_ref()
            .ok_or_else(|| ConnectorError::ProviderError("No active thread".into()))?;

        let params = json!({
            "threadId": thread_id,
            "input": [{
                "type": "text",
                "text": content
            }]
        });

        let result = self.send_request("turn/start", params).await?;

        let turn_id = result
            .get("turn")
            .and_then(|t| t.get("id"))
            .and_then(|i| i.as_str())
            .unwrap_or("unknown")
            .to_string();

        info!("Started turn: {}", turn_id);
        Ok(turn_id)
    }

    /// Interrupt the current turn
    pub async fn interrupt(&mut self) -> Result<(), ConnectorError> {
        let thread_id = self.thread_id.as_ref()
            .ok_or_else(|| ConnectorError::ProviderError("No active thread".into()))?;

        let params = json!({
            "threadId": thread_id
        });

        self.send_request("turn/interrupt", params).await?;
        info!("Interrupted turn");
        Ok(())
    }

    // MARK: - Approvals

    /// Approve or reject an exec request
    pub fn approve_exec(&self, request_id: &str, approved: bool) -> Result<(), ConnectorError> {
        let submission = json!({
            "type": "exec_approval",
            "id": request_id,
            "decision": if approved { "approve" } else { "reject" }
        });

        let line = serde_json::to_string(&submission)? + "\n";
        let mut stdin = self.stdin.lock().unwrap();
        stdin.write_all(line.as_bytes())?;
        stdin.flush()?;

        info!("Sent exec approval: {} = {}", request_id, approved);
        Ok(())
    }

    /// Approve or reject a patch request
    pub fn approve_patch(&self, request_id: &str, approved: bool) -> Result<(), ConnectorError> {
        let submission = json!({
            "type": "patch_approval",
            "id": request_id,
            "decision": if approved { "approve" } else { "reject" }
        });

        let line = serde_json::to_string(&submission)? + "\n";
        let mut stdin = self.stdin.lock().unwrap();
        stdin.write_all(line.as_bytes())?;
        stdin.flush()?;

        info!("Sent patch approval: {} = {}", request_id, approved);
        Ok(())
    }

    /// Answer a question
    pub fn answer_question(&self, request_id: &str, answers: HashMap<String, String>) -> Result<(), ConnectorError> {
        let submission = json!({
            "type": "user_input_answer",
            "id": request_id,
            "response": {
                "answers": answers
            }
        });

        let line = serde_json::to_string(&submission)? + "\n";
        let mut stdin = self.stdin.lock().unwrap();
        stdin.write_all(line.as_bytes())?;
        stdin.flush()?;

        info!("Sent question answer: {}", request_id);
        Ok(())
    }

    /// Check if codex is installed
    pub fn is_installed() -> bool {
        Self::find_codex_binary().is_some()
    }
}

impl Drop for CodexConnector {
    fn drop(&mut self) {
        // Try to kill the process gracefully
        let _ = self.process.kill();
    }
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Simple ISO 8601 format
    let days = secs / 86400;
    let time = secs % 86400;
    let hours = time / 3600;
    let minutes = (time % 3600) / 60;
    let seconds = time % 60;

    // Rough year calculation
    let years_since_1970 = days / 365;
    let year = 1970 + years_since_1970;

    format!(
        "{:04}-01-01T{:02}:{:02}:{:02}Z",
        year, hours, minutes, seconds
    )
}
