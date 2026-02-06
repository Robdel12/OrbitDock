//! Codex connector
//!
//! Direct integration with codex-core library.
//! No subprocess, no JSON-RPC — just Rust function calls.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use codex_core::auth::AuthCredentialsStoreMode;
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_core::{AuthManager, CodexThread, ThreadManager};
use codex_protocol::protocol::{
    Event, EventMsg, FileChange, Op, ReviewDecision, SessionSource,
};
use codex_protocol::request_user_input::{RequestUserInputAnswer, RequestUserInputResponse};
use codex_protocol::user_input::UserInput;
use serde_json::json;
use tokio::sync::mpsc;
use tracing::{debug, error, info};

use crate::{ApprovalType, ConnectorError, ConnectorEvent};

/// Tracks an in-progress assistant message being streamed via deltas
struct StreamingMessage {
    message_id: String,
    content: String,
    last_broadcast: std::time::Instant,
    /// True if started by AgentMessageContentDelta (newer path).
    /// When set, AgentMessageDelta events are skipped to avoid doubling.
    from_content_delta: bool,
}

/// Minimum interval between streaming content broadcasts (ms)
const STREAM_THROTTLE_MS: u128 = 50;

/// Codex connector using direct codex-core integration
pub struct CodexConnector {
    thread: Arc<CodexThread>,
    _thread_manager: Arc<ThreadManager>,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    thread_id: String,
}

impl CodexConnector {
    /// Create a new Codex connector with direct codex-core integration
    pub async fn new(cwd: &str, model: Option<&str>) -> Result<Self, ConnectorError> {
        info!("Creating codex-core connector for {}", cwd);

        // Resolve codex home directory (~/.codex)
        let codex_home = find_codex_home()
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;

        // Create auth manager (reads existing codex credentials)
        let auth_manager = Arc::new(AuthManager::new(
            codex_home.clone(),
            true, // enable CODEX_API_KEY env var
            AuthCredentialsStoreMode::Auto,
        ));

        // Create thread manager
        let thread_manager = Arc::new(ThreadManager::new(
            codex_home,
            auth_manager.clone(),
            SessionSource::Mcp,
        ));

        // Load config from user's existing setup (~/.codex/config.toml)
        let mut cli_overrides = Vec::new();

        // Override model if specified (model IS a TOML config field)
        if let Some(m) = model {
            cli_overrides.push(("model".to_string(), toml::Value::String(m.to_string())));
        }

        // Set approval policy to UnlessTrusted (safe default for OrbitDock)
        cli_overrides.push((
            "approval_policy".to_string(),
            toml::Value::String("untrusted".to_string()),
        ));

        // cwd is a ConfigOverrides field, not a TOML config field
        let harness_overrides = ConfigOverrides {
            cwd: Some(std::path::PathBuf::from(cwd)),
            ..Default::default()
        };

        let config = Config::load_with_cli_overrides_and_harness_overrides(
            cli_overrides,
            harness_overrides,
        )
        .await
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to load config: {}", e)))?;

        // Start a thread
        let new_thread = thread_manager
            .start_thread(config)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to start thread: {}", e)))?;

        let thread = new_thread.thread;
        let thread_id = new_thread.thread_id;
        info!("Started codex thread: {:?}", thread_id);

        let (event_tx, event_rx) = mpsc::channel(256);
        let output_buffers = Arc::new(tokio::sync::Mutex::new(HashMap::<String, String>::new()));
        let streaming_message = Arc::new(tokio::sync::Mutex::new(Option::<StreamingMessage>::None));
        let msg_counter = Arc::new(AtomicU64::new(0));

        // Spawn async event loop
        let tx = event_tx.clone();
        let t = thread.clone();
        let buffers = output_buffers.clone();
        let streaming = streaming_message.clone();
        let counter = msg_counter.clone();
        tokio::spawn(async move {
            Self::event_loop(t, tx, buffers, streaming, counter).await;
        });

        Ok(Self {
            thread,
            _thread_manager: thread_manager,
            event_rx: Some(event_rx),
            thread_id: thread_id.to_string(),
        })
    }

