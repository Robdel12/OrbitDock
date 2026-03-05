//! Codex connector
//!
//! Direct integration with codex-core library.
//! No subprocess, no JSON-RPC — just Rust function calls.

pub mod auth;
pub mod rollout_parser;
pub mod session;

/// Re-export codex-arg0 init for server startup.
/// Must be called before the tokio runtime starts.
pub use codex_arg0::arg0_dispatch;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use codex_core::auth::AuthCredentialsStoreMode;
use codex_core::config::{find_codex_home, Config, ConfigOverrides};
use codex_core::models_manager::collaboration_mode_presets::CollaborationModesConfig;
use codex_core::models_manager::manager::RefreshStrategy;
use codex_core::{AuthManager, CodexThread, SteerInputError, ThreadManager};
use codex_protocol::config_types::{CollaborationMode, ModeKind, ReasoningSummary, Settings};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{
    AskForApproval, Event, EventMsg, FileChange, McpServerRefreshConfig, Op, ReviewDecision,
    SandboxPolicy, SessionSource,
};
use codex_protocol::request_user_input::{RequestUserInputAnswer, RequestUserInputResponse};
use codex_protocol::user_input::UserInput;
use serde_json::json;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use orbitdock_connector_core::{ApprovalType, ConnectorError, ConnectorEvent};

/// Outcome of a steer_turn attempt
pub enum SteerOutcome {
    /// The steer was accepted by the active turn
    Accepted,
    /// No active turn was running; fell back to starting a new turn
    FellBackToNewTurn,
}

/// Tracks an in-progress assistant message being streamed via deltas
struct StreamingMessage {
    message_id: String,
    content: String,
    last_broadcast: std::time::Instant,
    /// True if started by AgentMessageContentDelta (newer path).
    /// When set, AgentMessageDelta events are skipped to avoid doubling.
    from_content_delta: bool,
}

/// Determines which reasoning event stream is active for the current turn.
///
/// codex-protocol can emit both modern and legacy reasoning events for compatibility.
/// We process only one stream per turn to avoid duplicated timeline rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum ReasoningStreamMode {
    #[default]
    Unknown,
    Modern,
    Legacy,
}

#[derive(Debug, Default)]
struct ReasoningEventTracker {
    summary_mode: ReasoningStreamMode,
    raw_mode: ReasoningStreamMode,
}

impl ReasoningEventTracker {
    fn reset_for_turn(&mut self) {
        self.summary_mode = ReasoningStreamMode::Unknown;
        self.raw_mode = ReasoningStreamMode::Unknown;
    }

    fn should_process_modern_summary(&mut self) -> bool {
        match self.summary_mode {
            ReasoningStreamMode::Unknown => {
                self.summary_mode = ReasoningStreamMode::Modern;
                true
            }
            ReasoningStreamMode::Modern => true,
            ReasoningStreamMode::Legacy => false,
        }
    }

    fn should_process_legacy_summary(&mut self) -> bool {
        match self.summary_mode {
            ReasoningStreamMode::Unknown => {
                self.summary_mode = ReasoningStreamMode::Legacy;
                true
            }
            ReasoningStreamMode::Legacy => true,
            ReasoningStreamMode::Modern => false,
        }
    }

    fn mark_modern_summary_seen(&mut self) {
        if self.summary_mode == ReasoningStreamMode::Unknown {
            self.summary_mode = ReasoningStreamMode::Modern;
        }
    }

    fn should_process_modern_raw(&mut self) -> bool {
        match self.raw_mode {
            ReasoningStreamMode::Unknown => {
                self.raw_mode = ReasoningStreamMode::Modern;
                true
            }
            ReasoningStreamMode::Modern => true,
            ReasoningStreamMode::Legacy => false,
        }
    }

    fn should_process_legacy_raw(&mut self) -> bool {
        match self.raw_mode {
            ReasoningStreamMode::Unknown => {
                self.raw_mode = ReasoningStreamMode::Legacy;
                true
            }
            ReasoningStreamMode::Legacy => true,
            ReasoningStreamMode::Modern => false,
        }
    }
}

/// Tracks the current working directory so we only emit changes
struct EnvironmentTracker {
    cwd: Option<String>,
    branch: Option<String>,
    sha: Option<String>,
}

/// Minimum interval between streaming content broadcasts (ms)
const STREAM_THROTTLE_MS: u128 = 50;
const DEFAULT_CODEX_SHOW_RAW_REASONING: bool = true;
const DEFAULT_CODEX_HIDE_REASONING: bool = false;
const DEFAULT_CODEX_REASONING_SUMMARY: &str = "detailed";
const REASONING_SUMMARY_NONE: &str = "none";
const ENV_CODEX_SHOW_RAW_REASONING: &str = "ORBITDOCK_CODEX_SHOW_RAW_REASONING";
const ENV_CODEX_HIDE_REASONING: &str = "ORBITDOCK_CODEX_HIDE_REASONING";
const ENV_CODEX_REASONING_SUMMARY: &str = "ORBITDOCK_CODEX_REASONING_SUMMARY";

