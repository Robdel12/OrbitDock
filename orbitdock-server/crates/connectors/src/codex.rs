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
use codex_core::features::Feature;
use codex_core::models_manager::manager::RefreshStrategy;
use codex_core::{AuthManager, CodexThread, ThreadManager};
use codex_protocol::protocol::{
    AskForApproval, Event, EventMsg, FileChange, Op, ReviewDecision, SandboxPolicy, SessionSource,
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
    pub async fn new(
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        info!("Creating codex-core connector for {}", cwd);

        // Resolve codex home directory (~/.codex)
        let codex_home = find_codex_home().map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to find codex home: {}", e))
        })?;

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

        // Set approval policy (defaults to "untrusted" if not specified)
        let policy = approval_policy.unwrap_or("untrusted");
        cli_overrides.push((
            "approval_policy".to_string(),
            toml::Value::String(policy.to_string()),
        ));

        // Set sandbox mode if specified (config key is "sandbox_mode", not "sandbox_policy")
        if let Some(sandbox) = sandbox_mode {
            cli_overrides.push((
                "sandbox_mode".to_string(),
                toml::Value::String(sandbox.to_string()),
            ));
        }

        // cwd is a ConfigOverrides field, not a TOML config field
        let harness_overrides = ConfigOverrides {
            cwd: Some(std::path::PathBuf::from(cwd)),
            ..Default::default()
        };

        let config =
            Config::load_with_cli_overrides_and_harness_overrides(cli_overrides, harness_overrides)
                .await
                .map_err(|e| {
                    ConnectorError::ProviderError(format!("Failed to load config: {}", e))
                })?;

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
                    let events = Self::translate_event(
                        event,
                        &output_buffers,
                        &streaming_message,
                        &msg_counter,
                    )
                    .await;
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
                    tool_input: Some(
                        serde_json::to_string(&json!({"command": command_str})).unwrap_or_default(),
                    ),
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
                let files: Vec<String> =
                    e.changes.keys().map(|p| p.display().to_string()).collect();
                let first_file = files.first().cloned().unwrap_or_default();
                let content = files.join(", ");

                // Build unified diff from all changes
                let unified_diff = e
                    .changes
                    .iter()
                    .map(|(path, change)| match change {
                        FileChange::Add { content } => {
                            format!(
                                "--- /dev/null\n+++ {}\n{}",
                                path.display(),
                                content
                                    .lines()
                                    .map(|l| format!("+{}", l))
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            )
                        }
                        FileChange::Delete { content } => {
                            format!(
                                "--- {}\n+++ /dev/null\n{}",
                                path.display(),
                                content
                                    .lines()
                                    .map(|l| format!("-{}", l))
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            )
                        }
                        FileChange::Update { unified_diff, .. } => {
                            format!(
                                "--- {}\n+++ {}\n{}",
                                path.display(),
                                path.display(),
                                unified_diff
                            )
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n");

                let tool_input = serde_json::to_string(&json!({
                    "file_path": first_file,
                    "unified_diff": unified_diff,
                }))
                .unwrap_or_default();

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
                    Ok(result) => (serde_json::to_string(result).unwrap_or_default(), false),
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
                let amendment = e
                    .proposed_execpolicy_amendment
                    .map(|a| a.command().to_vec());
                // Use event.id (sub_id) as request_id — codex-core keys approvals by sub_id, not call_id
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: event.id.clone(),
                    approval_type: ApprovalType::Exec,
                    command: Some(command),
                    file_path: Some(e.cwd.display().to_string()),
                    diff: None,
                    question: None,
                    proposed_amendment: amendment,
                }]
            }

            EventMsg::ApplyPatchApprovalRequest(e) => {
                // Build full diff from changes
                let files: Vec<String> =
                    e.changes.keys().map(|p| p.display().to_string()).collect();
                let first_file = files.first().cloned();

                let diff = e
                    .changes
                    .iter()
                    .map(|(path, change)| match change {
                        FileChange::Add { content } => {
                            format!(
                                "--- /dev/null\n+++ {}\n{}",
                                path.display(),
                                content
                                    .lines()
                                    .map(|l| format!("+{}", l))
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            )
                        }
                        FileChange::Delete { content } => {
                            format!(
                                "--- {}\n+++ /dev/null\n{}",
                                path.display(),
                                content
                                    .lines()
                                    .map(|l| format!("-{}", l))
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            )
                        }
                        FileChange::Update { unified_diff, .. } => {
                            format!(
                                "--- {}\n+++ {}\n{}",
                                path.display(),
                                path.display(),
                                unified_diff
                            )
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n");

                // Use event.id (sub_id) as request_id — codex-core keys approvals by sub_id, not call_id
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: event.id.clone(),
                    approval_type: ApprovalType::Patch,
                    command: None,
                    file_path: first_file,
                    diff: Some(diff),
                    question: None,
                    proposed_amendment: None,
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
                    proposed_amendment: None,
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

            EventMsg::ThreadNameUpdated(e) => {
                if let Some(name) = e.thread_name {
                    vec![ConnectorEvent::ThreadNameUpdated(name)]
                } else {
                    vec![]
                }
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

    /// Send a user message (starts a turn), with optional per-turn overrides
    pub async fn send_message(
        &self,
        content: &str,
        model: Option<&str>,
        effort: Option<&str>,
    ) -> Result<(), ConnectorError> {
        // Submit per-turn overrides before the user message when present
        if model.is_some() || effort.is_some() {
            let effort_value = effort.map(|e| match e {
                "low" => codex_protocol::openai_models::ReasoningEffort::Low,
                "medium" => codex_protocol::openai_models::ReasoningEffort::Medium,
                "high" => codex_protocol::openai_models::ReasoningEffort::High,
                _ => codex_protocol::openai_models::ReasoningEffort::Medium,
            });
            let override_op = Op::OverrideTurnContext {
                cwd: None,
                approval_policy: None,
                sandbox_policy: None,
                windows_sandbox_level: None,
                model: model.map(|m| m.to_string()),
                effort: effort_value.map(Some),
                summary: None,
                collaboration_mode: None,
                personality: None,
            };
            self.thread.submit(override_op).await.map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to override turn context: {}", e))
            })?;
            info!(
                "Submitted per-turn overrides: model={:?}, effort={:?}",
                model, effort
            );
        }

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

    /// Approve or reject an exec request with a specific decision
    pub async fn approve_exec(
        &self,
        request_id: &str,
        decision: &str,
        proposed_amendment: Option<Vec<String>>,
    ) -> Result<(), ConnectorError> {
        let review = match decision {
            "approved" => ReviewDecision::Approved,
            "approved_for_session" => ReviewDecision::ApprovedForSession,
            "approved_always" => {
                if let Some(cmd) = proposed_amendment {
                    ReviewDecision::ApprovedExecpolicyAmendment {
                        proposed_execpolicy_amendment:
                            codex_protocol::approvals::ExecPolicyAmendment::new(cmd),
                    }
                } else {
                    // Fallback to session-level if no amendment available
                    ReviewDecision::ApprovedForSession
                }
            }
            "abort" => ReviewDecision::Abort,
            _ => ReviewDecision::Denied,
        };

        let op = Op::ExecApproval {
            id: request_id.to_string(),
            decision: review,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to approve exec: {}", e)))?;

        info!("Sent exec approval: {} = {}", request_id, decision);
        Ok(())
    }

    /// Approve or reject a patch request with a specific decision
    pub async fn approve_patch(
        &self,
        request_id: &str,
        decision: &str,
    ) -> Result<(), ConnectorError> {
        let review = match decision {
            "approved" => ReviewDecision::Approved,
            "approved_for_session" => ReviewDecision::ApprovedForSession,
            "abort" => ReviewDecision::Abort,
            _ => ReviewDecision::Denied,
        };

        let op = Op::PatchApproval {
            id: request_id.to_string(),
            decision: review,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to approve patch: {}", e))
        })?;

        info!("Sent patch approval: {} = {}", request_id, decision);
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
                .map(|(k, v)| (k, RequestUserInputAnswer { answers: vec![v] }))
                .collect(),
        };

        let op = Op::UserInputAnswer {
            id: request_id.to_string(),
            response,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to answer question: {}", e))
        })?;

        info!("Sent question answer: {}", request_id);
        Ok(())
    }

    /// Set the thread name in codex-core
    pub async fn set_thread_name(&self, name: &str) -> Result<(), ConnectorError> {
        let op = Op::SetThreadName {
            name: name.to_string(),
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to set thread name: {}", e))
        })?;

        info!("Set thread name: {}", name);
        Ok(())
    }

    /// Update session config (approval policy and/or sandbox mode) mid-session
    pub async fn update_config(
        &self,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<(), ConnectorError> {
        let policy = approval_policy.map(|p| match p {
            "untrusted" => AskForApproval::UnlessTrusted,
            "on-failure" => AskForApproval::OnFailure,
            "on-request" => AskForApproval::OnRequest,
            "never" => AskForApproval::Never,
            _ => AskForApproval::OnRequest,
        });

        let sandbox = sandbox_mode.map(|s| match s {
            "danger-full-access" => SandboxPolicy::DangerFullAccess,
            "read-only" => SandboxPolicy::ReadOnly,
            "workspace-write" => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
            _ => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
        });

        let op = Op::OverrideTurnContext {
            cwd: None,
            approval_policy: policy,
            sandbox_policy: sandbox,
            windows_sandbox_level: None,
            model: None,
            effort: None,
            summary: None,
            collaboration_mode: None,
            personality: None,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to update config: {}", e))
        })?;

        info!(
            "Updated session config: approval={:?}, sandbox={:?}",
            approval_policy, sandbox_mode
        );
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

/// Discover currently available Codex models for this account/environment.
pub async fn discover_models() -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError> {
    let codex_home = find_codex_home()
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;
    let auth_manager = Arc::new(AuthManager::new(
        codex_home.clone(),
        true,
        AuthCredentialsStoreMode::Auto,
    ));
    let thread_manager = Arc::new(ThreadManager::new(codex_home, auth_manager, SessionSource::Mcp));

    let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    let harness_overrides = ConfigOverrides {
        cwd: Some(cwd),
        ..Default::default()
    };
    let mut config = Config::load_with_cli_overrides_and_harness_overrides(
        Vec::new(),
        harness_overrides,
    )
    .await
    .map_err(|e| ConnectorError::ProviderError(format!("Failed to load config: {}", e)))?;
    config.features.enable(Feature::RemoteModels);

    let models = thread_manager
        .list_models(&config, RefreshStrategy::OnlineIfUncached)
        .await
        .into_iter()
        .filter(|preset| preset.show_in_picker && preset.supported_in_api)
        .map(|preset| orbitdock_protocol::CodexModelOption {
            id: preset.id,
            model: preset.model,
            display_name: preset.display_name,
            description: preset.description,
            is_default: preset.is_default,
            supported_reasoning_efforts: preset
                .supported_reasoning_efforts
                .into_iter()
                .map(|e| e.effort.to_string())
                .collect(),
        })
        .collect();

    Ok(models)
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
        let d = if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
            366
        } else {
            365
        };
        if days < d {
            break;
        }
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
        if days < m {
            break;
        }
        days -= m;
        month += 1;
    }

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year,
        month,
        days + 1,
        hours,
        minutes,
        seconds
    )
}