    /// Async event loop — pulls events from CodexThread and translates them
    async fn event_loop(
        thread: Arc<CodexThread>,
        tx: mpsc::Sender<ConnectorEvent>,
        output_buffers: Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        streaming_message: Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
        msg_counter: Arc<AtomicU64>,
    ) {
        loop {
            match thread.next_event().await {
                Ok(event) => {
                    let events = Self::translate_event(event, &output_buffers, &streaming_message, &msg_counter).await;
                    for ev in events {
                        if tx.send(ev).await.is_err() {
                            debug!("Event channel closed, stopping event loop");
                            return;
                        }
                    }
                }
                Err(e) => {
                    error!("Error reading codex event: {}", e);
                    let _ = tx
                        .send(ConnectorEvent::Error(format!("Event read error: {}", e)))
                        .await;
                    return;
                }
            }
        }
    }

    /// Translate a codex-core Event to ConnectorEvent(s)
    async fn translate_event(
        event: Event,
        output_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
        msg_counter: &AtomicU64,
    ) -> Vec<ConnectorEvent> {
        match event.msg {
            EventMsg::UserMessage(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let msg_id = format!("user-{}-{}", event.id, seq);
                let message = orbitdock_protocol::Message {
                    id: msg_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::User,
                    content: e.message,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::TurnStarted(_) => {
                vec![ConnectorEvent::TurnStarted]
            }

            EventMsg::TurnComplete(_) => {
                vec![ConnectorEvent::TurnCompleted]
            }

            EventMsg::TurnAborted(e) => {
                vec![ConnectorEvent::TurnAborted {
                    reason: format!("{:?}", e.reason),
                }]
            }

            EventMsg::AgentMessage(e) => {
                // If we were streaming deltas, finalize that message with the complete text
                let mut streaming = streaming_message.lock().await;
                if let Some(s) = streaming.take() {
                    vec![ConnectorEvent::MessageUpdated {
                        message_id: s.message_id,
                        content: Some(e.message),
                        tool_output: None,
                        is_error: None,
                        duration_ms: None,
                    }]
                } else {
                    // No streaming was in progress — create a fresh message
                    let message = orbitdock_protocol::Message {
                        id: event.id.clone(),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content: e.message,
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
            }

            EventMsg::AgentReasoning(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("thinking-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Thinking,
                    content: e.text,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ExecCommandBegin(e) => {
                let command_str = e.command.join(" ");
                // Initialize output buffer for this call
                {
                    let mut buffers = output_buffers.lock().await;
                    buffers.insert(e.call_id.clone(), String::new());
                }

                let message = orbitdock_protocol::Message {
                    id: e.call_id.clone(),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: command_str.clone(),
                    tool_name: Some("Bash".to_string()),
                    tool_input: Some(serde_json::to_string(&json!({"command": command_str})).unwrap_or_default()),
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ExecCommandOutputDelta(e) => {
                // Accumulate output — don't emit an event
                let chunk_str = String::from_utf8_lossy(&e.chunk).to_string();
                {
                    let mut buffers = output_buffers.lock().await;
                    if let Some(buf) = buffers.get_mut(&e.call_id) {
                        buf.push_str(&chunk_str);
                    }
                }
                vec![]
            }

            EventMsg::ExecCommandEnd(e) => {
                // Grab accumulated output (or use the aggregated_output from the event)
                let output = {
                    let mut buffers = output_buffers.lock().await;
                    buffers
                        .remove(&e.call_id)
                        .unwrap_or_else(|| e.aggregated_output.clone())
                };

                let output_str = if output.is_empty() {
                    e.aggregated_output.clone()
                } else {
                    output
                };

                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output_str),
                    is_error: Some(e.exit_code != 0),
                    duration_ms: Some(e.duration.as_millis() as u64),
                }]
            }

            EventMsg::PatchApplyBegin(e) => {
                // Build diff and file info from changes
                let files: Vec<String> = e.changes.keys().map(|p| p.display().to_string()).collect();
                let first_file = files.first().cloned().unwrap_or_default();
                let content = files.join(", ");

                // Build unified diff from all changes
                let unified_diff = e.changes.iter().map(|(path, change)| {
                    match change {
                        FileChange::Add { content } => {
                            format!("--- /dev/null\n+++ {}\n{}", path.display(),
                                content.lines().map(|l| format!("+{}", l)).collect::<Vec<_>>().join("\n"))
                        }
                        FileChange::Delete { content } => {
                            format!("--- {}\n+++ /dev/null\n{}", path.display(),
                                content.lines().map(|l| format!("-{}", l)).collect::<Vec<_>>().join("\n"))
                        }
                        FileChange::Update { unified_diff, .. } => {
                            format!("--- {}\n+++ {}\n{}", path.display(), path.display(), unified_diff)
                        }
                    }
                }).collect::<Vec<_>>().join("\n\n");

                let tool_input = serde_json::to_string(&json!({
                    "file_path": first_file,
                    "unified_diff": unified_diff,
                })).unwrap_or_default();

                let message = orbitdock_protocol::Message {
                    id: e.call_id.clone(),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content,
                    tool_name: Some("Edit".to_string()),
                    tool_input: Some(tool_input),
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::PatchApplyEnd(e) => {
                let output = if e.success {
                    "Applied successfully".to_string()
                } else {
                    format!("Failed: {}", e.stderr)
                };

                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(!e.success),
                    duration_ms: None,
                }]
            }

            EventMsg::McpToolCallBegin(e) => {
                let tool_name = format!("{}:{}", e.invocation.server, e.invocation.tool);
                let input_str = e
                    .invocation
                    .arguments
                    .as_ref()
                    .map(|v| serde_json::to_string(v).unwrap_or_default());

                let message = orbitdock_protocol::Message {
                    id: e.call_id.clone(),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: e.invocation.tool.clone(),
                    tool_name: Some(tool_name),
                    tool_input: input_str,
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::McpToolCallEnd(e) => {
                let (output, is_error) = match &e.result {
                    Ok(result) => (
                        serde_json::to_string(result).unwrap_or_default(),
                        false,
                    ),
                    Err(msg) => (msg.clone(), true),
                };

                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(is_error),
                    duration_ms: Some(e.duration.as_millis() as u64),
                }]
            }

            EventMsg::ExecApprovalRequest(e) => {
                let command = e.command.join(" ");
                // Use event.id (sub_id) as request_id — codex-core keys approvals by sub_id, not call_id
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: event.id.clone(),
                    approval_type: ApprovalType::Exec,
                    command: Some(command),
                    file_path: Some(e.cwd.display().to_string()),
                    diff: None,
                    question: None,
                }]
            }

            EventMsg::ApplyPatchApprovalRequest(e) => {
                // Build full diff from changes
                let files: Vec<String> = e.changes.keys().map(|p| p.display().to_string()).collect();
                let first_file = files.first().cloned();

                let diff = e.changes.iter().map(|(path, change)| {
                    match change {
                        FileChange::Add { content } => {
                            format!("--- /dev/null\n+++ {}\n{}", path.display(),
                                content.lines().map(|l| format!("+{}", l)).collect::<Vec<_>>().join("\n"))
                        }
                        FileChange::Delete { content } => {
                            format!("--- {}\n+++ /dev/null\n{}", path.display(),
                                content.lines().map(|l| format!("-{}", l)).collect::<Vec<_>>().join("\n"))
                        }
                        FileChange::Update { unified_diff, .. } => {
                            format!("--- {}\n+++ {}\n{}", path.display(), path.display(), unified_diff)
                        }
                    }
                }).collect::<Vec<_>>().join("\n\n");

                // Use event.id (sub_id) as request_id — codex-core keys approvals by sub_id, not call_id
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: event.id.clone(),
                    approval_type: ApprovalType::Patch,
                    command: None,
                    file_path: first_file,
                    diff: Some(diff),
                    question: None,
                }]
            }

            EventMsg::RequestUserInput(e) => {
                let question_text = e.questions.first().map(|q| q.question.clone());
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: e.call_id,
                    approval_type: ApprovalType::Question,
                    command: None,
                    file_path: None,
                    diff: None,
                    question: question_text,
                }]
            }

            EventMsg::TokenCount(e) => {
                if let Some(info) = e.info {
                    let last = &info.last_token_usage;
                    let usage = orbitdock_protocol::TokenUsage {
                        input_tokens: last.input_tokens.max(0) as u64,
                        output_tokens: last.output_tokens.max(0) as u64,
                        cached_tokens: last.cached_input_tokens.max(0) as u64,
                        context_window: info.model_context_window.unwrap_or(200_000).max(0) as u64,
                    };
                    vec![ConnectorEvent::TokensUpdated(usage)]
                } else {
                    vec![]
                }
            }

            EventMsg::TurnDiff(e) => {
                vec![ConnectorEvent::DiffUpdated(e.unified_diff)]
            }

            EventMsg::PlanUpdate(e) => {
                let plan = serde_json::to_string(&e).unwrap_or_default();
                vec![ConnectorEvent::PlanUpdated(plan)]
            }

            EventMsg::ShutdownComplete => {
                vec![ConnectorEvent::SessionEnded {
                    reason: "shutdown".to_string(),
                }]
            }

            EventMsg::Error(e) => {
                vec![ConnectorEvent::Error(e.message)]
            }

            EventMsg::AgentMessageContentDelta(e) => {
                let mut streaming = streaming_message.lock().await;
                match streaming.as_mut() {
                    None => {
                        // First delta — create the message bubble using item_id as unique ID
                        let msg_id = e.item_id.clone();
                        let message = orbitdock_protocol::Message {
                            id: msg_id.clone(),
                            session_id: String::new(),
                            message_type: orbitdock_protocol::MessageType::Assistant,
                            content: e.delta.clone(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            is_error: false,
                            timestamp: iso_now(),
                            duration_ms: None,
                        };
                        *streaming = Some(StreamingMessage {
                            message_id: msg_id,
                            content: e.delta,
                            last_broadcast: std::time::Instant::now(),
                            from_content_delta: true,
                        });
                        vec![ConnectorEvent::MessageCreated(message)]
                    }
                    Some(s) => {
                        // Accumulate content always
                        s.content.push_str(&e.delta);

                        // Only broadcast if enough time has passed
                        let now = std::time::Instant::now();
                        if now.duration_since(s.last_broadcast).as_millis() >= STREAM_THROTTLE_MS {
                            s.last_broadcast = now;
                            vec![ConnectorEvent::MessageUpdated {
                                message_id: s.message_id.clone(),
                                content: Some(s.content.clone()),
                                tool_output: None,
                                is_error: None,
                                duration_ms: None,
                            }]
                        } else {
                            vec![]
                        }
                    }
                }
            }

            // Legacy fallback — older codex-core versions send this instead.
            // Skipped when AgentMessageContentDelta is active (both fire simultaneously).
            EventMsg::AgentMessageDelta(e) => {
                let mut streaming = streaming_message.lock().await;
                match streaming.as_mut() {
                    None => {
                        let msg_id = event.id.clone();
                        let message = orbitdock_protocol::Message {
                            id: msg_id.clone(),
                            session_id: String::new(),
                            message_type: orbitdock_protocol::MessageType::Assistant,
                            content: e.delta.clone(),
                            tool_name: None,
                            tool_input: None,
                            tool_output: None,
                            is_error: false,
                            timestamp: iso_now(),
                            duration_ms: None,
                        };
                        *streaming = Some(StreamingMessage {
                            message_id: msg_id,
                            content: e.delta,
                            last_broadcast: std::time::Instant::now(),
                            from_content_delta: false,
                        });
                        vec![ConnectorEvent::MessageCreated(message)]
                    }
                    Some(s) => {
                        // Skip if AgentMessageContentDelta is already handling streaming
                        if s.from_content_delta {
                            return vec![];
                        }
                        s.content.push_str(&e.delta);
                        let now = std::time::Instant::now();
                        if now.duration_since(s.last_broadcast).as_millis() < STREAM_THROTTLE_MS {
                            return vec![];
                        }
                        s.last_broadcast = now;
                        vec![ConnectorEvent::MessageUpdated {
                            message_id: s.message_id.clone(),
                            content: Some(s.content.clone()),
                            tool_output: None,
                            is_error: None,
                            duration_ms: None,
                        }]
                    }
                }
            }

            // Ignore other high-frequency streaming events
            EventMsg::AgentReasoningDelta(_)
            | EventMsg::AgentReasoningRawContent(_)
            | EventMsg::AgentReasoningRawContentDelta(_)
            | EventMsg::AgentReasoningSectionBreak(_)
            | EventMsg::PlanDelta(_) => vec![],

            // Log but ignore other events
            other => {
                let name = format!("{:?}", other);
                let variant = name.split('(').next().unwrap_or(&name);
                debug!("Unhandled codex event: {}", variant);
                vec![]
            }
        }
    }

