//! Claude CLI Direct connector
//!
//! Spawns the `claude` CLI as a subprocess and communicates via stdin/stdout
//! using the NDJSON stream-json protocol. No Node.js bridge needed.
//!
//! Protocol reference: docs/claude-agent-sdk-protocol.md

pub mod session;

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, error, info, warn};

use orbitdock_connector_core::{ApprovalType, ConnectorError, ConnectorEvent};

// ---------------------------------------------------------------------------
// Stdin messages (Rust → CLI)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum StdinMessage {
    User {
        session_id: String,
        message: UserMessagePayload,
        #[serde(skip_serializing_if = "Option::is_none")]
        parent_tool_use_id: Option<String>,
    },
    ControlRequest {
        request_id: String,
        request: ControlRequestBody,
    },
    ControlResponse {
        response: ControlResponsePayload,
    },
}

#[derive(Debug, Serialize)]
struct UserMessagePayload {
    role: &'static str,
    content: Vec<UserContentBlock>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum UserContentBlock {
    Text { text: String },
    Image { source: ImageSource },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ImageSource {
    Base64 {
        media_type: String,
        data: String,
    },
    #[serde(rename = "url")]
    Url {
        url: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
enum ControlRequestBody {
    Initialize {},
    Interrupt,
    SetModel { model: Option<String> },
    SetMaxThinkingTokens { max_thinking_tokens: Option<u64> },
    SetPermissionMode { mode: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "subtype", rename_all = "snake_case")]
#[allow(dead_code)]
enum ControlResponsePayload {
    Success { request_id: String, response: Value },
    Error { request_id: String, error: String },
}

// ---------------------------------------------------------------------------
// Image transformation helper
// ---------------------------------------------------------------------------

/// Transform ImageInput to Anthropic's image content block format.
/// - URL images: pass through as-is
/// - Path images: read file, convert to base64
fn transform_image(image: &orbitdock_protocol::ImageInput) -> Result<UserContentBlock, String> {
    match image.input_type.as_str() {
        "url" => {
            if let Some((media_type, data)) = parse_data_uri_base64(&image.value) {
                Ok(UserContentBlock::Image {
                    source: ImageSource::Base64 { media_type, data },
                })
            } else {
                Ok(UserContentBlock::Image {
                    source: ImageSource::Url {
                        url: image.value.clone(),
                    },
                })
            }
        }
        "path" => {
            // Read file from disk
            let bytes = std::fs::read(&image.value)
                .map_err(|e| format!("Failed to read image file {}: {}", image.value, e))?;

            // Infer media type from file extension
            let media_type = infer_media_type(&image.value);

            // Encode to base64
            let data = STANDARD.encode(&bytes);

            Ok(UserContentBlock::Image {
                source: ImageSource::Base64 { media_type, data },
            })
        }
        other => Err(format!("Unknown image input_type: {}", other)),
    }
}

/// Parse a `data:*;base64,...` URI into `(media_type, base64_data)`.
fn parse_data_uri_base64(uri: &str) -> Option<(String, String)> {
    let without_scheme = uri.strip_prefix("data:")?;
    let comma_pos = without_scheme.find(',')?;
    let meta = &without_scheme[..comma_pos];
    if !meta.ends_with(";base64") {
        return None;
    }

    let media_type = &meta[..meta.len() - 7];
    let normalized_media_type = if media_type.is_empty() {
        "image/png"
    } else {
        media_type
    };

    let raw_data = &without_scheme[comma_pos + 1..];
    let normalized_data: String = raw_data
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    if normalized_data.is_empty() {
        return None;
    }

    Some((normalized_media_type.to_string(), normalized_data))
}

/// Infer MIME type from file path extension.
fn infer_media_type(path: &str) -> String {
    let path_lower = path.to_lowercase();
    if path_lower.ends_with(".png") {
        "image/png".to_string()
    } else if path_lower.ends_with(".jpg") || path_lower.ends_with(".jpeg") {
        "image/jpeg".to_string()
    } else if path_lower.ends_with(".gif") {
        "image/gif".to_string()
    } else if path_lower.ends_with(".webp") {
        "image/webp".to_string()
    } else {
        // Default to PNG for unknown types
        "image/png".to_string()
    }
}

// ---------------------------------------------------------------------------
// ClaudeConnector
// ---------------------------------------------------------------------------

/// Stores the `input`, `tool_use_id`, and `permission_suggestions` from a
/// `can_use_tool` control request so we can echo them back in the approval
/// response (required by the SDK).
struct PendingApproval {
    input: Value,
    tool_use_id: Option<String>,
    permission_suggestions: Option<Value>,
}

#[allow(dead_code)]
pub struct ClaudeConnector {
    stdin_tx: mpsc::Sender<String>,
    child: Arc<Mutex<Child>>,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    claude_session_id: Arc<Mutex<Option<String>>>,
    msg_counter: Arc<AtomicU64>,
    pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
    models: Arc<Mutex<Vec<orbitdock_protocol::ClaudeModelOption>>>,
}

impl ClaudeConnector {
    /// Spawn a new `claude` CLI subprocess.
    pub async fn new(
        cwd: &str,
        model: Option<&str>,
        resume_id: Option<&str>,
        permission_mode: Option<&str>,
        allowed_tools: &[String],
        disallowed_tools: &[String],
        effort: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        let claude_bin = resolve_claude_binary()?;

        let mut args = vec![
            "--output-format",
            "stream-json",
            "--verbose",
            "--input-format",
            "stream-json",
            "--permission-prompt-tool",
            "stdio",
        ];

        if let Some(m) = model {
            args.extend(["--model", m]);
        }
        if let Some(sid) = resume_id {
            args.extend(["--resume", sid]);
        }
        if let Some(mode) = permission_mode {
            args.extend(["--permission-mode", mode]);
        }
        let allowed_joined = allowed_tools.join(",");
        let disallowed_joined = disallowed_tools.join(",");
        if !allowed_tools.is_empty() {
            args.extend(["--allowedTools", &allowed_joined]);
        }
        if !disallowed_tools.is_empty() {
            args.extend(["--disallowedTools", &disallowed_joined]);
        }
        if let Some(e) = effort {
            args.extend(["--effort", e]);
        }

        let args_display = args.join(" ");
        info!(
            component = "claude_connector",
            event = "claude.spawn",
            cwd = %cwd,
            claude_bin = %claude_bin,
            resume_id = ?resume_id,
            args = %args_display,
            "Spawning Claude CLI directly"
        );

        let mut child = tokio::process::Command::new(&claude_bin)
            .args(&args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("CLAUDE_CODE_ENTRYPOINT", "orbitdock")
            .env_remove("CLAUDECODE")
            .spawn()
            .map_err(|e| {
                error!(
                    component = "claude_connector",
                    event = "claude.spawn.failed",
                    error = %e,
                    claude_bin = %claude_bin,
                    args = %args_display,
                    "Failed to spawn Claude CLI"
                );
                ConnectorError::ProviderError(format!("Failed to spawn claude CLI: {}", e))
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ConnectorError::ProviderError("No stdin on child".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ConnectorError::ProviderError("No stdout on child".into()))?;

        let (event_tx, event_rx) = mpsc::channel::<ConnectorEvent>(256);
        let (stdin_tx, stdin_rx) = mpsc::channel::<String>(256);
        let claude_session_id = Arc::new(Mutex::new(None));
        // Seed from epoch millis so IDs never collide across connector restarts
        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let msg_counter = Arc::new(AtomicU64::new(epoch_ms));
        let pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));

        // Spawn stderr reader + exit code watcher
        let child_arc: Arc<Mutex<Child>> = Arc::new(Mutex::new(child));
        if let Some(stderr) = child_arc.lock().await.stderr.take() {
            let child_for_exit = child_arc.clone();
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                let mut stderr_lines = Vec::new();
                while let Ok(Some(line)) = lines.next_line().await {
                    warn!(
                        component = "claude_connector",
                        event = "claude.stderr",
                        line = %line,
                        "Claude CLI stderr"
                    );
                    stderr_lines.push(line);
                }
                // stderr closed — process is exiting, capture exit code
                let exit_status = child_for_exit.lock().await.wait().await;
                match exit_status {
                    Ok(status) => {
                        let code = status.code();
                        if code != Some(0) {
                            warn!(
                                component = "claude_connector",
                                event = "claude.exit",
                                exit_code = ?code,
                                stderr_tail = %stderr_lines.iter().rev().take(5)
                                    .collect::<Vec<_>>().into_iter().rev()
                                    .cloned().collect::<Vec<_>>().join("\n"),
                                "Claude CLI exited with non-zero status"
                            );
                        } else {
                            info!(
                                component = "claude_connector",
                                event = "claude.exit",
                                exit_code = ?code,
                                "Claude CLI exited"
                            );
                        }
                    }
                    Err(e) => {
                        error!(
                            component = "claude_connector",
                            event = "claude.exit.error",
                            error = %e,
                            "Failed to get Claude CLI exit status"
                        );
                    }
                }
            });
        }

        // Spawn stdin writer task
        tokio::spawn(async move {
            Self::stdin_writer(stdin, stdin_rx).await;
        });

        // Spawn stdout reader loop
        let session_clone = claude_session_id.clone();
        let counter_clone = msg_counter.clone();
        let pending_clone = pending_controls.clone();
        let approvals_clone = pending_approvals.clone();
        let models: Arc<Mutex<Vec<orbitdock_protocol::ClaudeModelOption>>> =
            Arc::new(Mutex::new(Vec::new()));
        let models_clone = models.clone();

        // Keep a clone of event_tx so we can emit models after send_initialize()
        // completes. The system init message arrives on stdout before the
        // control_response, so the event loop would read an empty models mutex.
        let init_event_tx = event_tx.clone();

        tokio::spawn(async move {
            Self::event_loop(
                stdout,
                event_tx,
                session_clone,
                counter_clone,
                pending_clone,
                approvals_clone,
                models_clone,
            )
            .await;
        });

        let connector = Self {
            stdin_tx,
            child: child_arc,
            event_rx: Some(event_rx),
            claude_session_id,
            msg_counter,
            pending_controls,
            pending_approvals,
            models: models.clone(),
        };

        // Send initialize control request — kill the child if it fails, and parse models from response
        match connector.send_initialize().await {
            Ok(init_response) => {
                // Log the response keys to debug model parsing
                let keys: Vec<&str> = init_response
                    .as_object()
                    .map(|o| o.keys().map(|k| k.as_str()).collect())
                    .unwrap_or_default();
                debug!(
                    component = "claude_connector",
                    event = "claude.init.response_keys",
                    keys = ?keys,
                    has_models = init_response.get("models").is_some(),
                    "Initialize response received"
                );

                // Parse models from init response
                if let Some(models_array) = init_response.get("models").and_then(|v| v.as_array()) {
                    let parsed_models: Vec<orbitdock_protocol::ClaudeModelOption> = models_array
                        .iter()
                        .filter_map(|m| {
                            let value = m.get("value")?.as_str()?.to_string();
                            let display_name = m.get("displayName")?.as_str()?.to_string();
                            let description = m.get("description")?.as_str()?.to_string();
                            Some(orbitdock_protocol::ClaudeModelOption {
                                value,
                                display_name,
                                description,
                            })
                        })
                        .collect();

                    info!(
                        component = "claude_connector",
                        event = "claude.init.models_parsed",
                        count = parsed_models.len(),
                        "Parsed models from initialize response"
                    );

                    *models.lock().await = parsed_models.clone();

                    // Emit models via the event channel. The system init message
                    // was already processed by the event loop with an empty models
                    // vec (race condition), so we send a follow-up event here.
                    let _ = init_event_tx
                        .send(ConnectorEvent::ClaudeInitialized {
                            slash_commands: vec![],
                            skills: vec![],
                            tools: vec![],
                            models: parsed_models,
                        })
                        .await;
                }
            }
            Err(e) => {
                error!(
                    component = "claude_connector",
                    event = "claude.init.failed",
                    error = %e,
                    "Initialize failed, killing orphaned child process"
                );
                let _ = connector.shutdown().await;
                return Err(e);
            }
        }

        Ok(connector)
    }

    /// Take the event receiver (can only be called once).
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
    }

    /// Get the Claude session ID (set after init event).
    pub async fn claude_session_id(&self) -> Option<String> {
        self.claude_session_id.lock().await.clone()
    }

    /// Send a user message to start or continue a turn.
    pub async fn send_message(
        &self,
        content: &str,
        _model: Option<&str>,
        _effort: Option<&str>,
        images: &[orbitdock_protocol::ImageInput],
    ) -> Result<(), ConnectorError> {
        let mut content_blocks = vec![UserContentBlock::Text {
            text: content.to_string(),
        }];

        // Transform images to Anthropic format
        for image in images {
            match transform_image(image) {
                Ok(block) => content_blocks.push(block),
                Err(e) => {
                    warn!(
                        event = "claude.image.transform_failed",
                        error = %e,
                        input_type = %image.input_type,
                        "Failed to transform image, skipping"
                    );
                }
            }
        }

        let msg = StdinMessage::User {
            session_id: String::new(),
            message: UserMessagePayload {
                role: "user",
                content: content_blocks,
            },
            parent_tool_use_id: None,
        };
        self.write_stdin_message(&msg).await
    }

    /// Interrupt the current turn.
    pub async fn interrupt(&self) -> Result<(), ConnectorError> {
        self.send_control_request(ControlRequestBody::Interrupt)
            .await?;
        Ok(())
    }

    /// Approve or deny a tool use request.
    ///
    /// - `message`: Custom deny reason shown to the agent (deny only).
    /// - `interrupt`: If true, stop the entire turn instead of just this tool.
    /// - `updated_input`: Modified tool input to use instead of the original.
    pub async fn approve_tool(
        &self,
        request_id: &str,
        decision: &str,
        message: Option<&str>,
        interrupt: Option<bool>,
        updated_input: Option<&Value>,
    ) -> Result<(), ConnectorError> {
        let pending = self.pending_approvals.lock().await.remove(request_id);

        let is_deny = matches!(decision, "denied" | "deny" | "abort");
        let response_payload = if is_deny {
            let mut deny = serde_json::json!({
                "behavior": "deny",
                "message": message.unwrap_or("User denied this operation"),
                "interrupt": interrupt.unwrap_or(decision == "abort"),
            });
            if let Some(ref p) = pending {
                if let Some(ref id) = p.tool_use_id {
                    deny["toolUseID"] = serde_json::json!(id);
                }
            }
            deny
        } else {
            let mut allow = serde_json::json!({
                "behavior": "allow",
            });
            if let Some(ref p) = pending {
                // Use client-provided updated_input if present, otherwise echo original
                if let Some(ui) = updated_input {
                    allow["updatedInput"] = ui.clone();
                } else {
                    allow["updatedInput"] = p.input.clone();
                }
                if let Some(ref id) = p.tool_use_id {
                    allow["toolUseID"] = serde_json::json!(id);
                }
                // For session/always approvals, relay the CLI's permission_suggestions
                if matches!(decision, "approved_for_session" | "approved_always") {
                    if let Some(ref suggestions) = p.permission_suggestions {
                        allow["updatedPermissions"] = suggestions.clone();
                    } else {
                        warn!(
                            component = "claude_connector",
                            event = "claude.approval.missing_permission_suggestions",
                            request_id = %request_id,
                            decision = %decision,
                            tool_use_id = ?p.tool_use_id,
                            "Session-scoped approval missing permission suggestions; CLI may reprompt the same command"
                        );
                    }
                }
            } else if matches!(decision, "approved_for_session" | "approved_always") {
                warn!(
                    component = "claude_connector",
                    event = "claude.approval.missing_pending_context",
                    request_id = %request_id,
                    decision = %decision,
                    "Session-scoped approval missing pending request context; cannot attach permission updates"
                );
            }
            allow
        };

        let msg = StdinMessage::ControlResponse {
            response: ControlResponsePayload::Success {
                request_id: request_id.to_string(),
                response: response_payload,
            },
        };
        self.write_stdin_message(&msg).await
    }

    /// Answer a question approval.
    pub async fn answer_question(
        &self,
        request_id: &str,
        answer: &str,
    ) -> Result<(), ConnectorError> {
        let response_payload = serde_json::json!({
            "behavior": "deny",
            "message": answer,
            "interrupt": false,
        });

        let msg = StdinMessage::ControlResponse {
            response: ControlResponsePayload::Success {
                request_id: request_id.to_string(),
                response: response_payload,
            },
        };
        self.write_stdin_message(&msg).await
    }

    /// Change the model mid-session.
    pub async fn set_model(&self, model: &str) -> Result<(), ConnectorError> {
        let _ = self
            .send_control_request(ControlRequestBody::SetModel {
                model: Some(model.to_string()),
            })
            .await;
        Ok(())
    }

    /// Change maximum thinking tokens.
    pub async fn set_max_thinking(&self, tokens: u64) -> Result<(), ConnectorError> {
        let _ = self
            .send_control_request(ControlRequestBody::SetMaxThinkingTokens {
                max_thinking_tokens: Some(tokens),
            })
            .await;
        Ok(())
    }

    /// Change permission mode mid-session.
    pub async fn set_permission_mode(&self, mode: &str) -> Result<(), ConnectorError> {
        let _ = self
            .send_control_request(ControlRequestBody::SetPermissionMode {
                mode: mode.to_string(),
            })
            .await;
        Ok(())
    }

    /// Shutdown the subprocess.
    pub async fn shutdown(&self) -> Result<(), ConnectorError> {
        // Drop the stdin sender to close the pipe, which signals the CLI to exit
        // (The sender is held by the stdin_writer task, which will end when the
        // channel closes. We can't drop it directly, but killing the child works.)
        let mut child = self.child.lock().await;
        let _ = child.kill().await;
        Ok(())
    }

    // -- Internal helpers ---------------------------------------------------

    /// Send the initialize control request.
    async fn send_initialize(&self) -> Result<Value, ConnectorError> {
        self.send_control_request(ControlRequestBody::Initialize {})
            .await
    }

    /// Send a control request and wait for the response.
    async fn send_control_request(
        &self,
        body: ControlRequestBody,
    ) -> Result<Value, ConnectorError> {
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending_controls.lock().await.insert(id.clone(), tx);

        let msg = StdinMessage::ControlRequest {
            request_id: id.clone(),
            request: body,
        };
        self.write_stdin_message(&msg).await?;

        match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
            Ok(Ok(val)) => Ok(val),
            Ok(Err(_)) => {
                self.pending_controls.lock().await.remove(&id);
                Err(ConnectorError::ProviderError(
                    "Control response channel dropped".into(),
                ))
            }
            Err(_) => {
                self.pending_controls.lock().await.remove(&id);
                Err(ConnectorError::ProviderError(
                    "Control request timed out after 30s".into(),
                ))
            }
        }
    }

    /// Serialize and send a message to the stdin channel.
    async fn write_stdin_message(&self, msg: &StdinMessage) -> Result<(), ConnectorError> {
        let json = serde_json::to_string(msg).map_err(ConnectorError::JsonError)?;

        debug!(
            component = "claude_connector",
            event = "claude.stdin.write",
            payload_len = json.len(),
            "Writing to CLI stdin"
        );

        self.stdin_tx
            .send(json)
            .await
            .map_err(|_| ConnectorError::ProviderError("stdin channel closed".into()))
    }

    /// Dedicated stdin writer task — reads from channel, writes to child stdin.
    async fn stdin_writer(mut stdin: tokio::process::ChildStdin, mut rx: mpsc::Receiver<String>) {
        while let Some(mut line) = rx.recv().await {
            line.push('\n');
            if let Err(e) = stdin.write_all(line.as_bytes()).await {
                error!(
                    component = "claude_connector",
                    event = "claude.stdin.write_error",
                    error = %e,
                    "Failed to write to CLI stdin"
                );
                break;
            }
            if let Err(e) = stdin.flush().await {
                error!(
                    component = "claude_connector",
                    event = "claude.stdin.flush_error",
                    error = %e,
                    "Failed to flush CLI stdin"
                );
                break;
            }
        }
        debug!(
            component = "claude_connector",
            event = "claude.stdin.closed",
            "Stdin writer task ended"
        );
    }

    /// Read stdout line-by-line, parse JSON, translate to ConnectorEvent.
    async fn event_loop(
        stdout: tokio::process::ChildStdout,
        event_tx: mpsc::Sender<ConnectorEvent>,
        session_id: Arc<Mutex<Option<String>>>,
        msg_counter: Arc<AtomicU64>,
        pending_controls: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
        pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>>,
        models: Arc<Mutex<Vec<orbitdock_protocol::ClaudeModelOption>>>,
    ) {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        let mut streaming_content = String::new();
        let mut streaming_msg_id: Option<String> = None;
        let mut in_turn = false;
        // Per-call input/cached tokens from the latest assistant message (for accurate context fill)
        let mut last_turn_input: Option<(u64, u64)> = None;
        let mut cumulative_output: u64 = 0;
        let mut last_context_window: u64 = 200_000;

        let mut line_count: u64 = 0;

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    line_count += 1;
                    let line = line.trim().to_string();
                    if line.is_empty() {
                        continue;
                    }

                    // Log first few lines and any non-JSON for debugging startup issues
                    if line_count <= 3 {
                        info!(
                            component = "claude_connector",
                            event = "claude.stdout.raw",
                            line_num = line_count,
                            preview = %if line.len() > 300 { &line[..300] } else { &line },
                            "Raw stdout line"
                        );
                    }

                    let raw: Value = match serde_json::from_str(&line) {
                        Ok(v) => v,
                        Err(e) => {
                            warn!(
                                component = "claude_connector",
                                event = "claude.stdout.parse_error",
                                error = %e,
                                line_preview = %if line.len() > 200 { &line[..200] } else { &line },
                                "Failed to parse stdout JSON"
                            );
                            continue;
                        }
                    };

                    let events = Self::dispatch_stdout_message(
                        &raw,
                        &session_id,
                        &msg_counter,
                        &pending_controls,
                        &pending_approvals,
                        &mut streaming_content,
                        &mut streaming_msg_id,
                        &mut in_turn,
                        &mut last_turn_input,
                        &mut cumulative_output,
                        &mut last_context_window,
                        &models,
                    )
                    .await;

                    for ev in events {
                        if event_tx.send(ev).await.is_err() {
                            info!(
                                component = "claude_connector",
                                event = "claude.event_loop.channel_closed",
                                "Event channel closed, stopping reader"
                            );
                            return;
                        }
                    }
                }
                Ok(None) => {
                    warn!(
                        component = "claude_connector",
                        event = "claude.stdout.eof",
                        lines_read = line_count,
                        "Claude CLI stdout EOF"
                    );
                    let _ = event_tx
                        .send(ConnectorEvent::SessionEnded {
                            reason: "cli_exited".to_string(),
                        })
                        .await;
                    return;
                }
                Err(e) => {
                    error!(
                        component = "claude_connector",
                        event = "claude.stdout.read_error",
                        error = %e,
                        "Error reading CLI stdout"
                    );
                    let _ = event_tx
                        .send(ConnectorEvent::SessionEnded {
                            reason: format!("read_error: {}", e),
                        })
                        .await;
                    return;
                }
            }
        }
    }

    /// Dispatch a raw stdout JSON message by its `type` field.
    #[allow(clippy::too_many_arguments)]
    async fn dispatch_stdout_message(
        raw: &Value,
        session_id_slot: &Arc<Mutex<Option<String>>>,
        msg_counter: &Arc<AtomicU64>,
        pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
        pending_approvals: &Arc<Mutex<HashMap<String, PendingApproval>>>,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        in_turn: &mut bool,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
        models: &Arc<Mutex<Vec<orbitdock_protocol::ClaudeModelOption>>>,
    ) -> Vec<ConnectorEvent> {
        let msg_type = raw.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let session_id = session_id_slot.lock().await.clone().unwrap_or_default();

        let is_replay = raw
            .get("isReplay")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        debug!(
            component = "claude_connector",
            event = "claude.stdout.dispatch",
            msg_type = %msg_type,
            session_id = %session_id,
            is_replay = is_replay,
            "Dispatching stdout message"
        );

        // Skip replayed messages from --resume. Only allow `system` through
        // (contains init with session_id, hook_started for thread registration).
        if is_replay && msg_type != "system" {
            return vec![];
        }

        // Emit TurnStarted on first assistant activity (stream_event or assistant message)
        let mut turn_start_event = Vec::new();
        if !*in_turn && matches!(msg_type, "assistant" | "stream_event") {
            *in_turn = true;
            turn_start_event.push(ConnectorEvent::TurnStarted);
        }

        let mut events = match msg_type {
            "system" => Self::handle_system_message(raw, session_id_slot, models).await,

            "assistant" => Self::handle_assistant_message(
                raw,
                &session_id,
                msg_counter,
                streaming_content,
                streaming_msg_id,
                last_turn_input,
                cumulative_output,
                last_context_window,
            ),

            "user" => Self::handle_user_message(raw, &session_id, msg_counter),

            "stream_event" => Self::handle_stream_event(
                raw,
                &session_id,
                msg_counter,
                streaming_content,
                streaming_msg_id,
            ),

            "result" => {
                *in_turn = false;
                Self::handle_result_message(
                    raw,
                    streaming_content,
                    streaming_msg_id,
                    last_turn_input,
                    cumulative_output,
                    last_context_window,
                )
            }

            "control_request" => Self::handle_cli_control_request(raw, pending_approvals).await,

            "control_cancel_request" => {
                // CLI cancelled a pending approval — clean up stored data
                if let Some(req_id) = string_field(raw, "request_id", "requestId") {
                    pending_approvals.lock().await.remove(req_id.as_str());
                    debug!(
                        component = "claude_connector",
                        event = "claude.control.cancelled",
                        request_id = %req_id,
                        "CLI cancelled control request"
                    );
                }
                vec![]
            }

            "control_response" => {
                Self::handle_control_response(raw, pending_controls).await;
                vec![]
            }

            "tool_progress" => Self::handle_tool_progress(raw),

            "keep_alive" | "auth_status" => vec![],

            _ => {
                debug!(
                    component = "claude_connector",
                    event = "claude.stdout.unknown_type",
                    msg_type = %msg_type,
                    "Unknown stdout message type"
                );
                vec![]
            }
        };

        // Prepend TurnStarted so it fires before any message events
        let final_events = if !turn_start_event.is_empty() {
            turn_start_event.append(&mut events);
            turn_start_event
        } else {
            events
        };

        if !final_events.is_empty() && msg_type != "stream_event" {
            debug!(
                component = "claude_connector",
                event = "claude.stdout.dispatch_result",
                msg_type = %msg_type,
                event_count = final_events.len(),
                "Produced connector events"
            );
        }

        final_events
    }

    /// Handle `system` messages (init, compact_boundary, status).
    async fn handle_system_message(
        raw: &Value,
        session_id_slot: &Arc<Mutex<Option<String>>>,
        _models: &Arc<Mutex<Vec<orbitdock_protocol::ClaudeModelOption>>>,
    ) -> Vec<ConnectorEvent> {
        let subtype = raw.get("subtype").and_then(|v| v.as_str()).unwrap_or("");

        match subtype {
            "init" => {
                let mut events = vec![];
                if let Some(sid) = raw.get("session_id").and_then(|v| v.as_str()) {
                    *session_id_slot.lock().await = Some(sid.to_string());
                    let model = raw.get("model").and_then(|v| v.as_str());

                    // Parse capability arrays from init message
                    let parse_string_array = |key: &str| -> Vec<String> {
                        raw.get(key)
                            .and_then(|v| v.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|v| v.as_str().map(String::from))
                                    .collect()
                            })
                            .unwrap_or_default()
                    };
                    let slash_commands = parse_string_array("slash_commands");
                    let skills = parse_string_array("skills");
                    let tools = parse_string_array("tools");

                    info!(
                        component = "claude_connector",
                        event = "claude.init",
                        claude_session_id = %sid,
                        model = ?model,
                        slash_commands_count = slash_commands.len(),
                        skills_count = skills.len(),
                        tools_count = tools.len(),
                        "Claude session initialized via CLI"
                    );

                    if let Some(m) = model {
                        events.push(ConnectorEvent::ModelUpdated(m.to_string()));
                    }

                    // Don't read models from the mutex here — the system init
                    // message arrives on stdout before the control_response that
                    // populates the models mutex. Models are emitted separately
                    // from new() after send_initialize() completes.
                    events.push(ConnectorEvent::ClaudeInitialized {
                        slash_commands,
                        skills,
                        tools,
                        models: vec![],
                    });
                }
                events
            }
            "compact_boundary" => {
                vec![ConnectorEvent::ContextCompacted]
            }
            "hook_started" => {
                // Capture the hook's session_id so we can register it as a managed thread.
                // On --resume the CLI creates a new session_id for hooks, different from
                // the original. Without registering it, the hook handler creates a
                // duplicate passive session.
                if let Some(sid) = raw.get("session_id").and_then(|v| v.as_str()) {
                    info!(
                        component = "claude_connector",
                        event = "claude.hook_started",
                        hook_session_id = %sid,
                        "Hook started with session ID"
                    );
                    vec![ConnectorEvent::HookSessionId(sid.to_string())]
                } else {
                    vec![]
                }
            }
            _ => {
                // status messages, hook_response, etc. — ignore
                vec![]
            }
        }
    }

    /// Handle `assistant` messages — extract content blocks into ConnectorEvents.
    #[allow(clippy::too_many_arguments)]
    fn handle_assistant_message(
        raw: &Value,
        session_id: &str,
        msg_counter: &Arc<AtomicU64>,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        // Track whether streaming was active before flushing — if so, the text
        // content was already delivered via the streaming path and the final
        // assistant message's "text" blocks are duplicates.
        let had_streaming = streaming_msg_id.is_some();

        // Flush any pending streaming content
        flush_streaming(&mut events, streaming_content, streaming_msg_id);

        let message = match raw.get("message") {
            Some(m) => m,
            None => {
                debug!(
                    component = "claude_connector",
                    event = "claude.assistant.no_message_field",
                    "Assistant message missing 'message' field"
                );
                return events;
            }
        };

        let content_blocks = match message.get("content").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => {
                debug!(
                    component = "claude_connector",
                    event = "claude.assistant.no_content_blocks",
                    "Assistant message missing 'content' array"
                );
                return events;
            }
        };

        let block_types: Vec<&str> = content_blocks
            .iter()
            .map(|b| b.get("type").and_then(|v| v.as_str()).unwrap_or("?"))
            .collect();
        debug!(
            component = "claude_connector",
            event = "claude.assistant.content_blocks",
            block_count = content_blocks.len(),
            block_types = ?block_types,
            had_streaming = had_streaming,
            "Processing assistant content blocks"
        );

        for block in content_blocks {
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
            let id = format!(
                "claude-msg-{}-{}",
                &session_id[..8.min(session_id.len())],
                msg_counter.fetch_add(1, Ordering::Relaxed)
            );

            match block_type {
                // Skip text blocks if streaming already delivered the content
                "text" if had_streaming => continue,
                "text" => {
                    let text = block.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    events.push(ConnectorEvent::MessageCreated(
                        orbitdock_protocol::Message {
                            id,
                            session_id: session_id.to_string(),
                            message_type: orbitdock_protocol::MessageType::Assistant,
                            content: text.to_string(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            is_error: false,
                            is_in_progress: false,
                            timestamp: now_iso(),
                            duration_ms: None,
                            images: vec![],
                        },
                    ));
                }
                "tool_use" => {
                    let tool_name = block
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown");
                    let input = block.get("input").map(|v| v.to_string());
                    let tool_use_id = block.get("id").and_then(|v| v.as_str());
                    let message_id = tool_use_id.map(str::to_string).unwrap_or(id);
                    events.push(ConnectorEvent::MessageCreated(
                        orbitdock_protocol::Message {
                            id: message_id,
                            session_id: session_id.to_string(),
                            message_type: orbitdock_protocol::MessageType::Tool,
                            content: String::new(),
                            tool_name: Some(tool_name.to_string()),
                            tool_input: input,
                            tool_output: None,
                            is_error: false,
                            is_in_progress: true,
                            timestamp: now_iso(),
                            duration_ms: None,
                            images: vec![],
                        },
                    ));
                }
                "thinking" => {
                    let thinking = block.get("thinking").and_then(|v| v.as_str()).unwrap_or("");
                    events.push(ConnectorEvent::MessageCreated(
                        orbitdock_protocol::Message {
                            id,
                            session_id: session_id.to_string(),
                            message_type: orbitdock_protocol::MessageType::Thinking,
                            content: thinking.to_string(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            is_error: false,
                            is_in_progress: false,
                            timestamp: now_iso(),
                            duration_ms: None,
                            images: vec![],
                        },
                    ));
                }
                _ => {}
            }
        }

        // Capture per-call usage from the assistant message for accurate context fill.
        // message.usage contains per-call values (not cumulative session totals).
        if let Some(usage) = message.get("usage").and_then(Value::as_object) {
            let input = value_to_u64(usage.get("input_tokens"));
            let cached = value_to_u64(usage.get("cache_read_input_tokens"))
                + value_to_u64(usage.get("cache_creation_input_tokens"));
            *last_turn_input = Some((input, cached));
            *cumulative_output += value_to_u64(usage.get("output_tokens"));

            // Emit live token progress during turns (not just on final `result`).
            // Claude tool/thinking blocks are nested inside assistant messages.
            let live_usage = orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: *cumulative_output,
                cached_tokens: cached,
                context_window: *last_context_window,
            };
            events.push(ConnectorEvent::TokensUpdated {
                usage: live_usage,
                snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::MixedLegacy,
            });
        }

        events
    }

    /// Handle echoed `user` messages — extract tool results.
    fn handle_user_message(
        raw: &Value,
        session_id: &str,
        msg_counter: &Arc<AtomicU64>,
    ) -> Vec<ConnectorEvent> {
        // Skip non-synthetic messages (real user input echoes)
        if !raw
            .get("isSynthetic")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return vec![];
        }

        let mut events = Vec::new();
        let message = match raw.get("message") {
            Some(m) => m,
            None => return events,
        };

        let content_blocks = match message.get("content").and_then(|v| v.as_array()) {
            Some(arr) => arr,
            None => return events,
        };

        for block in content_blocks {
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("");
            if block_type == "tool_result" {
                let content = block
                    .get("content")
                    .map(|v| {
                        if let Some(s) = v.as_str() {
                            s.to_string()
                        } else {
                            v.to_string()
                        }
                    })
                    .unwrap_or_default();
                let is_error = block
                    .get("is_error")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);

                if let Some(tool_use_id) = block.get("tool_use_id").and_then(|v| v.as_str()) {
                    events.push(ConnectorEvent::MessageUpdated {
                        message_id: tool_use_id.to_string(),
                        content: None,
                        tool_output: Some(content.clone()),
                        is_error: Some(is_error),
                        is_in_progress: Some(false),
                        duration_ms: None,
                    });
                }

                let id = format!(
                    "claude-msg-{}-{}",
                    &session_id[..8.min(session_id.len())],
                    msg_counter.fetch_add(1, Ordering::Relaxed)
                );
                events.push(ConnectorEvent::MessageCreated(
                    orbitdock_protocol::Message {
                        id,
                        session_id: session_id.to_string(),
                        message_type: orbitdock_protocol::MessageType::ToolResult,
                        content,
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error,
                        is_in_progress: false,
                        timestamp: now_iso(),
                        duration_ms: None,
                        images: vec![],
                    },
                ));
            }
        }

        events
    }

    /// Handle `stream_event` — streaming deltas from --include-partial-messages.
    fn handle_stream_event(
        raw: &Value,
        session_id: &str,
        msg_counter: &Arc<AtomicU64>,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        let event = match raw.get("event") {
            Some(e) => e,
            None => return events,
        };

        let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");

        if event_type == "content_block_delta" {
            let delta = match event.get("delta") {
                Some(d) => d,
                None => return events,
            };
            let delta_type = delta.get("type").and_then(|v| v.as_str()).unwrap_or("");

            if delta_type == "text_delta" {
                if let Some(text) = delta.get("text").and_then(|v| v.as_str()) {
                    streaming_content.push_str(text);

                    if streaming_msg_id.is_none() {
                        let msg_id = format!(
                            "claude-msg-{}-{}",
                            &session_id[..8.min(session_id.len())],
                            msg_counter.fetch_add(1, Ordering::Relaxed)
                        );
                        events.push(ConnectorEvent::MessageCreated(
                            orbitdock_protocol::Message {
                                id: msg_id.clone(),
                                session_id: session_id.to_string(),
                                message_type: orbitdock_protocol::MessageType::Assistant,
                                content: streaming_content.clone(),
                                tool_name: None,
                                tool_input: None,
                                tool_output: None,
                                is_error: false,
                                is_in_progress: true,
                                timestamp: now_iso(),
                                duration_ms: None,
                                images: vec![],
                            },
                        ));
                        *streaming_msg_id = Some(msg_id);
                    } else {
                        events.push(ConnectorEvent::MessageUpdated {
                            message_id: streaming_msg_id.clone().unwrap(),
                            content: Some(streaming_content.clone()),
                            tool_output: None,
                            is_error: None,
                            is_in_progress: Some(true),
                            duration_ms: None,
                        });
                    }
                }
            }
        }

        events
    }

    /// Handle `tool_progress` updates for long-running tool executions.
    fn handle_tool_progress(raw: &Value) -> Vec<ConnectorEvent> {
        let Some(tool_use_id) = raw.get("tool_use_id").and_then(|v| v.as_str()) else {
            return vec![];
        };

        let tool_name = raw
            .get("tool_name")
            .and_then(|v| v.as_str())
            .unwrap_or("Tool");
        let elapsed = raw
            .get("elapsed_time_seconds")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        vec![ConnectorEvent::MessageUpdated {
            message_id: tool_use_id.to_string(),
            content: None,
            tool_output: Some(format!("{} running ({}s)", tool_name, elapsed)),
            is_error: None,
            is_in_progress: Some(true),
            duration_ms: None,
        }]
    }

    /// Handle `result` messages — turn completed/aborted with usage.
    fn handle_result_message(
        raw: &Value,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
        last_turn_input: &mut Option<(u64, u64)>,
        cumulative_output: &mut u64,
        last_context_window: &mut u64,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        // Flush streaming content
        flush_streaming(&mut events, streaming_content, streaming_msg_id);

        // Build token usage. Prefer per-call input/cached from the last assistant
        // message (accurate for context fill) with cumulative output tokens.
        // Fall back to the old cumulative modelUsage extraction if no per-call data.
        let model_usage = raw.get("modelUsage").cloned();
        let usage = raw.get("usage").cloned();

        let token_usage = if let Some((input, cached)) = last_turn_input.take() {
            // Extract context_window from modelUsage (any model entry)
            let context_window = model_usage
                .as_ref()
                .and_then(Value::as_object)
                .and_then(|models| {
                    models
                        .values()
                        .find_map(|stats| stats.get("contextWindow").and_then(Value::as_u64))
                })
                .unwrap_or(200_000);

            Some(orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: *cumulative_output,
                cached_tokens: cached,
                context_window,
            })
        } else {
            extract_token_usage(&model_usage, &usage)
        };

        if let Some(tu) = token_usage {
            *last_context_window = tu.context_window.max(1);
            events.push(ConnectorEvent::TokensUpdated {
                usage: tu,
                snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::MixedLegacy,
            });
        }

        let subtype = raw.get("subtype").and_then(|v| v.as_str()).unwrap_or("");
        let is_error = raw
            .get("is_error")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if is_error || subtype.starts_with("error") {
            let reason = if subtype.is_empty() {
                "error".to_string()
            } else {
                subtype.to_string()
            };
            events.push(ConnectorEvent::TurnAborted { reason });
        } else {
            events.push(ConnectorEvent::TurnCompleted);
        }

        events
    }

    /// Handle `control_request` from the CLI (permission prompts).
    async fn handle_cli_control_request(
        raw: &Value,
        pending_approvals: &Arc<Mutex<HashMap<String, PendingApproval>>>,
    ) -> Vec<ConnectorEvent> {
        let request = match value_field(raw, "request", "request") {
            Some(r) => r,
            None => return vec![],
        };

        let subtype = string_field(request, "subtype", "subtype")
            .or_else(|| string_field(request, "sub_type", "subType"))
            .unwrap_or_default();

        if subtype != "can_use_tool" {
            debug!(
                component = "claude_connector",
                event = "claude.control_request.unhandled",
                subtype = %subtype,
                "Unhandled CLI control request subtype"
            );
            return vec![];
        }

        let request_id = string_field(raw, "request_id", "requestId").unwrap_or_default();
        let tool_name = string_field(request, "tool_name", "toolName");
        let input = value_field(request, "input", "input").cloned();
        let tool_use_id = string_field(request, "tool_use_id", "toolUseID")
            .or_else(|| string_field(request, "toolUseId", "toolUseId"));
        let permission_suggestions =
            value_field(request, "permission_suggestions", "permissionSuggestions")
                .cloned()
                .or_else(|| {
                    value_field(raw, "permission_suggestions", "permissionSuggestions").cloned()
                });
        let has_permission_suggestions = permission_suggestions.is_some();

        if request_id.is_empty() {
            warn!(
                component = "claude_connector",
                event = "claude.control_request.missing_request_id",
                tool_name = ?tool_name,
                tool_use_id = ?tool_use_id,
                "Claude can_use_tool request missing request_id; cannot correlate approval response"
            );
            return vec![];
        }

        // Store for echoing back in approve_tool response
        pending_approvals.lock().await.insert(
            request_id.clone(),
            PendingApproval {
                input: input.clone().unwrap_or(Value::Null),
                tool_use_id: tool_use_id.clone(),
                permission_suggestions,
            },
        );

        // Classify approval type
        let approval_type = match tool_name.as_deref() {
            Some("Edit" | "Write" | "NotebookEdit") => ApprovalType::Patch,
            Some("AskUserQuestion") => ApprovalType::Question,
            _ => ApprovalType::Exec,
        };

        // Extract command, file_path, diff, question from input
        let command = input
            .as_ref()
            .and_then(|i| i.get("command"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let file_path = input
            .as_ref()
            .and_then(|i| i.get("file_path"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let diff = input.as_ref().and_then(|payload| {
            Self::patch_diff_for_approval(tool_name.as_deref(), payload, file_path.as_deref())
        });
        let question = input
            .as_ref()
            .and_then(|i| i.get("question"))
            .and_then(|v| v.as_str())
            .map(String::from)
            .or_else(|| {
                input
                    .as_ref()
                    .and_then(|i| i.get("questions"))
                    .and_then(|v| v.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|q| q.get("question"))
                    .and_then(|v| v.as_str())
                    .map(String::from)
            });

        debug!(
            component = "claude_connector",
            event = "claude.approval_requested",
            request_id = %request_id,
            tool_name = ?tool_name,
            tool_use_id = ?tool_use_id,
            approval_type = ?approval_type,
            has_permission_suggestions,
            "CLI requesting tool approval"
        );

        let tool_input_json = input.as_ref().and_then(|i| serde_json::to_string(i).ok());

        vec![ConnectorEvent::ApprovalRequested {
            request_id,
            approval_type,
            tool_name: tool_name.clone(),
            tool_input: tool_input_json,
            command,
            file_path,
            diff,
            question,
            proposed_amendment: None,
        }]
    }

    fn patch_diff_for_approval(
        tool_name: Option<&str>,
        payload: &Value,
        fallback_file_path: Option<&str>,
    ) -> Option<String> {
        let is_patch_tool = matches!(tool_name, Some("Edit" | "Write" | "NotebookEdit"));
        if !is_patch_tool {
            return payload
                .get("new_string")
                .and_then(|value| value.as_str())
                .and_then(Self::trim_non_empty_str)
                .map(str::to_string);
        }

        let file_path = payload
            .get("file_path")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
            .or_else(|| fallback_file_path.and_then(Self::trim_non_empty_str))
            .unwrap_or("file");

        let old_string = payload.get("old_string").and_then(|value| value.as_str());
        let new_string = payload.get("new_string").and_then(|value| value.as_str());

        if old_string.is_some() || new_string.is_some() {
            return Some(Self::render_patch_diff(
                file_path,
                file_path,
                old_string.unwrap_or_default(),
                new_string.unwrap_or_default(),
            ));
        }

        if let Some(content) = payload
            .get("content")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
        {
            return Some(Self::render_patch_diff("/dev/null", file_path, "", content));
        }

        payload
            .get("new_string")
            .and_then(|value| value.as_str())
            .and_then(Self::trim_non_empty_str)
            .map(str::to_string)
    }

    fn render_patch_diff(old_path: &str, new_path: &str, old_text: &str, new_text: &str) -> String {
        let mut lines = vec![
            format!("--- {old_path}"),
            format!("+++ {new_path}"),
            "@@".to_string(),
        ];

        lines.extend(old_text.lines().map(|line| format!("-{line}")));
        lines.extend(new_text.lines().map(|line| format!("+{line}")));

        if old_text.is_empty() && new_text.is_empty() {
            lines.push("(no textual changes provided)".to_string());
        }

        lines.join("\n")
    }

    fn trim_non_empty_str(value: &str) -> Option<&str> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    }

    /// Handle `control_response` from CLI — resolve pending control requests.
    async fn handle_control_response(
        raw: &Value,
        pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    ) {
        let response = match value_field(raw, "response", "response") {
            Some(r) => r,
            None => return,
        };

        let request_id = string_field(response, "request_id", "requestId").unwrap_or_default();

        if request_id.is_empty() {
            return;
        }

        let mut pending = pending_controls.lock().await;
        if let Some(tx) = pending.remove(request_id.as_str()) {
            let _ = tx.send(response.clone());
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn value_field<'a>(value: &'a Value, snake_key: &str, camel_key: &str) -> Option<&'a Value> {
    value.get(snake_key).or_else(|| value.get(camel_key))
}

fn string_field(value: &Value, snake_key: &str, camel_key: &str) -> Option<String> {
    value_field(value, snake_key, camel_key)
        .and_then(|v| v.as_str())
        .map(String::from)
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("{}Z", ms / 1000)
}

/// Flush accumulated streaming content into a final MessageUpdated.
fn flush_streaming(
    events: &mut Vec<ConnectorEvent>,
    streaming_content: &mut String,
    streaming_msg_id: &mut Option<String>,
) {
    if let Some(mid) = streaming_msg_id.take() {
        if !streaming_content.is_empty() {
            events.push(ConnectorEvent::MessageUpdated {
                message_id: mid,
                content: Some(std::mem::take(streaming_content)),
                tool_output: None,
                is_error: None,
                is_in_progress: Some(false),
                duration_ms: None,
            });
        }
    }
}

/// Extract a `u64` from an optional JSON value, defaulting to 0.
fn value_to_u64(v: Option<&Value>) -> u64 {
    v.and_then(|v| v.as_u64()).unwrap_or(0)
}

/// Extract token usage from the modelUsage or usage fields in result messages.
fn extract_token_usage(
    model_usage: &Option<Value>,
    usage: &Option<Value>,
) -> Option<orbitdock_protocol::TokenUsage> {
    // Try modelUsage first (per-model breakdown, sum all models)
    if let Some(Value::Object(models)) = model_usage {
        let mut total = orbitdock_protocol::TokenUsage {
            input_tokens: 0,
            output_tokens: 0,
            cached_tokens: 0,
            context_window: 200_000,
        };
        for (_model_name, stats) in models {
            total.input_tokens += stats
                .get("inputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            total.output_tokens += stats
                .get("outputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            total.cached_tokens += stats
                .get("cacheReadInputTokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            if let Some(cw) = stats.get("contextWindow").and_then(|v| v.as_u64()) {
                total.context_window = cw;
            }
        }
        if total.input_tokens > 0 || total.output_tokens > 0 {
            return Some(total);
        }
    }

    // Fallback to flat usage object
    if let Some(u) = usage {
        let input = u.get("input_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let output = u.get("output_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
        let cached = u
            .get("cache_read_input_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        if input > 0 || output > 0 {
            return Some(orbitdock_protocol::TokenUsage {
                input_tokens: input,
                output_tokens: output,
                cached_tokens: cached,
                context_window: 200_000,
            });
        }
    }

    None
}

/// Resolve the claude binary path.
/// 1. CLAUDE_BIN env var
/// 2. ~/.claude/local/claude
/// 3. Search PATH via `which`
fn resolve_claude_binary() -> Result<String, ConnectorError> {
    // 1. Env var override
    if let Ok(path) = std::env::var("CLAUDE_BIN") {
        if std::path::Path::new(&path).exists() {
            return Ok(path);
        }
        warn!(
            component = "claude_connector",
            event = "claude.binary.env_not_found",
            path = %path,
            "CLAUDE_BIN path does not exist, trying fallbacks"
        );
    }

    // 2. Well-known location
    if let Ok(home) = std::env::var("HOME") {
        let local_path = format!("{}/.claude/local/claude", home);
        if std::path::Path::new(&local_path).exists() {
            return Ok(local_path);
        }
    }

    // 3. Search PATH
    if let Ok(output) = std::process::Command::new("which").arg("claude").output() {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() && std::path::Path::new(&path).exists() {
                return Ok(path);
            }
        }
    }

    Err(ConnectorError::ProviderError(
        "Claude CLI binary not found. Install Claude Code or set CLAUDE_BIN.".to_string(),
    ))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use serde_json::{json, Value};
    use tokio::sync::Mutex;

    use super::{
        parse_data_uri_base64, transform_image, ClaudeConnector, ImageSource, PendingApproval,
        UserContentBlock,
    };
    use crate::ConnectorEvent;

    #[test]
    fn parse_data_uri_base64_extracts_media_type_and_payload() {
        let uri = "data:image/png;base64,aGVs\nbG8=";
        let parsed = parse_data_uri_base64(uri).expect("expected valid data uri");
        assert_eq!(parsed.0, "image/png");
        assert_eq!(parsed.1, "aGVsbG8=");
    }

    #[test]
    fn transform_image_converts_data_uri_url_to_base64_source() {
        let input = orbitdock_protocol::ImageInput {
            input_type: "url".to_string(),
            value: "data:image/png;base64,aGVsbG8=".to_string(),
        };
        let block = transform_image(&input).expect("transform should succeed");
        match block {
            UserContentBlock::Image {
                source: ImageSource::Base64 { media_type, data },
            } => {
                assert_eq!(media_type, "image/png");
                assert_eq!(data, "aGVsbG8=");
            }
            other => panic!("expected base64 image source, got {:?}", other),
        }
    }

    #[test]
    fn transform_image_keeps_http_url_as_url_source() {
        let input = orbitdock_protocol::ImageInput {
            input_type: "url".to_string(),
            value: "https://example.com/image.png".to_string(),
        };
        let block = transform_image(&input).expect("transform should succeed");
        match block {
            UserContentBlock::Image {
                source: ImageSource::Url { url },
            } => assert_eq!(url, "https://example.com/image.png"),
            other => panic!("expected url image source, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn handle_cli_control_request_accepts_camel_case_permission_fields() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let permission_suggestions = json!([
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "session",
                "rules": [{ "toolName": "Bash", "ruleContent": "npm test" }]
            }
        ]);

        let raw = json!({
            "type": "control_request",
            "requestId": "req-camel-1",
            "request": {
                "subtype": "can_use_tool",
                "toolName": "Bash",
                "toolUseID": "toolu-camel-1",
                "input": { "command": "npm test" },
                "permissionSuggestions": permission_suggestions
            }
        });

        let events = ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals).await;
        assert_eq!(events.len(), 1);
        match &events[0] {
            ConnectorEvent::ApprovalRequested {
                request_id,
                tool_name,
                command,
                ..
            } => {
                assert_eq!(request_id, "req-camel-1");
                assert_eq!(tool_name.as_deref(), Some("Bash"));
                assert_eq!(command.as_deref(), Some("npm test"));
            }
            other => panic!("expected ApprovalRequested event, got {:?}", other),
        }

        let pending = pending_approvals.lock().await;
        let stored = pending
            .get("req-camel-1")
            .expect("pending approval should be stored");
        assert_eq!(stored.tool_use_id.as_deref(), Some("toolu-camel-1"));
        assert_eq!(
            stored.permission_suggestions,
            Some(raw["request"]["permissionSuggestions"].clone())
        );
    }

    #[tokio::test]
    async fn handle_cli_control_request_uses_top_level_permission_suggestions_fallback() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let permission_suggestions: Value = json!([
            {
                "type": "addRules",
                "behavior": "allow",
                "destination": "session",
                "rules": [{ "toolName": "Bash", "ruleContent": "git status" }]
            }
        ]);

        let raw = json!({
            "type": "control_request",
            "request_id": "req-top-level-1",
            "permissionSuggestions": permission_suggestions,
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": { "command": "git status" }
            }
        });

        let events = ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals).await;
        assert_eq!(events.len(), 1);

        let pending = pending_approvals.lock().await;
        let stored = pending
            .get("req-top-level-1")
            .expect("pending approval should be stored");
        assert_eq!(
            stored.permission_suggestions,
            Some(raw["permissionSuggestions"].clone())
        );
    }

    #[tokio::test]
    async fn handle_cli_control_request_rejects_missing_request_id() {
        let pending_approvals: Arc<Mutex<HashMap<String, PendingApproval>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let raw = json!({
            "type": "control_request",
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": { "command": "pwd" }
            }
        });

        let events = ClaudeConnector::handle_cli_control_request(&raw, &pending_approvals).await;
        assert!(events.is_empty(), "missing request id should be ignored");
        assert!(pending_approvals.lock().await.is_empty());
    }
}
