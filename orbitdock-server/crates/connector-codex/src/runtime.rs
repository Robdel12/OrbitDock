use super::workers::iso_now;
use super::CodexConnector;
use codex_core::{CodexThread, ThreadManager};
use codex_protocol::openai_models::ReasoningEffort;
use orbitdock_connector_core::{ConnectorError, ConnectorEvent};
use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{debug, error, info};

/// Tracks an in-progress assistant message being streamed via deltas
pub(super) struct StreamingMessage {
    pub(super) message_id: String,
    pub(super) content: String,
    pub(super) last_broadcast: std::time::Instant,
    /// True if started by AgentMessageContentDelta (newer path).
    /// When set, AgentMessageDelta events are skipped to avoid doubling.
    pub(super) from_content_delta: bool,
}

/// Determines which reasoning event stream is active for the current turn.
///
/// codex-protocol can emit both modern and legacy reasoning events for compatibility.
/// We process only one stream per turn to avoid duplicated timeline rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum ReasoningStreamMode {
    #[default]
    Unknown,
    Modern,
    Legacy,
}

#[derive(Debug, Default)]
pub(super) struct ReasoningEventTracker {
    pub(super) summary_mode: ReasoningStreamMode,
    pub(super) raw_mode: ReasoningStreamMode,
}

impl ReasoningEventTracker {
    pub(super) fn reset_for_turn(&mut self) {
        self.summary_mode = ReasoningStreamMode::Unknown;
        self.raw_mode = ReasoningStreamMode::Unknown;
    }

    pub(super) fn should_process_modern_summary(&mut self) -> bool {
        match self.summary_mode {
            ReasoningStreamMode::Unknown => {
                self.summary_mode = ReasoningStreamMode::Modern;
                true
            }
            ReasoningStreamMode::Modern => true,
            ReasoningStreamMode::Legacy => false,
        }
    }

    pub(super) fn should_process_legacy_summary(&mut self) -> bool {
        match self.summary_mode {
            ReasoningStreamMode::Unknown => {
                self.summary_mode = ReasoningStreamMode::Legacy;
                true
            }
            ReasoningStreamMode::Legacy => true,
            ReasoningStreamMode::Modern => false,
        }
    }

    pub(super) fn mark_modern_summary_seen(&mut self) {
        if self.summary_mode == ReasoningStreamMode::Unknown {
            self.summary_mode = ReasoningStreamMode::Modern;
        }
    }

    pub(super) fn should_process_modern_raw(&mut self) -> bool {
        match self.raw_mode {
            ReasoningStreamMode::Unknown => {
                self.raw_mode = ReasoningStreamMode::Modern;
                true
            }
            ReasoningStreamMode::Modern => true,
            ReasoningStreamMode::Legacy => false,
        }
    }

    pub(super) fn should_process_legacy_raw(&mut self) -> bool {
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
pub(super) struct EnvironmentTracker {
    pub(super) cwd: Option<String>,
    pub(super) branch: Option<String>,
    pub(super) sha: Option<String>,
}

/// Minimum interval between streaming content broadcasts (ms)
pub(super) const STREAM_THROTTLE_MS: u128 = 50;

impl CodexConnector {
    /// Create a connector from an existing NewThread (shared by new() and fork_thread())
    pub(super) fn from_thread(
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
        let patch_contexts = Arc::new(tokio::sync::Mutex::new(
            HashMap::<String, serde_json::Value>::new(),
        ));

        let tx = event_tx.clone();
        let thread_for_loop = thread.clone();
        let buffers = output_buffers.clone();
        let deltas = delta_buffers.clone();
        let streaming = streaming_message.clone();
        let counter = msg_counter.clone();
        let tracker = env_tracker.clone();
        let reasoning = reasoning_tracker.clone();
        let model = current_model.clone();
        let effort = current_reasoning_effort.clone();
        let patches = patch_contexts.clone();
        tokio::spawn(async move {
            Self::event_loop(
                thread_for_loop,
                tx,
                buffers,
                deltas,
                streaming,
                counter,
                tracker,
                reasoning,
                model,
                effort,
                patches,
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
        patch_contexts: Arc<tokio::sync::Mutex<HashMap<String, serde_json::Value>>>,
    ) {
        loop {
            match thread.next_event().await {
                Ok(event) => {
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
                        &patch_contexts,
                    ))
                    .await;
                    for event in events {
                        if tx.send(event).await.is_err() {
                            debug!("Event channel closed, stopping event loop");
                            return;
                        }
                    }
                }
                Err(error) => {
                    error!("Error reading codex event: {}", error);
                    let _ = tx
                        .send(ConnectorEvent::Error(format!(
                            "Event read error: {}",
                            error
                        )))
                        .await;
                    return;
                }
            }
        }
    }
}

/// Helper to build a ConversationRowEntry with empty session_id and zero sequence.
pub(crate) fn row_entry(row: ConversationRow) -> ConversationRowEntry {
    ConversationRowEntry {
        session_id: String::new(),
        sequence: 0,
        turn_id: None,
        row,
    }
}

/// Build a thinking row and wrap it for delta streaming.
pub(crate) fn thinking_row_entry(id: String, content: String) -> ConversationRowEntry {
    row_entry(ConversationRow::Thinking(MessageRowContent {
        id,
        content,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: true,
        images: vec![],
        memory_citation: None,
    }))
}

/// Build a finalized thinking row (not streaming).
pub(crate) fn finalized_thinking_row_entry(id: String, content: String) -> ConversationRowEntry {
    row_entry(ConversationRow::Thinking(MessageRowContent {
        id,
        content,
        turn_id: None,
        timestamp: Some(iso_now()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
    }))
}

pub(crate) async fn apply_delta_thinking(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    message_id: String,
    delta: String,
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

    let entry = thinking_row_entry(message_id.clone(), content);

    if is_new {
        vec![ConnectorEvent::ConversationRowCreated(entry)]
    } else {
        vec![ConnectorEvent::ConversationRowUpdated {
            row_id: message_id,
            entry,
        }]
    }
}
