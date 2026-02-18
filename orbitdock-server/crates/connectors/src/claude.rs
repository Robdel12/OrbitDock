//! Claude CLI Direct connector
//!
//! Spawns the `claude` CLI as a subprocess and communicates via stdin/stdout
//! using the NDJSON stream-json protocol. No Node.js bridge needed.
//!
//! Protocol reference: docs/claude-agent-sdk-protocol.md

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Child;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, error, info, warn};

use crate::{ApprovalType, ConnectorError, ConnectorEvent};

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
            "--include-partial-messages",
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

        info!(
            component = "claude_connector",
            event = "claude.spawn",
            cwd = %cwd,
            claude_bin = %claude_bin,
            resume_id = ?resume_id,
            "Spawning Claude CLI directly"
        );

        let mut child = tokio::process::Command::new(&claude_bin)
            .args(&args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("CLAUDE_CODE_ENTRYPOINT", "orbitdock")
            .spawn()
            .map_err(|e| {
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

        // Spawn stderr reader for logging
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    debug!(
                        component = "claude_connector",
                        event = "claude.stderr",
                        line = %line,
                        "Claude CLI stderr"
                    );
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

        tokio::spawn(async move {
            Self::event_loop(
                stdout,
                event_tx,
                session_clone,
                counter_clone,
                pending_clone,
                approvals_clone,
            )
            .await;
        });

        let connector = Self {
            stdin_tx,
            child: Arc::new(Mutex::new(child)),
            event_rx: Some(event_rx),
            claude_session_id,
            msg_counter,
            pending_controls,
            pending_approvals,
        };

        // Send initialize control request
        connector.send_initialize().await?;

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
    ) -> Result<(), ConnectorError> {
        let msg = StdinMessage::User {
            session_id: String::new(),
            message: UserMessagePayload {
                role: "user",
                content: vec![UserContentBlock::Text {
                    text: content.to_string(),
                }],
            },
            parent_tool_use_id: None,
        };
        self.write_stdin_message(&msg).await
    }

    /// Interrupt the current turn.
    pub async fn interrupt(&self) -> Result<(), ConnectorError> {
        let _ = self
            .send_control_request(ControlRequestBody::Interrupt)
            .await;
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

        let response_payload = if decision == "deny" {
            let mut deny = serde_json::json!({
                "behavior": "deny",
                "message": message.unwrap_or("User denied this operation"),
                "interrupt": interrupt.unwrap_or(false),
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
                    }
                }
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
    async fn send_initialize(&self) -> Result<(), ConnectorError> {
        let _ = self
            .send_control_request(ControlRequestBody::Initialize {})
            .await;
        Ok(())
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
    ) {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        let mut streaming_content = String::new();
        let mut streaming_msg_id: Option<String> = None;
        let mut in_turn = false;

        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let line = line.trim().to_string();
                    if line.is_empty() {
                        continue;
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
                    info!(
                        component = "claude_connector",
                        event = "claude.stdout.eof",
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
    ) -> Vec<ConnectorEvent> {
        let msg_type = raw.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let session_id = session_id_slot.lock().await.clone().unwrap_or_default();

        debug!(
            component = "claude_connector",
            event = "claude.stdout.dispatch",
            msg_type = %msg_type,
            session_id = %session_id,
            "Dispatching stdout message"
        );

        // Emit TurnStarted on first assistant activity (stream_event or assistant message)
        let mut turn_start_event = Vec::new();
        if !*in_turn && matches!(msg_type, "assistant" | "stream_event") {
            *in_turn = true;
            turn_start_event.push(ConnectorEvent::TurnStarted);
        }

        let mut events = match msg_type {
            "system" => Self::handle_system_message(raw, session_id_slot).await,

            "assistant" => Self::handle_assistant_message(
                raw,
                &session_id,
                msg_counter,
                streaming_content,
                streaming_msg_id,
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
                Self::handle_result_message(raw, streaming_content, streaming_msg_id)
            }

            "control_request" => Self::handle_cli_control_request(raw, pending_approvals).await,

            "control_cancel_request" => {
                // CLI cancelled a pending approval — clean up stored data
                if let Some(req_id) = raw.get("request_id").and_then(|v| v.as_str()) {
                    pending_approvals.lock().await.remove(req_id);
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

            "tool_progress" => {
                // Could emit MessageUpdated for progress, but ignore for now
                vec![]
            }

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

                    events.push(ConnectorEvent::ClaudeInitialized {
                        slash_commands,
                        skills,
                        tools,
                    });
                }
                events
            }
            "compact_boundary" => {
                vec![ConnectorEvent::ContextCompacted]
            }
            _ => {
                // status messages, hook_response, etc. — ignore
                vec![]
            }
        }
    }

    /// Handle `assistant` messages — extract content blocks into ConnectorEvents.
    fn handle_assistant_message(
        raw: &Value,
        session_id: &str,
        msg_counter: &Arc<AtomicU64>,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
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
                            timestamp: now_iso(),
                            duration_ms: None,
                        },
                    ));
                }
                "tool_use" => {
                    let tool_name = block
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown");
                    let input = block.get("input").map(|v| v.to_string());
                    events.push(ConnectorEvent::MessageCreated(
                        orbitdock_protocol::Message {
                            id,
                            session_id: session_id.to_string(),
                            message_type: orbitdock_protocol::MessageType::Tool,
                            content: String::new(),
                            tool_name: Some(tool_name.to_string()),
                            tool_input: input,
                            tool_output: None,
                            is_error: false,
                            timestamp: now_iso(),
                            duration_ms: None,
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
                            timestamp: now_iso(),
                            duration_ms: None,
                        },
                    ));
                }
                _ => {}
            }
        }

        events
    }

    /// Handle echoed `user` messages — extract tool results.
    fn handle_user_message(
        raw: &Value,
        session_id: &str,
        msg_counter: &Arc<AtomicU64>,
    ) -> Vec<ConnectorEvent> {
        // Skip replayed messages
        if raw
            .get("isReplay")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            return vec![];
        }

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
                        timestamp: now_iso(),
                        duration_ms: None,
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
                                timestamp: now_iso(),
                                duration_ms: None,
                            },
                        ));
                        *streaming_msg_id = Some(msg_id);
                    } else {
                        events.push(ConnectorEvent::MessageUpdated {
                            message_id: streaming_msg_id.clone().unwrap(),
                            content: Some(streaming_content.clone()),
                            tool_output: None,
                            is_error: None,
                            duration_ms: None,
                        });
                    }
                }
            }
        }

        events
    }

    /// Handle `result` messages — turn completed/aborted with usage.
    fn handle_result_message(
        raw: &Value,
        streaming_content: &mut String,
        streaming_msg_id: &mut Option<String>,
    ) -> Vec<ConnectorEvent> {
        let mut events = Vec::new();

        // Flush streaming content
        flush_streaming(&mut events, streaming_content, streaming_msg_id);

        // Extract token usage from modelUsage or usage
        let model_usage = raw.get("modelUsage").cloned();
        let usage = raw.get("usage").cloned();
        let token_usage = extract_token_usage(&model_usage, &usage);
        if let Some(tu) = token_usage {
            events.push(ConnectorEvent::TokensUpdated(tu));
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
        let request = match raw.get("request") {
            Some(r) => r,
            None => return vec![],
        };

        let subtype = request
            .get("subtype")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if subtype != "can_use_tool" {
            debug!(
                component = "claude_connector",
                event = "claude.control_request.unhandled",
                subtype = %subtype,
                "Unhandled CLI control request subtype"
            );
            return vec![];
        }

        let request_id = raw
            .get("request_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let tool_name = request
            .get("tool_name")
            .and_then(|v| v.as_str())
            .map(String::from);
        let input = request.get("input").cloned();
        let tool_use_id = request
            .get("tool_use_id")
            .and_then(|v| v.as_str())
            .map(String::from);
        let permission_suggestions = request.get("permission_suggestions").cloned();

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
        let diff = input
            .as_ref()
            .and_then(|i| i.get("new_string"))
            .and_then(|v| v.as_str())
            .map(String::from);
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
            "CLI requesting tool approval"
        );

        vec![ConnectorEvent::ApprovalRequested {
            request_id,
            approval_type,
            command,
            file_path,
            diff,
            question,
            proposed_amendment: None,
        }]
    }

    /// Handle `control_response` from CLI — resolve pending control requests.
    async fn handle_control_response(
        raw: &Value,
        pending_controls: &Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    ) {
        let response = match raw.get("response") {
            Some(r) => r,
            None => return,
        };

        let request_id = response
            .get("request_id")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if request_id.is_empty() {
            return;
        }

        let mut pending = pending_controls.lock().await;
        if let Some(tx) = pending.remove(request_id) {
            let _ = tx.send(response.clone());
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
                duration_ms: None,
            });
        }
    }
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