/// Codex connector using direct codex-core integration
pub struct CodexConnector {
    thread: Arc<CodexThread>,
    thread_manager: Arc<ThreadManager>,
    codex_home: PathBuf,
    event_rx: Option<mpsc::Receiver<ConnectorEvent>>,
    thread_id: String,
    current_model: Arc<tokio::sync::Mutex<Option<String>>>,
    current_reasoning_effort: Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
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
            codex_home.clone(),
            auth_manager.clone(),
            SessionSource::Mcp,
            None,
            CollaborationModesConfig::default(),
        ));

        let config = Self::build_config(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            thread_manager.as_ref(),
        )
        .await?;

        // Start a thread
        let new_thread = thread_manager
            .start_thread(config)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to start thread: {}", e)))?;

        Self::from_thread(new_thread, thread_manager, codex_home)
    }

    /// Resume a Codex session from an existing rollout file (preserves conversation history)
    pub async fn resume(
        cwd: &str,
        thread_id: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, ConnectorError> {
        info!(
            "Resuming codex-core connector for {} with thread {}",
            cwd, thread_id
        );

        let codex_home = find_codex_home().map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to find codex home: {}", e))
        })?;

        // Find the rollout file for this thread
        let rollout_path = codex_core::find_thread_path_by_id_str(&codex_home, thread_id)
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to find rollout for thread: {}", e))
            })?
            .ok_or_else(|| {
                ConnectorError::ProviderError(format!(
                    "No rollout file found for thread {}",
                    thread_id
                ))
            })?;

        info!("Found rollout at {:?}", rollout_path);

        let auth_manager = Arc::new(AuthManager::new(
            codex_home.clone(),
            true,
            AuthCredentialsStoreMode::Auto,
        ));

        let thread_manager = Arc::new(ThreadManager::new(
            codex_home.clone(),
            auth_manager.clone(),
            SessionSource::Mcp,
            None,
            CollaborationModesConfig::default(),
        ));

        let config = Self::build_config(
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            thread_manager.as_ref(),
        )
        .await?;

        let new_thread = thread_manager
            .resume_thread_from_rollout(config, rollout_path, auth_manager)
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to resume thread: {}", e))
            })?;

        Self::from_thread(new_thread, thread_manager, codex_home)
    }

    /// Build a Config with optional overrides
    async fn build_config(
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        thread_manager: &ThreadManager,
    ) -> Result<Config, ConnectorError> {
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

        // Reasoning trace defaults for OrbitDock direct sessions. These can be
        // overridden via environment variables for troubleshooting.
        let show_raw_reasoning = parse_bool_env(ENV_CODEX_SHOW_RAW_REASONING)
            .unwrap_or(DEFAULT_CODEX_SHOW_RAW_REASONING);
        let hide_reasoning =
            parse_bool_env(ENV_CODEX_HIDE_REASONING).unwrap_or(DEFAULT_CODEX_HIDE_REASONING);
        let mut reasoning_summary = parse_reasoning_summary_env(ENV_CODEX_REASONING_SUMMARY)
            .unwrap_or_else(|| DEFAULT_CODEX_REASONING_SUMMARY.to_string());
        if model_rejects_reasoning_summary(model) {
            reasoning_summary = REASONING_SUMMARY_NONE.to_string();
        }

        cli_overrides.push((
            "show_raw_agent_reasoning".to_string(),
            toml::Value::Boolean(show_raw_reasoning),
        ));
        cli_overrides.push((
            "hide_agent_reasoning".to_string(),
            toml::Value::Boolean(hide_reasoning),
        ));
        cli_overrides.push((
            "model_reasoning_summary".to_string(),
            toml::Value::String(reasoning_summary),
        ));

        // cwd is a ConfigOverrides field, not a TOML config field
        let harness_overrides = ConfigOverrides {
            cwd: Some(std::path::PathBuf::from(cwd)),
            codex_linux_sandbox_exe: None,
            ..Default::default()
        };

        let mut config =
            Config::load_with_cli_overrides_and_harness_overrides(cli_overrides, harness_overrides)
                .await
                .map_err(|e| {
                    ConnectorError::ProviderError(format!("Failed to load config: {}", e))
                })?;

        let supports_reasoning_summaries =
            model_supports_reasoning_summaries(thread_manager, &config).await;
        if should_disable_reasoning_summary(config.model.as_deref(), supports_reasoning_summaries) {
            config.model_reasoning_summary = Some(ReasoningSummary::None);
        }

        Ok(config)
    }

    /// Create a connector from an existing NewThread (shared by new() and fork_thread())
    fn from_thread(
        new_thread: codex_core::NewThread,
        thread_manager: Arc<ThreadManager>,
        codex_home: PathBuf,
    ) -> Result<Self, ConnectorError> {
        let thread = new_thread.thread;
        let thread_id = new_thread.thread_id;
        info!("Started codex thread: {:?}", thread_id);

        let (event_tx, event_rx) = mpsc::channel(256);
        let output_buffers = Arc::new(tokio::sync::Mutex::new(HashMap::<String, String>::new()));
        let delta_buffers = Arc::new(tokio::sync::Mutex::new(HashMap::<String, String>::new()));
        let streaming_message = Arc::new(tokio::sync::Mutex::new(Option::<StreamingMessage>::None));
        let msg_counter = Arc::new(AtomicU64::new(0));
        let env_tracker = Arc::new(tokio::sync::Mutex::new(EnvironmentTracker {
            cwd: None,
            branch: None,
            sha: None,
        }));
        let reasoning_tracker = Arc::new(tokio::sync::Mutex::new(ReasoningEventTracker::default()));
        let current_model = Arc::new(tokio::sync::Mutex::new(Option::<String>::None));
        let current_reasoning_effort =
            Arc::new(tokio::sync::Mutex::new(Option::<ReasoningEffort>::None));

        // Spawn async event loop
        let tx = event_tx.clone();
        let t = thread.clone();
        let buffers = output_buffers.clone();
        let deltas = delta_buffers.clone();
        let streaming = streaming_message.clone();
        let counter = msg_counter.clone();
        let tracker = env_tracker.clone();
        let reasoning = reasoning_tracker.clone();
        let model = current_model.clone();
        let effort = current_reasoning_effort.clone();
        tokio::spawn(async move {
            Self::event_loop(
                t, tx, buffers, deltas, streaming, counter, tracker, reasoning, model, effort,
            )
            .await;
        });

        Ok(Self {
            thread,
            thread_manager,
            codex_home,
            event_rx: Some(event_rx),
            thread_id: thread_id.to_string(),
            current_model,
            current_reasoning_effort,
        })
    }

    /// Fork this session's thread at a given point in history, returning a new connector
    pub async fn fork_thread(
        &self,
        nth_user_message: Option<u32>,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
        cwd: Option<&str>,
    ) -> Result<(CodexConnector, String), ConnectorError> {
        // Find the source rollout path (same approach as app-server)
        let rollout_path =
            codex_core::find_thread_path_by_id_str(&self.codex_home, &self.thread_id)
                .await
                .map_err(|e| {
                    ConnectorError::ProviderError(format!("Failed to find rollout path: {}", e))
                })?
                .ok_or_else(|| {
                    ConnectorError::ProviderError(format!(
                        "No rollout file found for thread {}",
                        self.thread_id
                    ))
                })?;

        // Build config with overrides — use source session's cwd as fallback
        let effective_cwd = cwd.unwrap_or(".");
        let config = Self::build_config(
            effective_cwd,
            model,
            approval_policy,
            sandbox_mode,
            self.thread_manager.as_ref(),
        )
        .await?;

        // Convert nth_user_message: None means full history (usize::MAX)
        let nth = nth_user_message.map(|n| n as usize).unwrap_or(usize::MAX);

        let new_thread = self
            .thread_manager
            .fork_thread(nth, config, rollout_path, false)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to fork thread: {}", e)))?;

        let new_thread_id = new_thread.thread_id.to_string();
        let connector = Self::from_thread(
            new_thread,
            self.thread_manager.clone(),
            self.codex_home.clone(),
        )?;

        Ok((connector, new_thread_id))
    }

    /// Async event loop — pulls events from CodexThread and translates them
    #[allow(clippy::too_many_arguments)]
    async fn event_loop(
        thread: Arc<CodexThread>,
        tx: mpsc::Sender<ConnectorEvent>,
        output_buffers: Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        delta_buffers: Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        streaming_message: Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
        msg_counter: Arc<AtomicU64>,
        env_tracker: Arc<tokio::sync::Mutex<EnvironmentTracker>>,
        reasoning_tracker: Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
        current_model: Arc<tokio::sync::Mutex<Option<String>>>,
        current_reasoning_effort: Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
    ) {
        loop {
            match thread.next_event().await {
                Ok(event) => {
                    // Box::pin keeps the large translate_event future (driven
                    // by the ever-growing EventMsg enum) on the heap so it
                    // doesn't blow the default tokio thread stack.
                    let events = Box::pin(Self::translate_event(
                        event,
                        &output_buffers,
                        &delta_buffers,
                        &streaming_message,
                        &msg_counter,
                        &env_tracker,
                        &reasoning_tracker,
                        &current_model,
                        &current_reasoning_effort,
                    ))
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
    #[allow(clippy::too_many_arguments)]
    async fn translate_event(
        event: Event,
        output_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        streaming_message: &Arc<tokio::sync::Mutex<Option<StreamingMessage>>>,
        msg_counter: &AtomicU64,
        env_tracker: &Arc<tokio::sync::Mutex<EnvironmentTracker>>,
        reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
        current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
        current_reasoning_effort: &Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
    ) -> Vec<ConnectorEvent> {
        #[allow(unreachable_patterns)]
        match event.msg {
            EventMsg::UserMessage(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let msg_id = format!("user-{}-{}", event.id, seq);

                let mut images: Vec<orbitdock_protocol::ImageInput> = Vec::new();
                if let Some(urls) = &e.images {
                    for url in urls {
                        images.push(orbitdock_protocol::ImageInput {
                            input_type: "url".to_string(),
                            value: url.clone(),
                        });
                    }
                }
                for path in &e.local_images {
                    images.push(orbitdock_protocol::ImageInput {
                        input_type: "path".to_string(),
                        value: path.to_string_lossy().to_string(),
                    });
                }

                let message = orbitdock_protocol::Message {
                    id: msg_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::User,
                    content: e.message,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images,
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::TurnStarted(_) => {
                {
                    let mut buffers = delta_buffers.lock().await;
                    buffers.clear();
                }
                {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.reset_for_turn();
                }
                vec![ConnectorEvent::TurnStarted]
            }

            EventMsg::TurnComplete(_) => {
                let pending_delta_ids = {
                    let mut buffers = delta_buffers.lock().await;
                    let ids = buffers.keys().cloned().collect::<Vec<_>>();
                    buffers.clear();
                    ids
                };
                {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.reset_for_turn();
                }
                let mut events = vec![ConnectorEvent::TurnCompleted];
                for message_id in pending_delta_ids {
                    events.push(ConnectorEvent::MessageUpdated {
                        message_id,
                        content: None,
                        tool_output: None,
                        is_error: None,
                        is_in_progress: Some(false),
                        duration_ms: None,
                    });
                }
                events
            }

            EventMsg::TurnAborted(e) => {
                let pending_delta_ids = {
                    let mut buffers = delta_buffers.lock().await;
                    let ids = buffers.keys().cloned().collect::<Vec<_>>();
                    buffers.clear();
                    ids
                };
                {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.reset_for_turn();
                }
                let mut events = vec![ConnectorEvent::TurnAborted {
                    reason: format!("{:?}", e.reason),
                }];
                for message_id in pending_delta_ids {
                    events.push(ConnectorEvent::MessageUpdated {
                        message_id,
                        content: None,
                        tool_output: None,
                        is_error: None,
                        is_in_progress: Some(false),
                        duration_ms: None,
                    });
                }
                events
            }

            EventMsg::SessionConfigured(e) => {
                let cwd_str = e.cwd.to_string_lossy().to_string();
                {
                    let mut model = current_model.lock().await;
                    *model = Some(e.model.clone());
                }
                {
                    let mut effort = current_reasoning_effort.lock().await;
                    *effort = e.reasoning_effort;
                }

                // Look up git info from the cwd
                let git_info = codex_core::git_info::collect_git_info(&e.cwd).await;
                let (branch, sha) = match git_info {
                    Some(info) => (info.branch, info.commit_hash),
                    None => (None, None),
                };

                // Seed tracker with initial environment
                {
                    let mut tracker = env_tracker.lock().await;
                    tracker.cwd = Some(cwd_str.clone());
                    tracker.branch = branch.clone();
                    tracker.sha = sha.clone();
                }

                vec![ConnectorEvent::EnvironmentChanged {
                    cwd: Some(cwd_str),
                    git_branch: branch,
                    git_sha: sha,
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
                        is_in_progress: Some(false),
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
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
            }

            EventMsg::AgentReasoning(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_legacy_summary()
                };
                if !should_process {
                    return vec![];
                }
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("thinking-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Thinking,
                    content: e.text,
                    tool_name: None,
                    tool_input: reasoning_trace_metadata_json("summary", "legacy", None, None),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ExecCommandBegin(e) => {
                let command_str = e.command.join(" ");
                let tool_input = serde_json::to_string(&json!({
                    "command": command_str.clone(),
                    "argv": e.command.clone(),
                    "cwd": e.cwd.display().to_string(),
                    "source": e.source.to_string(),
                    "call_id": e.call_id.clone(),
                    "turn_id": e.turn_id.clone(),
                    "process_id": e.process_id.clone(),
                    "interaction_input": e.interaction_input.clone(),
                    "parsed_cmd": e.parsed_cmd.clone(),
                }))
                .ok();
                // Initialize output buffer for this call
                {
                    let mut buffers = output_buffers.lock().await;
                    buffers.insert(e.call_id.clone(), String::new());
                }

                // Re-collect git info on every command — the agent may have
                // changed branches without changing cwd (e.g. `git checkout`)
                let new_cwd = e.cwd.to_string_lossy().to_string();
                let git_info = codex_core::git_info::collect_git_info(&e.cwd).await;
                let (new_branch, new_sha) = match git_info {
                    Some(info) => (info.branch, info.commit_hash),
                    None => (None, None),
                };
                let mut events = Vec::new();
                {
                    let mut tracker = env_tracker.lock().await;
                    let cwd_changed = tracker.cwd.as_deref() != Some(&new_cwd);
                    let branch_changed = tracker.branch != new_branch;
                    let sha_changed = tracker.sha != new_sha;
                    if cwd_changed || branch_changed || sha_changed {
                        tracker.cwd = Some(new_cwd.clone());
                        tracker.branch = new_branch.clone();
                        tracker.sha = new_sha.clone();
                        events.push(ConnectorEvent::EnvironmentChanged {
                            cwd: Some(new_cwd),
                            git_branch: new_branch,
                            git_sha: new_sha,
                        });
                    }
                }

                let message = orbitdock_protocol::Message {
                    id: e.call_id.clone(),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: command_str.clone(),
                    tool_name: Some("Bash".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                events.push(ConnectorEvent::MessageCreated(message));
                events
            }

            EventMsg::ExecCommandOutputDelta(e) => {
                let chunk_str = String::from_utf8_lossy(&e.chunk).to_string();
                let mut accumulated = String::new();
                {
                    let mut buffers = output_buffers.lock().await;
                    if let Some(buf) = buffers.get_mut(&e.call_id) {
                        buf.push_str(&chunk_str);
                        accumulated = buf.clone();
                    }
                }

                if accumulated.is_empty() {
                    vec![]
                } else {
                    vec![ConnectorEvent::MessageUpdated {
                        message_id: e.call_id,
                        content: None,
                        tool_output: Some(accumulated),
                        is_error: None,
                        is_in_progress: Some(true),
                        duration_ms: None,
                    }]
                }
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
                    is_in_progress: Some(false),
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
                    "files": files,
                    "call_id": e.call_id,
                    "turn_id": e.turn_id,
                    "auto_approved": e.auto_approved,
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
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::PatchApplyEnd(e) => {
                let mut output_lines: Vec<String> = Vec::new();
                output_lines.push(format!("status: {:?}", e.status));
                if e.success {
                    output_lines.push("result: applied successfully".to_string());
                } else {
                    output_lines.push("result: failed".to_string());
                }
                if !e.stdout.trim().is_empty() {
                    output_lines.push(String::new());
                    output_lines.push("stdout:".to_string());
                    output_lines.push(e.stdout);
                }
                if !e.stderr.trim().is_empty() {
                    output_lines.push(String::new());
                    output_lines.push("stderr:".to_string());
                    output_lines.push(e.stderr);
                }
                let output = output_lines.join("\n");

                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(!e.success),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::McpToolCallBegin(e) => {
                let server = e.invocation.server.clone();
                let tool = e.invocation.tool.clone();
                let call_id = e.call_id.clone();
                let tool_name = format!("mcp__{}__{}", server, tool);
                let input_str = tool_input_with_arguments(
                    json!({
                        "call_id": call_id.clone(),
                        "server": server,
                        "tool": tool,
                    }),
                    e.invocation.arguments.as_ref(),
                );

                let message = orbitdock_protocol::Message {
                    id: call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: e.invocation.tool.clone(),
                    tool_name: Some(tool_name),
                    tool_input: input_str,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
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
                    is_in_progress: Some(false),
                    duration_ms: Some(e.duration.as_millis() as u64),
                }]
            }

            EventMsg::WebSearchBegin(e) => {
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Searching the web".to_string(),
                    tool_name: Some("websearch".to_string()),
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::WebSearchEnd(e) => {
                let query = e.query;
                let output = serde_json::to_string_pretty(&e.action)
                    .or_else(|_| serde_json::to_string(&e.action))
                    .unwrap_or_default();
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: Some(query),
                    tool_output: Some(output),
                    is_error: Some(false),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::ViewImageToolCall(e) => {
                let path = e.path.to_string_lossy().to_string();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: path.clone(),
                    tool_name: Some("view_image".to_string()),
                    tool_input: serde_json::to_string(&json!({ "path": path })).ok(),
                    tool_output: Some("Image loaded".to_string()),
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![orbitdock_protocol::ImageInput {
                        input_type: "path".to_string(),
                        value: e.path.to_string_lossy().to_string(),
                    }],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::DynamicToolCallRequest(e) => {
                let call_id = e.call_id.clone();
                let turn_id = e.turn_id.clone();
                let tool = e.tool.clone();
                let message = orbitdock_protocol::Message {
                    id: call_id.clone(),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: tool.clone(),
                    tool_name: Some(tool),
                    tool_input: tool_input_with_arguments(
                        json!({
                            "call_id": call_id,
                            "turn_id": turn_id,
                        }),
                        Some(&e.arguments),
                    ),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::DynamicToolCallResponse(e) => {
                let output = dynamic_tool_output_to_text(&e.content_items, e.error);
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: output,
                    is_error: Some(!e.success),
                    is_in_progress: Some(false),
                    duration_ms: Some(e.duration.as_millis() as u64),
                }]
            }

            EventMsg::TerminalInteraction(e) => {
                let snippet = format!("\n[stdin] {}\n", e.stdin);
                let next_output = {
                    let mut buffers = output_buffers.lock().await;
                    let entry = buffers.entry(e.call_id.clone()).or_default();
                    entry.push_str(&snippet);
                    entry.clone()
                };

                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(next_output),
                    is_error: None,
                    is_in_progress: Some(true),
                    duration_ms: None,
                }]
            }

            EventMsg::CollabAgentSpawnBegin(e) => {
                let description = if e.prompt.trim().is_empty() {
                    "Spawning agent".to_string()
                } else {
                    e.prompt.clone()
                };
                let tool_input = serde_json::to_string(&json!({
                    "subagent_type": "spawn_agent",
                    "description": description,
                    "sender_thread_id": e.sender_thread_id.to_string(),
                    "prompt": e.prompt,
                }))
                .ok();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Spawn agent".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::CollabAgentSpawnEnd(e) => {
                let receiver = e
                    .new_thread_id
                    .map(|id| id.to_string())
                    .unwrap_or_else(|| "none".to_string());
                let receiver_label = collab_agent_label(
                    &receiver,
                    e.new_agent_nickname.as_deref(),
                    e.new_agent_role.as_deref(),
                );
                let status_text = format!("{:?}", e.status);
                let output = format!(
                    "sender: {}\nspawned: {}\nstatus: {}",
                    e.sender_thread_id, receiver_label, status_text
                );
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(agent_status_failed(&e.status)),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::CollabAgentInteractionBegin(e) => {
                let tool_input = serde_json::to_string(&json!({
                    "subagent_type": "agent",
                    "description": e.prompt,
                    "sender_thread_id": e.sender_thread_id.to_string(),
                    "receiver_thread_id": e.receiver_thread_id.to_string(),
                }))
                .ok();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Agent interaction".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::CollabAgentInteractionEnd(e) => {
                let status_text = format!("{:?}", e.status);
                let receiver_label = collab_agent_label(
                    &e.receiver_thread_id.to_string(),
                    e.receiver_agent_nickname.as_deref(),
                    e.receiver_agent_role.as_deref(),
                );
                let output = format!(
                    "sender: {}\nreceiver: {}\nstatus: {}",
                    e.sender_thread_id, receiver_label, status_text
                );
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(agent_status_failed(&e.status)),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::CollabWaitingBegin(e) => {
                let receiver_ids: Vec<String> = e
                    .receiver_thread_ids
                    .iter()
                    .map(ToString::to_string)
                    .collect();
                let receiver_agents: Vec<serde_json::Value> = e
                    .receiver_agents
                    .iter()
                    .map(|agent| {
                        json!({
                            "thread_id": agent.thread_id.to_string(),
                            "agent_nickname": agent.agent_nickname,
                            "agent_role": agent.agent_role,
                        })
                    })
                    .collect();
                let tool_input = serde_json::to_string(&json!({
                    "subagent_type": "wait",
                    "description": format!("Waiting for {} agent(s)", receiver_ids.len()),
                    "sender_thread_id": e.sender_thread_id.to_string(),
                    "receiver_thread_ids": receiver_ids,
                    "receiver_agents": receiver_agents,
                }))
                .ok();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Waiting for agents".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::CollabWaitingEnd(e) => {
                let mut lines: Vec<String> = Vec::new();
                let mut has_error = false;
                lines.push(format!("sender: {}", e.sender_thread_id));
                if !e.agent_statuses.is_empty() {
                    for entry in &e.agent_statuses {
                        let status_text = format!("{:?}", entry.status);
                        let label = collab_agent_label(
                            &entry.thread_id.to_string(),
                            entry.agent_nickname.as_deref(),
                            entry.agent_role.as_deref(),
                        );
                        lines.push(format!("{label}: {status_text}"));
                        has_error = has_error || agent_status_failed(&entry.status);
                    }
                } else {
                    for (thread_id, status) in &e.statuses {
                        let status_text = format!("{:?}", status);
                        lines.push(format!("{thread_id}: {status_text}"));
                        has_error = has_error || agent_status_failed(status);
                    }
                }
                let output = if lines.is_empty() {
                    "No agent statuses reported".to_string()
                } else {
                    lines.join("\n")
                };
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(has_error),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::CollabCloseBegin(e) => {
                let tool_input = serde_json::to_string(&json!({
                    "subagent_type": "close",
                    "description": "Closing agent",
                    "sender_thread_id": e.sender_thread_id.to_string(),
                    "receiver_thread_id": e.receiver_thread_id.to_string(),
                }))
                .ok();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Close agent".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::CollabCloseEnd(e) => {
                let status_text = format!("{:?}", e.status);
                let receiver_label = collab_agent_label(
                    &e.receiver_thread_id.to_string(),
                    e.receiver_agent_nickname.as_deref(),
                    e.receiver_agent_role.as_deref(),
                );
                let output = format!(
                    "sender: {}\nreceiver: {}\nstatus: {}",
                    e.sender_thread_id, receiver_label, status_text
                );
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(agent_status_failed(&e.status)),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::CollabResumeBegin(e) => {
                let tool_input = serde_json::to_string(&json!({
                    "subagent_type": "resume",
                    "description": "Resuming agent",
                    "sender_thread_id": e.sender_thread_id.to_string(),
                    "receiver_thread_id": e.receiver_thread_id.to_string(),
                    "receiver_agent_nickname": e.receiver_agent_nickname,
                    "receiver_agent_role": e.receiver_agent_role,
                }))
                .ok();
                let message = orbitdock_protocol::Message {
                    id: e.call_id,
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Resume agent".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::CollabResumeEnd(e) => {
                let status_text = format!("{:?}", e.status);
                let receiver_label = collab_agent_label(
                    &e.receiver_thread_id.to_string(),
                    e.receiver_agent_nickname.as_deref(),
                    e.receiver_agent_role.as_deref(),
                );
                let output = format!(
                    "sender: {}\nreceiver: {}\nstatus: {}",
                    e.sender_thread_id, receiver_label, status_text
                );
                vec![ConnectorEvent::MessageUpdated {
                    message_id: e.call_id,
                    content: None,
                    tool_output: Some(output),
                    is_error: Some(agent_status_failed(&e.status)),
                    is_in_progress: Some(false),
                    duration_ms: None,
                }]
            }

            EventMsg::ExecApprovalRequest(e) => {
                let command = e.command.join(" ");
                let amendment = e
                    .proposed_execpolicy_amendment
                    .map(|a| a.command().to_vec());
                // codex-core matches approvals by approval_id (execve intercept) or call_id.
                let request_id = e.approval_id.clone().unwrap_or_else(|| e.call_id.clone());
                vec![ConnectorEvent::ApprovalRequested {
                    request_id,
                    approval_type: ApprovalType::Exec,
                    tool_name: None,
                    tool_input: None,
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

                // codex-core matches patch approvals by call_id.
                vec![ConnectorEvent::ApprovalRequested {
                    request_id: e.call_id.clone(),
                    approval_type: ApprovalType::Patch,
                    tool_name: None,
                    tool_input: None,
                    command: None,
                    file_path: first_file,
                    diff: Some(diff),
                    question: None,
                    proposed_amendment: None,
                }]
            }

            EventMsg::RequestUserInput(e) => {
                let question_text = e.questions.first().map(|q| q.question.clone());
                let tool_input = serde_json::to_string(&serde_json::json!({
                    "questions": e.questions,
                }))
                .ok();
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("ask-user-question-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: question_text
                        .clone()
                        .unwrap_or_else(|| "Question requested".to_string()),
                    tool_name: Some("askuserquestion".to_string()),
                    tool_input: tool_input.clone(),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![
                    ConnectorEvent::MessageCreated(message),
                    ConnectorEvent::ApprovalRequested {
                        request_id: event.id.clone(),
                        approval_type: ApprovalType::Question,
                        tool_name: None,
                        tool_input,
                        command: None,
                        file_path: None,
                        diff: None,
                        question: question_text,
                        proposed_amendment: None,
                    },
                ]
            }

            EventMsg::ElicitationRequest(e) => {
                let question_text = if e.message.is_empty() {
                    Some(format!("{} request", e.server_name))
                } else {
                    Some(e.message.clone())
                };
                let tool_input = serde_json::to_string(&e).ok();
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("mcp-approval-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: question_text
                        .clone()
                        .unwrap_or_else(|| "MCP approval requested".to_string()),
                    tool_name: Some("mcp_approval".to_string()),
                    tool_input: tool_input.clone(),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![
                    ConnectorEvent::MessageCreated(message),
                    ConnectorEvent::ApprovalRequested {
                        request_id: format!(
                            "elicitation-{}-{}",
                            e.server_name,
                            serde_json::to_string(&e.id).unwrap_or_else(|_| "request".to_string())
                        ),
                        approval_type: ApprovalType::Question,
                        tool_name: Some("mcp_approval".to_string()),
                        tool_input,
                        command: None,
                        file_path: None,
                        diff: None,
                        question: question_text,
                        proposed_amendment: None,
                    },
                ]
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
                    vec![ConnectorEvent::TokensUpdated {
                        usage,
                        snapshot_kind: orbitdock_protocol::TokenUsageSnapshotKind::ContextTurn,
                    }]
                } else {
                    vec![]
                }
            }

            EventMsg::TurnDiff(e) => {
                vec![ConnectorEvent::DiffUpdated(e.unified_diff)]
            }

            EventMsg::PlanUpdate(e) => {
                let plan = serde_json::to_string(&e).unwrap_or_default();
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let explanation = e
                    .explanation
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("Plan updated");
                let content = format!("{} ({} steps)", explanation, e.plan.len());
                let message = orbitdock_protocol::Message {
                    id: format!("update-plan-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content,
                    tool_name: Some("update_plan".to_string()),
                    tool_input: serde_json::to_string(&e).ok(),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![
                    ConnectorEvent::PlanUpdated(plan),
                    ConnectorEvent::MessageCreated(message),
                ]
            }

            EventMsg::PlanDelta(e) => {
                let message_id = format!("plan-{}", e.item_id);
                Self::apply_delta_message(
                    delta_buffers,
                    message_id,
                    e.delta,
                    orbitdock_protocol::MessageType::Thinking,
                    None,
                )
                .await
            }

            EventMsg::Warning(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("warning-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content: e.message,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ModelReroute(e) => {
                {
                    let mut model = current_model.lock().await;
                    *model = Some(e.to_model.clone());
                }
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let reason = format!("{:?}", e.reason);
                let message = orbitdock_protocol::Message {
                    id: format!("model-reroute-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content: format!(
                        "Model rerouted from {} to {} ({})",
                        e.from_model, e.to_model, reason
                    ),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::RealtimeConversationStarted(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let content = match e.session_id {
                    Some(session_id) if !session_id.is_empty() => {
                        format!("Realtime conversation started ({session_id})")
                    }
                    _ => "Realtime conversation started".to_string(),
                };
                let message = orbitdock_protocol::Message {
                    id: format!("realtime-start-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::RealtimeConversationRealtime(e) => match e.payload {
                codex_protocol::protocol::RealtimeEvent::SessionCreated { session_id } => {
                    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                    let message = orbitdock_protocol::Message {
                        id: format!("realtime-session-created-{}-{}", event.id, seq),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content: format!("Realtime session created ({session_id})"),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
                codex_protocol::protocol::RealtimeEvent::SessionUpdated { backend_prompt } => {
                    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                    let content = match backend_prompt {
                        Some(prompt) if !prompt.trim().is_empty() => {
                            format!(
                                "Realtime session updated\n\n{}",
                                truncate_for_display(&prompt, 300)
                            )
                        }
                        _ => "Realtime session updated".to_string(),
                    };
                    let message = orbitdock_protocol::Message {
                        id: format!("realtime-session-updated-{}-{}", event.id, seq),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content,
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
                codex_protocol::protocol::RealtimeEvent::ConversationItemAdded(item) => {
                    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                    let item_text = serde_json::to_string_pretty(&item)
                        .or_else(|_| serde_json::to_string(&item))
                        .unwrap_or_default();
                    let message = orbitdock_protocol::Message {
                        id: format!("realtime-item-added-{}-{}", event.id, seq),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content: format!(
                            "Realtime conversation item added\n\n{}",
                            truncate_for_display(&item_text, 500)
                        ),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
                // Audio frames are intentionally omitted from the timeline to avoid
                // flooding the UI with high-frequency events.
                codex_protocol::protocol::RealtimeEvent::AudioOut(_) => vec![],
                codex_protocol::protocol::RealtimeEvent::Error(message_text) => {
                    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                    let message = orbitdock_protocol::Message {
                        id: format!("realtime-error-{}-{}", event.id, seq),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content: format!("Realtime conversation error: {}", message_text),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: true,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
            },

            EventMsg::RealtimeConversationClosed(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let content = match e.reason {
                    Some(reason) if !reason.trim().is_empty() => {
                        format!("Realtime conversation closed: {}", reason)
                    }
                    _ => "Realtime conversation closed".to_string(),
                };
                let message = orbitdock_protocol::Message {
                    id: format!("realtime-closed-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::DeprecationNotice(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let details = e.details.unwrap_or_default();
                let content = if details.is_empty() {
                    e.summary
                } else {
                    format!("{}\n\n{}", e.summary, details)
                };
                let message = orbitdock_protocol::Message {
                    id: format!("deprecation-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::BackgroundEvent(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("background-event-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content: e.message,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
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

            EventMsg::StreamError(e) => {
                let details = e.additional_details.unwrap_or_default();
                let content = if details.is_empty() {
                    e.message
                } else {
                    format!("{}\n\n{}", e.message, details)
                };
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("stream-error-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: true,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
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
                            is_in_progress: true,
                            timestamp: iso_now(),
                            duration_ms: None,
                            images: vec![],
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
                                is_in_progress: Some(true),
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
                            is_in_progress: true,
                            timestamp: iso_now(),
                            duration_ms: None,
                            images: vec![],
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
                            is_in_progress: Some(true),
                            duration_ms: None,
                        }]
                    }
                }
            }

            EventMsg::ReasoningContentDelta(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_modern_summary()
                };
                if !should_process {
                    return vec![];
                }
                let message_id = format!("reasoning-summary-{}-{}", e.item_id, e.summary_index);
                Self::apply_delta_message(
                    delta_buffers,
                    message_id,
                    e.delta,
                    orbitdock_protocol::MessageType::Thinking,
                    reasoning_trace_metadata_json(
                        "summary",
                        "modern",
                        Some(e.item_id.as_str()),
                        Some(e.summary_index),
                    ),
                )
                .await
            }

            EventMsg::ReasoningRawContentDelta(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_modern_raw()
                };
                if !should_process {
                    return vec![];
                }
                let message_id = format!("reasoning-raw-{}-{}", e.item_id, e.content_index);
                Self::apply_delta_message(
                    delta_buffers,
                    message_id,
                    e.delta,
                    orbitdock_protocol::MessageType::Thinking,
                    reasoning_trace_metadata_json(
                        "raw",
                        "modern",
                        Some(e.item_id.as_str()),
                        Some(e.content_index),
                    ),
                )
                .await
            }

            EventMsg::AgentReasoningDelta(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_legacy_summary()
                };
                if !should_process {
                    return vec![];
                }
                let message_id = format!("reasoning-summary-legacy-{}", event.id);
                Self::apply_delta_message(
                    delta_buffers,
                    message_id,
                    e.delta,
                    orbitdock_protocol::MessageType::Thinking,
                    reasoning_trace_metadata_json("summary", "legacy", None, None),
                )
                .await
            }

            EventMsg::AgentReasoningRawContent(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_legacy_raw()
                };
                if !should_process {
                    return vec![];
                }
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("reasoning-raw-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Thinking,
                    content: e.text,
                    tool_name: None,
                    tool_input: reasoning_trace_metadata_json("raw", "legacy", None, None),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::AgentReasoningRawContentDelta(e) => {
                let should_process = {
                    let mut tracker = reasoning_tracker.lock().await;
                    tracker.should_process_legacy_raw()
                };
                if !should_process {
                    return vec![];
                }
                let message_id = format!("reasoning-raw-legacy-{}", event.id);
                Self::apply_delta_message(
                    delta_buffers,
                    message_id,
                    e.delta,
                    orbitdock_protocol::MessageType::Thinking,
                    reasoning_trace_metadata_json("raw", "legacy", None, None),
                )
                .await
            }

            EventMsg::AgentReasoningSectionBreak(_) => {
                // Separator-only signal for reasoning summaries. We use summary/content deltas for
                // visible rows and do not render placeholder "Reasoning section N" messages.
                let mut tracker = reasoning_tracker.lock().await;
                tracker.mark_modern_summary_seen();
                vec![]
            }

            EventMsg::EnteredReviewMode(e) => {
                let summary = review_request_summary(&e);
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let message = orbitdock_protocol::Message {
                    id: format!("review-entered-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Enter review mode".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input: serde_json::to_string(&json!({
                        "subagent_type": "review",
                        "description": summary,
                    }))
                    .ok(),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ExitedReviewMode(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let output = e
                    .review_output
                    .map(|r| render_review_output(&r))
                    .unwrap_or_else(|| "Review mode exited.".to_string());
                let message = orbitdock_protocol::Message {
                    id: format!("review-exited-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Tool,
                    content: "Exit review mode".to_string(),
                    tool_name: Some("task".to_string()),
                    tool_input: serde_json::to_string(&json!({
                        "subagent_type": "review",
                        "description": "Review completed",
                    }))
                    .ok(),
                    tool_output: Some(output),
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ItemStarted(e) => match e.item {
                // Most TurnItem variants also emit legacy compatibility events.
                // We only render variants that add unique value to this timeline.
                codex_protocol::items::TurnItem::Plan(item) => {
                    Self::apply_delta_message(
                        delta_buffers,
                        format!("plan-{}", item.id),
                        item.text,
                        orbitdock_protocol::MessageType::Thinking,
                        None,
                    )
                    .await
                }
                codex_protocol::items::TurnItem::ContextCompaction(item) => {
                    let message = orbitdock_protocol::Message {
                        id: item.id,
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Tool,
                        content: "Compacting context".to_string(),
                        tool_name: Some("compactcontext".to_string()),
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: true,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
                _ => vec![],
            },

            EventMsg::ItemCompleted(e) => match e.item {
                // Most TurnItem variants also emit legacy compatibility events.
                // We only render variants that add unique value to this timeline.
                codex_protocol::items::TurnItem::Plan(item) => {
                    let message_id = format!("plan-{}", item.id);
                    {
                        let mut buffers = delta_buffers.lock().await;
                        buffers.remove(&message_id);
                    }
                    vec![ConnectorEvent::MessageUpdated {
                        message_id,
                        content: Some(item.text),
                        tool_output: None,
                        is_error: None,
                        is_in_progress: Some(false),
                        duration_ms: None,
                    }]
                }
                codex_protocol::items::TurnItem::Reasoning(item) => {
                    let mut events: Vec<ConnectorEvent> = Vec::new();

                    for (idx, summary) in item.summary_text.into_iter().enumerate() {
                        let message_id = format!("reasoning-summary-{}-{}", item.id, idx);
                        let had_buffer = {
                            let mut buffers = delta_buffers.lock().await;
                            buffers.remove(&message_id).is_some()
                        };
                        if had_buffer {
                            events.push(ConnectorEvent::MessageUpdated {
                                message_id,
                                content: Some(summary),
                                tool_output: None,
                                is_error: None,
                                is_in_progress: Some(false),
                                duration_ms: None,
                            });
                        } else {
                            let message = orbitdock_protocol::Message {
                                id: message_id,
                                session_id: String::new(),
                                message_type: orbitdock_protocol::MessageType::Thinking,
                                content: summary,
                                tool_name: None,
                                tool_input: reasoning_trace_metadata_json(
                                    "summary",
                                    "modern",
                                    Some(item.id.as_str()),
                                    Some(idx as i64),
                                ),
                                tool_output: None,
                                is_error: false,
                                is_in_progress: false,
                                timestamp: iso_now(),
                                duration_ms: None,
                                images: vec![],
                            };
                            events.push(ConnectorEvent::MessageCreated(message));
                        }
                    }

                    for (idx, raw) in item.raw_content.into_iter().enumerate() {
                        let message_id = format!("reasoning-raw-{}-{}", item.id, idx);
                        let had_buffer = {
                            let mut buffers = delta_buffers.lock().await;
                            buffers.remove(&message_id).is_some()
                        };
                        if had_buffer {
                            events.push(ConnectorEvent::MessageUpdated {
                                message_id,
                                content: Some(raw),
                                tool_output: None,
                                is_error: None,
                                is_in_progress: Some(false),
                                duration_ms: None,
                            });
                        } else {
                            let message = orbitdock_protocol::Message {
                                id: message_id,
                                session_id: String::new(),
                                message_type: orbitdock_protocol::MessageType::Thinking,
                                content: raw,
                                tool_name: None,
                                tool_input: reasoning_trace_metadata_json(
                                    "raw",
                                    "modern",
                                    Some(item.id.as_str()),
                                    Some(idx as i64),
                                ),
                                tool_output: None,
                                is_error: false,
                                is_in_progress: false,
                                timestamp: iso_now(),
                                duration_ms: None,
                                images: vec![],
                            };
                            events.push(ConnectorEvent::MessageCreated(message));
                        }
                    }

                    events
                }
                codex_protocol::items::TurnItem::ContextCompaction(item) => {
                    vec![ConnectorEvent::MessageUpdated {
                        message_id: item.id,
                        content: Some("Context compacted".to_string()),
                        tool_output: Some("Context compacted".to_string()),
                        is_error: Some(false),
                        is_in_progress: Some(false),
                        duration_ms: None,
                    }]
                }
                _ => vec![],
            },

            EventMsg::RawResponseItem(e) => match e.item {
                // Core may emit raw items that do not have a higher-level mapping.
                // Surface only unknown payloads to avoid duplicating the whole timeline.
                codex_protocol::models::ResponseItem::Other => {
                    let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                    let message = orbitdock_protocol::Message {
                        id: format!("raw-response-item-{}-{}", event.id, seq),
                        session_id: String::new(),
                        message_type: orbitdock_protocol::MessageType::Assistant,
                        content: "Received unsupported raw response item.".to_string(),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_now(),
                        duration_ms: None,
                        images: vec![],
                    };
                    vec![ConnectorEvent::MessageCreated(message)]
                }
                _ => vec![],
            },

            EventMsg::ListSkillsResponse(e) => {
                let skills = e
                    .skills
                    .into_iter()
                    .map(|entry| orbitdock_protocol::SkillsListEntry {
                        cwd: entry.cwd.to_string_lossy().to_string(),
                        skills: entry
                            .skills
                            .into_iter()
                            .map(|s| orbitdock_protocol::SkillMetadata {
                                name: s.name,
                                description: s.description,
                                short_description: s.short_description,
                                path: s.path.to_string_lossy().to_string(),
                                scope: match s.scope {
                                    codex_protocol::protocol::SkillScope::User => {
                                        orbitdock_protocol::SkillScope::User
                                    }
                                    codex_protocol::protocol::SkillScope::Repo => {
                                        orbitdock_protocol::SkillScope::Repo
                                    }
                                    codex_protocol::protocol::SkillScope::System => {
                                        orbitdock_protocol::SkillScope::System
                                    }
                                    codex_protocol::protocol::SkillScope::Admin => {
                                        orbitdock_protocol::SkillScope::Admin
                                    }
                                },
                                enabled: s.enabled,
                            })
                            .collect(),
                        errors: entry
                            .errors
                            .into_iter()
                            .map(|e| orbitdock_protocol::SkillErrorInfo {
                                path: e.path.to_string_lossy().to_string(),
                                message: e.message,
                            })
                            .collect(),
                    })
                    .collect();

                vec![ConnectorEvent::SkillsList {
                    skills,
                    errors: Vec::new(),
                }]
            }

            EventMsg::ListRemoteSkillsResponse(e) => {
                let skills = e
                    .skills
                    .into_iter()
                    .map(|s| orbitdock_protocol::RemoteSkillSummary {
                        id: s.id,
                        name: s.name,
                        description: s.description,
                    })
                    .collect();
                vec![ConnectorEvent::RemoteSkillsList { skills }]
            }

            EventMsg::RemoteSkillDownloaded(e) => {
                vec![ConnectorEvent::RemoteSkillDownloaded {
                    id: e.id,
                    name: e.name,
                    path: e.path.to_string_lossy().to_string(),
                }]
            }

            EventMsg::ListCustomPromptsResponse(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let mut lines = vec![format!(
                    "Custom prompts available: {}",
                    e.custom_prompts.len()
                )];
                for prompt in e.custom_prompts.iter().take(20) {
                    let mut line = format!("/prompts:{}", prompt.name);
                    if let Some(description) = &prompt.description {
                        let trimmed = description.trim();
                        if !trimmed.is_empty() {
                            line.push_str(&format!(" - {}", trimmed));
                        }
                    }
                    lines.push(line);
                }
                if e.custom_prompts.len() > 20 {
                    lines.push(format!("... {} more", e.custom_prompts.len() - 20));
                }

                let message = orbitdock_protocol::Message {
                    id: format!("custom-prompts-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content: lines.join("\n"),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::GetHistoryEntryResponse(e) => {
                let seq = msg_counter.fetch_add(1, Ordering::SeqCst);
                let content = if let Some(entry) = e.entry {
                    format!(
                        "History entry offset {} (log {}):\n{}\n\nConversation: {}\nTimestamp: {}",
                        e.offset, e.log_id, entry.text, entry.conversation_id, entry.ts
                    )
                } else {
                    format!(
                        "No history entry available for offset {} (log {}).",
                        e.offset, e.log_id
                    )
                };
                let message = orbitdock_protocol::Message {
                    id: format!("history-entry-{}-{}", event.id, seq),
                    session_id: String::new(),
                    message_type: orbitdock_protocol::MessageType::Assistant,
                    content,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                };
                vec![ConnectorEvent::MessageCreated(message)]
            }

            EventMsg::ContextCompacted(_) => {
                vec![ConnectorEvent::ContextCompacted]
            }

            EventMsg::UndoStarted(e) => {
                vec![ConnectorEvent::UndoStarted { message: e.message }]
            }

            EventMsg::UndoCompleted(e) => {
                vec![ConnectorEvent::UndoCompleted {
                    success: e.success,
                    message: e.message,
                }]
            }

            EventMsg::ThreadRolledBack(e) => {
                vec![ConnectorEvent::ThreadRolledBack {
                    num_turns: e.num_turns,
                }]
            }

            EventMsg::SkillsUpdateAvailable => {
                vec![ConnectorEvent::SkillsUpdateAvailable]
            }

            EventMsg::McpListToolsResponse(e) => {
                // Map codex-core types to our protocol types via serialize→deserialize
                let tools: HashMap<String, orbitdock_protocol::McpTool> = e
                    .tools
                    .into_iter()
                    .map(|(k, t)| {
                        let v = serde_json::to_value(&t).unwrap_or_default();
                        let mapped: orbitdock_protocol::McpTool = serde_json::from_value(v)
                            .unwrap_or(orbitdock_protocol::McpTool {
                                name: t.name,
                                title: t.title,
                                description: t.description,
                                input_schema: t.input_schema,
                                output_schema: t.output_schema,
                                annotations: t.annotations,
                            });
                        (k, mapped)
                    })
                    .collect();

                let resources: HashMap<String, Vec<orbitdock_protocol::McpResource>> = e
                    .resources
                    .into_iter()
                    .map(|(k, rs)| {
                        let mapped: Vec<orbitdock_protocol::McpResource> = rs
                            .into_iter()
                            .filter_map(|r| {
                                let v = serde_json::to_value(&r).ok()?;
                                serde_json::from_value(v).ok()
                            })
                            .collect();
                        (k, mapped)
                    })
                    .collect();

                let resource_templates: HashMap<
                    String,
                    Vec<orbitdock_protocol::McpResourceTemplate>,
                > = e
                    .resource_templates
                    .into_iter()
                    .map(|(k, ts)| {
                        let mapped: Vec<orbitdock_protocol::McpResourceTemplate> = ts
                            .into_iter()
                            .filter_map(|t| {
                                let v = serde_json::to_value(&t).ok()?;
                                serde_json::from_value(v).ok()
                            })
                            .collect();
                        (k, mapped)
                    })
                    .collect();

                let auth_statuses: HashMap<String, orbitdock_protocol::McpAuthStatus> = e
                    .auth_statuses
                    .into_iter()
                    .map(|(k, s)| {
                        let mapped = match s {
                            codex_protocol::protocol::McpAuthStatus::Unsupported => {
                                orbitdock_protocol::McpAuthStatus::Unsupported
                            }
                            codex_protocol::protocol::McpAuthStatus::NotLoggedIn => {
                                orbitdock_protocol::McpAuthStatus::NotLoggedIn
                            }
                            codex_protocol::protocol::McpAuthStatus::BearerToken => {
                                orbitdock_protocol::McpAuthStatus::BearerToken
                            }
                            codex_protocol::protocol::McpAuthStatus::OAuth => {
                                orbitdock_protocol::McpAuthStatus::OAuth
                            }
                        };
                        (k, mapped)
                    })
                    .collect();

                vec![ConnectorEvent::McpToolsList {
                    tools,
                    resources,
                    resource_templates,
                    auth_statuses,
                }]
            }

            EventMsg::McpStartupUpdate(e) => {
                let status = match e.status {
                    codex_protocol::protocol::McpStartupStatus::Starting => {
                        orbitdock_protocol::McpStartupStatus::Starting
                    }
                    codex_protocol::protocol::McpStartupStatus::Ready => {
                        orbitdock_protocol::McpStartupStatus::Ready
                    }
                    codex_protocol::protocol::McpStartupStatus::Failed { error } => {
                        orbitdock_protocol::McpStartupStatus::Failed { error }
                    }
                    codex_protocol::protocol::McpStartupStatus::Cancelled => {
                        orbitdock_protocol::McpStartupStatus::Cancelled
                    }
                };
                vec![ConnectorEvent::McpStartupUpdate {
                    server: e.server,
                    status,
                }]
            }

            EventMsg::McpStartupComplete(e) => {
                let failed = e
                    .failed
                    .into_iter()
                    .map(|f| orbitdock_protocol::McpStartupFailure {
                        server: f.server,
                        error: f.error,
                    })
                    .collect();
                vec![ConnectorEvent::McpStartupComplete {
                    ready: e.ready,
                    failed,
                    cancelled: e.cancelled,
                }]
            }

            // Log but ignore other events
            other => {
                let name = format!("{:?}", other);
                let variant = name.split('(').next().unwrap_or(&name);
                debug!("Unhandled codex event: {}", variant);
                vec![]
            }
        }
    }

    async fn apply_delta_message(
        delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
        message_id: String,
        delta: String,
        message_type: orbitdock_protocol::MessageType,
        tool_input: Option<String>,
    ) -> Vec<ConnectorEvent> {
        let (is_new, content) = {
            let mut buffers = delta_buffers.lock().await;
            match buffers.get_mut(&message_id) {
                Some(existing) => {
                    existing.push_str(&delta);
                    (false, existing.clone())
                }
                None => {
                    buffers.insert(message_id.clone(), delta.clone());
                    (true, delta)
                }
            }
        };

        if is_new {
            vec![ConnectorEvent::MessageCreated(
                orbitdock_protocol::Message {
                    id: message_id,
                    session_id: String::new(),
                    message_type,
                    content,
                    tool_name: None,
                    tool_input,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: true,
                    timestamp: iso_now(),
                    duration_ms: None,
                    images: vec![],
                },
            )]
        } else {
            vec![ConnectorEvent::MessageUpdated {
                message_id,
                content: Some(content),
                tool_output: None,
                is_error: None,
                is_in_progress: Some(true),
                duration_ms: None,
            }]
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

    /// Get the codex home directory path
    pub fn codex_home(&self) -> &std::path::Path {
        &self.codex_home
    }

    /// Find the rollout file path for this connector's thread
    pub async fn rollout_path(&self) -> Option<String> {
        codex_core::find_thread_path_by_id_str(&self.codex_home, &self.thread_id)
            .await
            .ok()
            .flatten()
            .map(|p| p.to_string_lossy().to_string())
    }

    // MARK: - Actions

    /// Send a user message (starts a turn), with optional per-turn overrides, skills, images, and mentions
    pub async fn send_message(
        &self,
        content: &str,
        model: Option<&str>,
        effort: Option<&str>,
        skills: &[orbitdock_protocol::SkillInput],
        images: &[orbitdock_protocol::ImageInput],
        mentions: &[orbitdock_protocol::MentionInput],
    ) -> Result<(), ConnectorError> {
        // Submit per-turn overrides before the user message when present
        if model.is_some() || effort.is_some() {
            let effort_value = effort.map(|e| match e {
                "none" => codex_protocol::openai_models::ReasoningEffort::None,
                "minimal" => codex_protocol::openai_models::ReasoningEffort::Minimal,
                "low" => codex_protocol::openai_models::ReasoningEffort::Low,
                "medium" => codex_protocol::openai_models::ReasoningEffort::Medium,
                "high" => codex_protocol::openai_models::ReasoningEffort::High,
                "xhigh" => codex_protocol::openai_models::ReasoningEffort::XHigh,
                _ => codex_protocol::openai_models::ReasoningEffort::Medium,
            });
            let effective_model = if let Some(model) = model {
                Some(model.to_string())
            } else {
                let current = self.current_model.lock().await;
                current.clone()
            };
            let summary = Some(reasoning_summary_for_model(
                effective_model.as_deref(),
                preferred_reasoning_summary(),
            ));
            let override_op = Op::OverrideTurnContext {
                cwd: None,
                approval_policy: None,
                sandbox_policy: None,
                windows_sandbox_level: None,
                model: model.map(|m| m.to_string()),
                effort: effort_value.map(Some),
                summary,
                collaboration_mode: None,
                personality: None,
            };
            self.thread.submit(override_op).await.map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to override turn context: {}", e))
            })?;
            info!(
                "Submitted per-turn overrides: model={:?}, effort={:?}, summary={:?}",
                model, effort, summary
            );
        }

        let mut items = vec![UserInput::Text {
            text: content.to_string(),
            text_elements: Vec::new(),
        }];

        for skill in skills {
            items.push(UserInput::Skill {
                name: skill.name.clone(),
                path: PathBuf::from(&skill.path),
            });
        }

        for image in images {
            match image.input_type.as_str() {
                "url" => items.push(UserInput::Image {
                    image_url: image.value.clone(),
                }),
                "path" => items.push(UserInput::LocalImage {
                    path: PathBuf::from(&image.value),
                }),
                other => {
                    warn!("Unknown image input_type: {}, treating as url", other);
                    items.push(UserInput::Image {
                        image_url: image.value.clone(),
                    });
                }
            }
        }

        for mention in mentions {
            items.push(UserInput::Mention {
                name: mention.name.clone(),
                path: mention.path.clone(),
            });
        }

        let op = Op::UserInput {
            items,
            final_output_json_schema: None,
        };

        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to send message: {}", e)))?;

        info!("Sent user message");
        Ok(())
    }

    /// Steer the active turn with additional user input.
    /// If no turn is active (race condition), falls back to starting a new turn.
    pub async fn steer_turn(
        &self,
        content: &str,
        images: &[orbitdock_protocol::ImageInput],
        mentions: &[orbitdock_protocol::MentionInput],
    ) -> Result<SteerOutcome, ConnectorError> {
        let mut items: Vec<UserInput> = Vec::new();

        if !content.is_empty() {
            items.push(UserInput::Text {
                text: content.to_string(),
                text_elements: Vec::new(),
            });
        }

        for image in images {
            match image.input_type.as_str() {
                "url" => items.push(UserInput::Image {
                    image_url: image.value.clone(),
                }),
                "path" => items.push(UserInput::LocalImage {
                    path: PathBuf::from(&image.value),
                }),
                other => {
                    warn!("Unknown image input_type: {}, treating as url", other);
                    items.push(UserInput::Image {
                        image_url: image.value.clone(),
                    });
                }
            }
        }

        for mention in mentions {
            items.push(UserInput::Mention {
                name: mention.name.clone(),
                path: mention.path.clone(),
            });
        }

        match self.thread.steer_input(items, None).await {
            Ok(turn_id) => {
                info!("Steered active turn: {}", turn_id);
                Ok(SteerOutcome::Accepted)
            }
            Err(SteerInputError::NoActiveTurn(items)) => {
                info!("No active turn for steer, falling back to send_message");
                self.thread
                    .submit(Op::UserInput {
                        items,
                        final_output_json_schema: None,
                    })
                    .await
                    .map_err(|e| {
                        ConnectorError::ProviderError(format!(
                            "Failed to send fallback message: {}",
                            e
                        ))
                    })?;
                Ok(SteerOutcome::FellBackToNewTurn)
            }
            Err(SteerInputError::EmptyInput) => {
                Err(ConnectorError::ProviderError("Empty steer input".into()))
            }
            Err(SteerInputError::ExpectedTurnMismatch { expected, actual }) => {
                Err(ConnectorError::ProviderError(format!(
                    "Turn mismatch: expected {expected}, got {actual}"
                )))
            }
        }
    }

    /// List skills for the given working directories
    pub async fn list_skills(
        &self,
        cwds: Vec<String>,
        force_reload: bool,
    ) -> Result<(), ConnectorError> {
        let cwds: Vec<PathBuf> = cwds.into_iter().map(PathBuf::from).collect();
        let op = Op::ListSkills { cwds, force_reload };
        self.thread
            .submit(op)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to list skills: {}", e)))?;
        info!("Requested skills list");
        Ok(())
    }

    /// List remote skills available via ChatGPT sharing
    pub async fn list_remote_skills(&self) -> Result<(), ConnectorError> {
        use codex_protocol::protocol::{RemoteSkillHazelnutScope, RemoteSkillProductSurface};
        let op = Op::ListRemoteSkills {
            hazelnut_scope: RemoteSkillHazelnutScope::AllShared,
            product_surface: RemoteSkillProductSurface::Codex,
            enabled: None,
        };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to list remote skills: {}", e))
        })?;
        info!("Requested remote skills list");
        Ok(())
    }

    /// Download a remote skill by hazelnut ID
    pub async fn download_remote_skill(&self, hazelnut_id: &str) -> Result<(), ConnectorError> {
        let op = Op::DownloadRemoteSkill {
            hazelnut_id: hazelnut_id.to_string(),
        };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to download skill: {}", e))
        })?;
        info!("Requested remote skill download: {}", hazelnut_id);
        Ok(())
    }

    /// List MCP tools across all configured servers
    pub async fn list_mcp_tools(&self) -> Result<(), ConnectorError> {
        let op = Op::ListMcpTools;
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to list MCP tools: {}", e))
        })?;
        info!("Requested MCP tools list");
        Ok(())
    }

    /// Refresh MCP servers (reinitialize and refresh cached tool lists)
    pub async fn refresh_mcp_servers(&self) -> Result<(), ConnectorError> {
        let config = McpServerRefreshConfig {
            mcp_servers: serde_json::Value::Object(Default::default()),
            mcp_oauth_credentials_store_mode: serde_json::Value::Null,
        };
        let op = Op::RefreshMcpServers { config };
        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to refresh MCP servers: {}", e))
        })?;
        info!("Requested MCP servers refresh");
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
            turn_id: None,
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
        answers: HashMap<String, Vec<String>>,
    ) -> Result<(), ConnectorError> {
        let response = RequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(|(k, v)| (k, RequestUserInputAnswer { answers: v }))
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
        permission_mode: Option<&str>,
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
            "read-only" => SandboxPolicy::ReadOnly {
                access: Default::default(),
            },
            "workspace-write" => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                read_only_access: Default::default(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
            _ => SandboxPolicy::WorkspaceWrite {
                writable_roots: Vec::new(),
                read_only_access: Default::default(),
                network_access: false,
                exclude_tmpdir_env_var: false,
                exclude_slash_tmp: false,
            },
        });

        let model = {
            let current = self.current_model.lock().await;
            current.clone().unwrap_or_else(|| "gpt-5-codex".to_string())
        };
        let effort = {
            let current = self.current_reasoning_effort.lock().await;
            *current
        };
        let collaboration_mode =
            collaboration_mode_from_permission_mode(permission_mode, model, effort);

        let op = Op::OverrideTurnContext {
            cwd: None,
            approval_policy: policy,
            sandbox_policy: sandbox,
            windows_sandbox_level: None,
            model: None,
            effort: None,
            summary: None,
            collaboration_mode,
            personality: None,
        };

        self.thread.submit(op).await.map_err(|e| {
            ConnectorError::ProviderError(format!("Failed to update config: {}", e))
        })?;

        info!(
            "Updated session config: approval={:?}, sandbox={:?}, permission_mode={:?}",
            approval_policy, sandbox_mode, permission_mode
        );
        Ok(())
    }

    /// Compact (summarize) the conversation context
    pub async fn compact(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Compact)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to compact: {}", e)))?;

        info!("Sent compact");
        Ok(())
    }

    /// Undo the last turn (reverts filesystem changes and removes from context)
    pub async fn undo(&self) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::Undo)
            .await
            .map_err(|e| ConnectorError::ProviderError(format!("Failed to undo: {}", e)))?;

        info!("Sent undo");
        Ok(())
    }

    /// Roll back N turns from context (does NOT revert filesystem changes)
    pub async fn thread_rollback(&self, num_turns: u32) -> Result<(), ConnectorError> {
        self.thread
            .submit(Op::ThreadRollback { num_turns })
            .await
            .map_err(|e| {
                ConnectorError::ProviderError(format!("Failed to thread rollback: {}", e))
            })?;

        info!("Sent thread rollback: {} turns", num_turns);
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
pub async fn discover_models() -> Result<Vec<orbitdock_protocol::CodexModelOption>, ConnectorError>
{
    let codex_home = find_codex_home()
        .map_err(|e| ConnectorError::ProviderError(format!("Failed to find codex home: {}", e)))?;
    let auth_manager = Arc::new(AuthManager::new(
        codex_home.clone(),
        true,
        AuthCredentialsStoreMode::Auto,
    ));
    let thread_manager = Arc::new(ThreadManager::new(
        codex_home,
        auth_manager,
        SessionSource::Mcp,
        None,
        CollaborationModesConfig::default(),
    ));

    let base_config = Config::load_with_cli_overrides(Vec::new())
        .await
        .or_else(|err| {
            warn!(
                "Failed to load config for model discovery: {}. Falling back to defaults.",
                err
            );
            Config::load_default_with_cli_overrides(Vec::new())
        })
        .map_err(|e| {
            ConnectorError::ProviderError(format!(
                "Failed to load config for model discovery: {}",
                e
            ))
        })?;

    let mut models: Vec<orbitdock_protocol::CodexModelOption> = Vec::new();
    for preset in thread_manager
        .list_models(RefreshStrategy::OnlineIfUncached)
        .await
        .into_iter()
        // codex-core already applies auth-aware filtering in list_models:
        // ChatGPT mode can include models that are not API-key compatible.
        .filter(|preset| preset.show_in_picker)
    {
        let mut model_config = base_config.clone();
        model_config.model = Some(preset.model.clone());
        let supports_reasoning_summaries =
            model_supports_reasoning_summaries(thread_manager.as_ref(), &model_config).await;
        let supported_reasoning_efforts = preset
            .supported_reasoning_efforts
            .into_iter()
            .map(|e| e.effort.to_string())
            .collect();

        models.push(orbitdock_protocol::CodexModelOption {
            id: preset.id,
            model: preset.model,
            display_name: preset.display_name,
            description: preset.description,
            is_default: preset.is_default,
            supported_reasoning_efforts,
            supports_reasoning_summaries,
        });
    }

    Ok(models)
}

fn dynamic_tool_output_to_text(
    content_items: &[codex_protocol::dynamic_tools::DynamicToolCallOutputContentItem],
    fallback_error: Option<String>,
) -> Option<String> {
    let mut lines: Vec<String> = Vec::new();

    for item in content_items {
        match item {
            codex_protocol::dynamic_tools::DynamicToolCallOutputContentItem::InputText { text } => {
                if !text.is_empty() {
                    lines.push(text.clone());
                }
            }
            codex_protocol::dynamic_tools::DynamicToolCallOutputContentItem::InputImage {
                image_url,
            } => {
                lines.push(format!("[image] {}", image_url));
            }
        }
    }

    if lines.is_empty() {
        fallback_error
    } else {
        Some(lines.join("\n"))
    }
}

fn parse_bool_env(name: &str) -> Option<bool> {
    let raw = std::env::var(name).ok()?;
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        other => {
            warn!(
                "Ignoring invalid boolean env {}={} (expected true/false, 1/0, yes/no, on/off)",
                name, other
            );
            None
        }
    }
}

fn parse_reasoning_summary_env(name: &str) -> Option<String> {
    let raw = std::env::var(name).ok()?;
    let value = raw.trim().to_ascii_lowercase();
    match value.as_str() {
        "auto" | "concise" | "detailed" | REASONING_SUMMARY_NONE => Some(value),
        other => {
            warn!(
                "Ignoring invalid reasoning summary env {}={} (expected auto|concise|detailed|none)",
                name, other
            );
            None
        }
    }
}

fn parse_reasoning_summary(value: &str) -> Option<ReasoningSummary> {
    match value.trim().to_ascii_lowercase().as_str() {
        "auto" => Some(ReasoningSummary::Auto),
        "concise" => Some(ReasoningSummary::Concise),
        "detailed" => Some(ReasoningSummary::Detailed),
        REASONING_SUMMARY_NONE => Some(ReasoningSummary::None),
        _ => None,
    }
}

fn preferred_reasoning_summary() -> ReasoningSummary {
    parse_reasoning_summary_env(ENV_CODEX_REASONING_SUMMARY)
        .as_deref()
        .and_then(parse_reasoning_summary)
        .unwrap_or(ReasoningSummary::Detailed)
}

fn model_rejects_reasoning_summary(model: Option<&str>) -> bool {
    model
        .map(|value| value.trim().to_ascii_lowercase().contains("codex-spark"))
        .unwrap_or(false)
}

fn reasoning_summary_for_model(
    model: Option<&str>,
    preferred: ReasoningSummary,
) -> ReasoningSummary {
    if model_rejects_reasoning_summary(model) {
        ReasoningSummary::None
    } else {
        preferred
    }
}

async fn model_supports_reasoning_summaries(
    thread_manager: &ThreadManager,
    config: &Config,
) -> bool {
    let Some(model) = config.model.as_deref() else {
        return true;
    };

    thread_manager
        .get_models_manager()
        .get_model_info(model, config)
        .await
        .supports_reasoning_summaries
}

fn should_disable_reasoning_summary(
    model: Option<&str>,
    supports_reasoning_summaries: bool,
) -> bool {
    !supports_reasoning_summaries || model_rejects_reasoning_summary(model)
}

fn collaboration_mode_from_permission_mode(
    permission_mode: Option<&str>,
    model: String,
    effort: Option<ReasoningEffort>,
) -> Option<CollaborationMode> {
    let mode = permission_mode
        .map(str::to_ascii_lowercase)
        .as_deref()
        .and_then(|m| match m {
            "plan" => Some(ModeKind::Plan),
            "default" => Some(ModeKind::Default),
            _ => None,
        })?;

    Some(CollaborationMode {
        mode,
        settings: Settings {
            model,
            reasoning_effort: effort,
            developer_instructions: None,
        },
    })
}

fn tool_input_with_arguments(
    metadata: serde_json::Value,
    arguments: Option<&serde_json::Value>,
) -> Option<String> {
    let mut payload = match metadata {
        serde_json::Value::Object(object) => object,
        _ => serde_json::Map::new(),
    };

    if let Some(args_value) = arguments {
        payload.insert("arguments".to_string(), args_value.clone());

        if let serde_json::Value::Object(args_object) = args_value {
            for (key, value) in args_object {
                if !payload.contains_key(key) {
                    payload.insert(key.clone(), value.clone());
                }
            }
        }
    }

    serde_json::to_string(&serde_json::Value::Object(payload)).ok()
}

fn collab_agent_label(
    thread_id: &str,
    agent_nickname: Option<&str>,
    agent_role: Option<&str>,
) -> String {
    let mut parts = vec![thread_id.to_string()];
    if let Some(nickname) = agent_nickname {
        let trimmed = nickname.trim();
        if !trimmed.is_empty() {
            parts.push(format!("nickname={trimmed}"));
        }
    }
    if let Some(role) = agent_role {
        let trimmed = role.trim();
        if !trimmed.is_empty() {
            parts.push(format!("role={trimmed}"));
        }
    }
    parts.join(" · ")
}

fn reasoning_trace_metadata_json(
    reasoning_kind: &'static str,
    stream: &'static str,
    item_id: Option<&str>,
    part_index: Option<i64>,
) -> Option<String> {
    let mut metadata = json!({
        "kind": "reasoning_trace",
        "reasoning_kind": reasoning_kind,
        "stream": stream,
    });

    if let Some(object) = metadata.as_object_mut() {
        if let Some(id) = item_id {
            object.insert("item_id".to_string(), json!(id));
        }
        if let Some(index) = part_index {
            object.insert("part_index".to_string(), json!(index));
        }
    }

    serde_json::to_string(&metadata).ok()
}

fn truncate_for_display(value: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    if trimmed.chars().count() <= max_chars {
        trimmed.to_string()
    } else {
        format!("{}...", trimmed.chars().take(max_chars).collect::<String>())
    }
}

fn review_request_summary(request: &codex_protocol::protocol::ReviewRequest) -> String {
    if let Some(hint) = &request.user_facing_hint {
        let trimmed = hint.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    match &request.target {
        codex_protocol::protocol::ReviewTarget::UncommittedChanges => {
            "Review uncommitted changes".to_string()
        }
        codex_protocol::protocol::ReviewTarget::BaseBranch { branch } => {
            format!("Review changes against branch `{branch}`")
        }
        codex_protocol::protocol::ReviewTarget::Commit { sha, title } => {
            if let Some(title) = title {
                let trimmed_title = title.trim();
                if !trimmed_title.is_empty() {
                    return format!("Review commit `{sha}` - {trimmed_title}");
                }
            }
            format!("Review commit `{sha}`")
        }
        codex_protocol::protocol::ReviewTarget::Custom { instructions } => {
            if instructions.trim().is_empty() {
                "Run custom review".to_string()
            } else {
                format!(
                    "Custom review\n\n{}",
                    truncate_for_display(instructions, 600)
                )
            }
        }
    }
}

fn render_review_output(output: &codex_protocol::protocol::ReviewOutputEvent) -> String {
    let mut lines: Vec<String> = Vec::new();

    if !output.overall_correctness.trim().is_empty() {
        lines.push(format!(
            "Overall correctness: {}",
            output.overall_correctness.trim()
        ));
    }

    if !output.overall_explanation.trim().is_empty() {
        lines.push(String::new());
        lines.push(output.overall_explanation.trim().to_string());
    }

    lines.push(String::new());
    lines.push(format!(
        "Confidence: {:.2}",
        output.overall_confidence_score
    ));

    if !output.findings.is_empty() {
        lines.push(String::new());
        lines.push(format!("Findings ({})", output.findings.len()));
        for finding in &output.findings {
            let path = finding.code_location.absolute_file_path.display();
            let range = &finding.code_location.line_range;
            lines.push(format!(
                "- [P{}] {} ({path}:{}-{}, confidence {:.2})",
                finding.priority,
                finding.title.trim(),
                range.start,
                range.end,
                finding.confidence_score
            ));
            if !finding.body.trim().is_empty() {
                lines.push(format!("  {}", finding.body.trim()));
            }
        }
    }

    lines.join("\n")
}

fn agent_status_failed(status: &codex_protocol::protocol::AgentStatus) -> bool {
    matches!(
        status,
        codex_protocol::protocol::AgentStatus::Errored(_)
            | codex_protocol::protocol::AgentStatus::NotFound
    )
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

#[cfg(test)]
mod tests {
    use super::{
        collaboration_mode_from_permission_mode, model_rejects_reasoning_summary,
        parse_reasoning_summary, reasoning_summary_for_model, should_disable_reasoning_summary,
    };
    use codex_protocol::config_types::{ModeKind, ReasoningSummary};
    use codex_protocol::openai_models::ReasoningEffort;

    #[test]
    fn collaboration_mode_maps_plan() {
        let result = collaboration_mode_from_permission_mode(
            Some("plan"),
            "openai/gpt-5.3-codex".to_string(),
            Some(ReasoningEffort::High),
        )
        .expect("expected mode");
        assert_eq!(result.mode, ModeKind::Plan);
        assert_eq!(result.settings.model, "openai/gpt-5.3-codex");
        assert_eq!(
            result.settings.reasoning_effort,
            Some(ReasoningEffort::High)
        );
    }

    #[test]
    fn collaboration_mode_maps_default_case_insensitive() {
        let result = collaboration_mode_from_permission_mode(
            Some("Default"),
            "openai/gpt-5.3-codex".to_string(),
            None,
        )
        .expect("expected mode");
        assert_eq!(result.mode, ModeKind::Default);
    }

    #[test]
    fn collaboration_mode_ignores_unknown_modes() {
        let result =
            collaboration_mode_from_permission_mode(Some("acceptEdits"), "model".to_string(), None);
        assert!(result.is_none());
    }

    #[test]
    fn model_rejects_reasoning_summary_for_spark() {
        assert!(model_rejects_reasoning_summary(Some("gpt-5.3-codex-spark")));
    }

    #[test]
    fn model_rejects_reasoning_summary_for_prefixed_spark() {
        assert!(model_rejects_reasoning_summary(Some(
            "openai/gpt-5.3-codex-spark"
        )));
    }

    #[test]
    fn model_allows_reasoning_summary_for_non_spark() {
        assert!(!model_rejects_reasoning_summary(Some("gpt-5.3-codex")));
        assert!(!model_rejects_reasoning_summary(None));
    }

    #[test]
    fn should_disable_reasoning_summary_when_model_does_not_support_it() {
        assert!(should_disable_reasoning_summary(
            Some("gpt-5.3-codex"),
            false
        ));
    }

    #[test]
    fn should_disable_reasoning_summary_for_known_spark_mismatch() {
        assert!(should_disable_reasoning_summary(
            Some("gpt-5.3-codex-spark"),
            true
        ));
    }

    #[test]
    fn should_keep_reasoning_summary_for_supported_non_spark_models() {
        assert!(!should_disable_reasoning_summary(
            Some("gpt-5.3-codex"),
            true
        ));
    }

    #[test]
    fn parse_reasoning_summary_maps_expected_values() {
        assert_eq!(
            parse_reasoning_summary("auto"),
            Some(ReasoningSummary::Auto)
        );
        assert_eq!(
            parse_reasoning_summary("concise"),
            Some(ReasoningSummary::Concise)
        );
        assert_eq!(
            parse_reasoning_summary("detailed"),
            Some(ReasoningSummary::Detailed)
        );
        assert_eq!(
            parse_reasoning_summary("none"),
            Some(ReasoningSummary::None)
        );
        assert_eq!(parse_reasoning_summary("invalid"), None);
    }

    #[test]
    fn reasoning_summary_for_model_forces_none_for_spark() {
        assert_eq!(
            reasoning_summary_for_model(Some("gpt-5.3-codex-spark"), ReasoningSummary::Detailed),
            ReasoningSummary::None
        );
    }

    #[test]
    fn reasoning_summary_for_model_keeps_preferred_for_non_spark() {
        assert_eq!(
            reasoning_summary_for_model(Some("gpt-5.3-codex"), ReasoningSummary::Concise),
            ReasoningSummary::Concise
        );
    }
}