    /// Get the event receiver (can only be called once)
    pub fn take_event_rx(&mut self) -> Option<mpsc::Receiver<ConnectorEvent>> {
        self.event_rx.take()
    }

    /// Get the codex-core thread ID (used to link with rollout files)
    pub fn thread_id(&self) -> &str {
        &self.thread_id
    }

    // MARK: - Actions

    /// Send a user message (starts a turn)
    pub async fn send_message(&self, content: &str) -> Result<(), ConnectorError> {
        let op = Op::UserInput {
            items: vec![UserInput::Text {
                text: content.to_string(),
                text_elements: Vec::new(),
            }],
            final_output_json_schema: None,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to send message: {}", e)))?;

        info!("Sent user message");
        Ok(())
    }

    /// Interrupt the current turn
    pub async fn interrupt(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Interrupt)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to interrupt: {}", e)))?;

        info!("Interrupted turn");
        Ok(())
    }

    /// Approve or reject an exec request
    pub async fn approve_exec(&self, request_id: &str, approved: bool) -> Result<(), ConnectorError> {
        let decision = if approved {
            ReviewDecision::Approved
        } else {
            ReviewDecision::Denied
        };

        let op = Op::ExecApproval {
            id: request_id.to_string(),
            decision,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to approve exec: {}", e)))?;

        info!("Sent exec approval: {} = {}", request_id, approved);
        Ok(())
    }

    /// Approve or reject a patch request
    pub async fn approve_patch(&self, request_id: &str, approved: bool) -> Result<(), ConnectorError> {
        let decision = if approved {
            ReviewDecision::Approved
        } else {
            ReviewDecision::Denied
        };

        let op = Op::PatchApproval {
            id: request_id.to_string(),
            decision,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to approve patch: {}", e)))?;

        info!("Sent patch approval: {} = {}", request_id, approved);
        Ok(())
    }

    /// Answer a question
    pub async fn answer_question(
        &self,
        request_id: &str,
        answers: HashMap<String, String>,
    ) -> Result<(), ConnectorError> {
        let response = RequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(|(k, v)| {
                    (
                        k,
                        RequestUserInputAnswer {
                            answers: vec![v],
                        },
                    )
                })
                .collect(),
        };

        let op = Op::UserInputAnswer {
            id: request_id.to_string(),
            response,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to answer question: {}", e)))?;

        info!("Sent question answer: {}", request_id);
        Ok(())
    }

    /// Shutdown the thread
    pub async fn shutdown(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Shutdown)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to shutdown: {}", e)))?;

        info!("Sent shutdown");
        Ok(())
    }
}

/// Get current time as ISO 8601 string
fn iso_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let days_since_epoch = secs / 86400;
    let time_of_day = secs % 86400;
    let hours = time_of_day / 3600;
    let minutes = (time_of_day % 3600) / 60;
    let seconds = time_of_day % 60;

    let mut days = days_since_epoch as i64;
    let mut year = 1970i64;
    loop {
        let d = if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) { 366 } else { 365 };
        if days < d { break; }
        days -= d;
        year += 1;
    }

    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let months = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };

    let mut month = 1;
    for m in months {
        if days < m { break; }
        days -= m;
        month += 1;
    }

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, days + 1, hours, minutes, seconds
    )
}
