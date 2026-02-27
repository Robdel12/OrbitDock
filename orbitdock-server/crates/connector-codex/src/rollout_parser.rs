//! Rollout file parser for passive Codex session watching.
//!
//! Reads `.codex/sessions/*.jsonl` files incrementally and emits typed
//! [`RolloutEvent`]s. All server orchestration (persistence, session handles,
//! broadcasts) lives in the server crate's `rollout_watcher` — this module is
//! pure parsing + file state tracking.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::SystemTime;

use anyhow::Context;
use codex_protocol::models::{ContentItem, ResponseItem};
use codex_protocol::protocol::{
    EventMsg, RolloutItem, RolloutLine, SessionMetaLine, TurnContextItem,
};

// Re-export SessionSource so the server crate can use it without depending on codex-protocol
pub use codex_protocol::protocol::SessionSource;
use notify::EventKind;
use orbitdock_protocol::{ImageInput, MessageType, TokenUsage, WorkStatus};
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::{debug, warn};

// ── Constants ────────────────────────────────────────────────────────────────

pub const DEBOUNCE_MS: u64 = 150;
pub const SESSION_TIMEOUT_SECS: u64 = 120;
pub const STARTUP_SEED_RECENT_SECS: u64 = 15 * 60;
pub const CATCHUP_SWEEP_SECS: u64 = 3;

// ── RolloutEvent ─────────────────────────────────────────────────────────────

/// Events emitted by the parser for the server driver to act on.
#[derive(Debug, Clone)]
pub enum RolloutEvent {
    SessionMeta {
        session_id: String,
        cwd: String,
        model_provider: Option<String>,
        originator: String,
        source: SessionSource,
        started_at: String,
        transcript_path: String,
        branch: Option<String>,
    },
    TurnContext {
        session_id: String,
        project_path: Option<String>,
        model: Option<String>,
        effort: Option<String>,
    },
    WorkStateChange {
        session_id: String,
        work_status: WorkStatus,
        attention_reason: Option<String>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
    },
    ClearPending {
        session_id: String,
    },
    UserMessage {
        session_id: String,
        message: Option<String>,
    },
    AppendChatMessage {
        session_id: String,
        message_type: MessageType,
        content: String,
        images: Vec<ImageInput>,
    },
    ShellCommandBegin {
        session_id: String,
        call_id: String,
        command: String,
    },
    ShellCommandEnd {
        session_id: String,
        call_id: String,
        output: Option<String>,
        is_error: Option<bool>,
        duration_ms: Option<u64>,
    },
    ToolCompleted {
        session_id: String,
        tool: Option<String>,
    },
    TokenCount {
        session_id: String,
        total_tokens: Option<i64>,
        token_usage: Option<TokenUsage>,
    },
    ThreadNameUpdated {
        session_id: String,
        name: String,
    },
}

// ── File state types ─────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct FileState {
    pub offset: u64,
    pub tail: String,
    pub session_id: Option<String>,
    pub project_path: Option<String>,
    pub model_provider: Option<String>,
    pub ignore_existing: bool,
    pub pending_tool_calls: HashMap<String, String>,
    pub next_message_seq: u64,
    pub saw_user_event: bool,
    pub saw_agent_event: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct PersistedState {
    pub version: i32,
    pub files: HashMap<String, PersistedFileState>,
}

impl Default for PersistedState {
    fn default() -> Self {
        Self {
            version: 1,
            files: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PersistedFileState {
    pub offset: u64,
    pub session_id: Option<String>,
    pub project_path: Option<String>,
    pub model_provider: Option<String>,
    pub ignore_existing: Option<bool>,
}

// ── RolloutFileProcessor ─────────────────────────────────────────────────────

/// Pure parser + file state tracker. No server deps (PersistCommand, SessionHandle, etc).
pub struct RolloutFileProcessor {
    pub watcher_started_at: SystemTime,
    pub file_states: HashMap<String, FileState>,
    pub persisted_state: PersistedState,
    state_path: PathBuf,
}

impl RolloutFileProcessor {
    pub fn new(state_path: PathBuf, persisted_state: PersistedState) -> Self {
        Self {
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::new(),
            persisted_state,
            state_path,
        }
    }

    // ── File processing ──────────────────────────────────────────────────

    /// Process a single rollout file, returning events for all new lines.
    pub async fn process_file(&mut self, path: &Path) -> anyhow::Result<Vec<RolloutEvent>> {
        if !path.exists() {
            return Ok(vec![]);
        }

        let path_string = path.to_string_lossy().to_string();

        // Guard stale path→session bindings
        if let Some(hinted_session_id) = rollout_session_id_hint(path) {
            let mapped_session_id = self
                .file_states
                .get(&path_string)
                .and_then(|state| state.session_id.clone());
            if let Some(ref mapped_session_id) = mapped_session_id {
                if *mapped_session_id != hinted_session_id {
                    self.reset_session_binding(&path_string);
                }
            }
        }

        let metadata = fs::metadata(path)?;
        let size = metadata.len();
        let created_at = metadata.created().ok();
        self.ensure_file_state(&path_string, size, created_at);

        // Handle ignore_existing flag
        let ignore_existing = self
            .file_states
            .get(&path_string)
            .map(|s| s.ignore_existing)
            .unwrap_or(false);
        if ignore_existing {
            let offset = self
                .file_states
                .get(&path_string)
                .map(|s| s.offset)
                .unwrap_or(0);
            if size > offset {
                if let Some(state) = self.file_states.get_mut(&path_string) {
                    state.ignore_existing = false;
                }
                // Need session meta before processing new content
                let mut events = self.ensure_session_meta(&path_string).await?;
                let more = self.read_and_parse_lines(&path_string, path, size).await?;
                events.extend(more);
                self.persist_state(&path_string);
                return Ok(events);
            } else {
                if let Some(state) = self.file_states.get_mut(&path_string) {
                    state.offset = size;
                }
                self.persist_state(&path_string);
                return Ok(vec![]);
            }
        }

        // Handle file truncation
        if let Some(state) = self.file_states.get_mut(&path_string) {
            if size < state.offset {
                state.offset = 0;
                state.tail.clear();
            }
        }

        let offset = self
            .file_states
            .get(&path_string)
            .map(|s| s.offset)
            .unwrap_or(0);
        if size == offset {
            self.persist_state(&path_string);
            return Ok(vec![]);
        }

        let events = self.read_and_parse_lines(&path_string, path, size).await?;
        self.persist_state(&path_string);
        Ok(events)
    }

    /// Read new bytes from offset→size, split into lines, parse each.
    async fn read_and_parse_lines(
        &mut self,
        path_string: &str,
        path: &Path,
        size: u64,
    ) -> anyhow::Result<Vec<RolloutEvent>> {
        let offset = self
            .file_states
            .get(path_string)
            .map(|s| s.offset)
            .unwrap_or(0);

        let chunk = read_file_chunk(path, offset)?;
        if let Some(state) = self.file_states.get_mut(path_string) {
            state.offset = size;
        }

        if chunk.is_empty() {
            return Ok(vec![]);
        }

        let chunk = String::from_utf8_lossy(&chunk).to_string();
        if chunk.is_empty() {
            return Ok(vec![]);
        }

        let old_tail = self
            .file_states
            .get(path_string)
            .map(|s| s.tail.clone())
            .unwrap_or_default();
        let combined = format!("{old_tail}{chunk}");
        let mut parts: Vec<&str> = combined.split('\n').collect();
        let next_tail = parts.pop().unwrap_or_default().to_string();

        if let Some(state) = self.file_states.get_mut(path_string) {
            state.tail = next_tail;
        }

        let mut events = Vec::new();
        for part in parts {
            let line = part.trim();
            if line.is_empty() {
                continue;
            }
            events.extend(self.parse_line(line, path_string).await);
        }

        if !events.is_empty() {
            debug!(
                component = "rollout_watcher",
                event = "rollout_watcher.lines_processed",
                path = %path_string,
                "Processed rollout lines"
            );
        }

        Ok(events)
    }

    /// Read the first line of a file and parse session_meta if present.
    pub async fn ensure_session_meta(&mut self, path: &str) -> anyhow::Result<Vec<RolloutEvent>> {
        let Some(line) = read_first_line(Path::new(path))? else {
            return Ok(vec![]);
        };
        // Try typed deserialization of the full RolloutLine
        let Ok(rollout_line) = serde_json::from_str::<RolloutLine>(&line) else {
            return Ok(vec![]);
        };
        if let RolloutItem::SessionMeta(meta) = rollout_line.item {
            return Ok(self.parse_session_meta(meta, path).await);
        }
        Ok(vec![])
    }

    pub fn reset_session_binding(&mut self, path: &str) {
        if let Some(state) = self.file_states.get_mut(path) {
            state.session_id = None;
            state.project_path = None;
            state.model_provider = None;
        }
    }

    // ── Line parsing (typed) ─────────────────────────────────────────────

    async fn parse_line(&mut self, line: &str, path: &str) -> Vec<RolloutEvent> {
        let Ok(rollout_line) = serde_json::from_str::<RolloutLine>(line) else {
            return vec![];
        };
        match rollout_line.item {
            RolloutItem::SessionMeta(meta) => self.parse_session_meta(meta, path).await,
            RolloutItem::TurnContext(ctx) => self.parse_turn_context(ctx, path),
            RolloutItem::EventMsg(event) => self.parse_event_msg(event, path),
            RolloutItem::ResponseItem(item) => self.parse_response_item(item, path),
            RolloutItem::Compacted(_) => vec![],
        }
    }

    async fn parse_session_meta(
        &mut self,
        meta_line: SessionMetaLine,
        path: &str,
    ) -> Vec<RolloutEvent> {
        let meta = meta_line.meta;
        let session_id = meta.id.to_string();
        let cwd = meta.cwd.to_string_lossy().to_string();
        let model_provider = meta.model_provider.clone();
        let originator = meta.originator.clone();
        let source = meta.source.clone();
        let started_at = if meta.timestamp.is_empty() {
            current_time_rfc3339()
        } else {
            meta.timestamp.clone()
        };
        let branch = meta_line.git.as_ref().and_then(|g| g.branch.clone());

        let (resolved_branch, _project_name) = resolve_git_info(&cwd).await;
        let branch = branch.or(resolved_branch);

        if let Some(state) = self.file_states.get_mut(path) {
            state.session_id = Some(session_id.clone());
            state.project_path = Some(cwd.clone());
            state.model_provider = model_provider.clone();
        }

        vec![RolloutEvent::SessionMeta {
            session_id,
            cwd,
            model_provider,
            originator,
            source,
            started_at,
            transcript_path: path.to_string(),
            branch,
        }]
    }

    fn parse_turn_context(&mut self, ctx: TurnContextItem, path: &str) -> Vec<RolloutEvent> {
        let Some(session_id) = self.file_session_id(path) else {
            return vec![];
        };

        let project_path = {
            let cwd_str = ctx.cwd.to_string_lossy().to_string();
            let changed = self
                .file_states
                .get(path)
                .and_then(|s| s.project_path.as_deref())
                .map(|existing| existing != cwd_str)
                .unwrap_or(true);
            if changed {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.project_path = Some(cwd_str.clone());
                }
                Some(cwd_str)
            } else {
                None
            }
        };

        let model = Some(ctx.model.clone());

        // Extract effort from the typed field, falling back to collaboration_mode
        let effort = ctx
            .effort
            .as_ref()
            .and_then(|e| serde_json::to_value(e).ok())
            .and_then(|v| v.as_str().map(str::to_string))
            .or_else(|| {
                ctx.collaboration_mode
                    .as_ref()
                    .and_then(|cm| cm.settings.reasoning_effort.as_ref())
                    .and_then(|e| serde_json::to_value(e).ok())
                    .and_then(|v| v.as_str().map(str::to_string))
            });

        if project_path.is_none() && model.is_none() && effort.is_none() {
            return vec![];
        }

        vec![RolloutEvent::TurnContext {
            session_id,
            project_path,
            model,
            effort,
        }]
    }

    fn parse_event_msg(&mut self, event: EventMsg, path: &str) -> Vec<RolloutEvent> {
        let Some(session_id) = self.file_session_id(path) else {
            return vec![];
        };

        match event {
            EventMsg::TurnStarted(_) => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = false;
                    state.saw_user_event = false;
                }
                vec![
                    RolloutEvent::WorkStateChange {
                        session_id: session_id.clone(),
                        work_status: WorkStatus::Working,
                        attention_reason: Some("none".to_string()),
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        last_tool: None,
                        last_tool_at: None,
                    },
                    RolloutEvent::ClearPending { session_id },
                ]
            }
            EventMsg::TurnComplete(_) | EventMsg::TurnAborted(_) => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = true;
                }
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Waiting,
                    attention_reason: Some("awaitingReply".to_string()),
                    pending_tool_name: Some(None),
                    pending_tool_input: Some(None),
                    pending_question: Some(None),
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::UserMessage(e) => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_user_event = true;
                    state.saw_agent_event = false;
                }
                vec![RolloutEvent::UserMessage {
                    session_id,
                    message: Some(e.message),
                }]
            }
            EventMsg::AgentMessage(_) => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = true;
                }
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Waiting,
                    attention_reason: Some("awaitingReply".to_string()),
                    pending_tool_name: Some(None),
                    pending_tool_input: Some(None),
                    pending_question: Some(None),
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::ExecCommandBegin(e) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let command = e.command.join(" ");
                vec![
                    RolloutEvent::ShellCommandBegin {
                        session_id: session_id.clone(),
                        call_id: e.call_id,
                        command,
                    },
                    RolloutEvent::WorkStateChange {
                        session_id,
                        work_status: WorkStatus::Working,
                        attention_reason: Some("none".to_string()),
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        last_tool: Some(Some("Shell".to_string())),
                        last_tool_at: Some(Some(current_time_rfc3339())),
                    },
                ]
            }
            EventMsg::ExecCommandEnd(e) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let output = if e.aggregated_output.is_empty() {
                    None
                } else {
                    Some(e.aggregated_output)
                };
                let is_error = Some(e.exit_code != 0);
                let duration_ms = Some(e.duration.as_millis() as u64);
                vec![
                    RolloutEvent::ShellCommandEnd {
                        session_id: session_id.clone(),
                        call_id: e.call_id,
                        output,
                        is_error,
                        duration_ms,
                    },
                    RolloutEvent::ToolCompleted {
                        session_id,
                        tool: Some("Shell".to_string()),
                    },
                ]
            }
            EventMsg::PatchApplyBegin(_) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Working,
                    attention_reason: Some("none".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                    last_tool: Some(Some("Edit".to_string())),
                    last_tool_at: Some(Some(current_time_rfc3339())),
                }]
            }
            EventMsg::PatchApplyEnd(_) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                vec![RolloutEvent::ToolCompleted {
                    session_id,
                    tool: Some("Edit".to_string()),
                }]
            }
            EventMsg::McpToolCallBegin(e) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let label = format!("MCP:{}/{}", e.invocation.server, e.invocation.tool);
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Working,
                    attention_reason: Some("none".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                    last_tool: Some(Some(label)),
                    last_tool_at: Some(Some(current_time_rfc3339())),
                }]
            }
            EventMsg::McpToolCallEnd(e) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let label = format!("MCP:{}/{}", e.invocation.server, e.invocation.tool);
                vec![RolloutEvent::ToolCompleted {
                    session_id,
                    tool: Some(label),
                }]
            }
            EventMsg::WebSearchBegin(_) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Working,
                    attention_reason: Some("none".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                    last_tool: Some(Some("WebSearch".to_string())),
                    last_tool_at: Some(Some(current_time_rfc3339())),
                }]
            }
            EventMsg::WebSearchEnd(_) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                vec![RolloutEvent::ToolCompleted {
                    session_id,
                    tool: Some("WebSearch".to_string()),
                }]
            }
            EventMsg::ViewImageToolCall(_) => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                vec![RolloutEvent::ToolCompleted {
                    session_id,
                    tool: Some("ViewImage".to_string()),
                }]
            }
            EventMsg::ExecApprovalRequest(_e) => {
                // Serialize the full event as JSON for the pending_tool_input field
                let payload_json = serde_json::to_string(&_e).ok();
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Permission,
                    attention_reason: Some("awaitingPermission".to_string()),
                    pending_tool_name: Some(Some("ExecCommand".to_string())),
                    pending_tool_input: Some(payload_json),
                    pending_question: None,
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::ApplyPatchApprovalRequest(_e) => {
                let payload_json = serde_json::to_string(&_e).ok();
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Permission,
                    attention_reason: Some("awaitingPermission".to_string()),
                    pending_tool_name: Some(Some("ApplyPatch".to_string())),
                    pending_tool_input: Some(payload_json),
                    pending_question: None,
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::RequestUserInput(e) => {
                let question = e
                    .questions
                    .first()
                    .and_then(|q| {
                        if q.question.is_empty() {
                            None
                        } else {
                            Some(q.question.clone())
                        }
                    })
                    .or_else(|| {
                        e.questions.first().and_then(|q| {
                            if q.header.is_empty() {
                                None
                            } else {
                                Some(q.header.clone())
                            }
                        })
                    });
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Question,
                    attention_reason: Some("awaitingQuestion".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: Some(question),
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::ElicitationRequest(e) => {
                let question = if e.message.is_empty() {
                    Some(e.server_name)
                } else {
                    Some(e.message)
                };
                vec![RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Question,
                    attention_reason: Some("awaitingQuestion".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: Some(question),
                    last_tool: None,
                    last_tool_at: None,
                }]
            }
            EventMsg::TokenCount(e) => {
                let (total_tokens, token_usage) = if let Some(ref info) = e.info {
                    let total = info.total_token_usage.total_tokens;
                    let usage = TokenUsage {
                        input_tokens: info.total_token_usage.input_tokens.max(0) as u64,
                        output_tokens: info.total_token_usage.output_tokens.max(0) as u64,
                        cached_tokens: info.total_token_usage.cached_input_tokens.max(0) as u64,
                        context_window: info.model_context_window.unwrap_or(0).max(0) as u64,
                    };
                    (Some(total), Some(usage))
                } else {
                    (None, None)
                };
                vec![RolloutEvent::TokenCount {
                    session_id,
                    total_tokens,
                    token_usage,
                }]
            }
            EventMsg::ThreadNameUpdated(e) => {
                if let Some(name) = e.thread_name {
                    vec![RolloutEvent::ThreadNameUpdated { session_id, name }]
                } else {
                    vec![]
                }
            }
            // ~50 other variants we don't care about
            _ => vec![],
        }
    }

    fn parse_response_item(&mut self, item: ResponseItem, path: &str) -> Vec<RolloutEvent> {
        let Some(session_id) = self.file_session_id(path) else {
            return vec![];
        };

        match item {
            ResponseItem::Message { role, content, .. } => {
                if role == "user" {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state.saw_user_event = true;
                        state.saw_agent_event = false;
                    }
                    let text = extract_text_from_content(&content);
                    let images = extract_images_from_content(&content);
                    let mut events = Vec::new();
                    if text.is_some() || !images.is_empty() {
                        events.push(RolloutEvent::AppendChatMessage {
                            session_id: session_id.clone(),
                            message_type: MessageType::User,
                            content: text.clone().unwrap_or_default(),
                            images,
                        });
                    }
                    events.push(RolloutEvent::UserMessage {
                        session_id,
                        message: text,
                    });
                    events
                } else if role == "assistant" {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state.saw_agent_event = true;
                    }
                    let mut events = Vec::new();
                    if let Some(text) = extract_text_from_content(&content) {
                        events.push(RolloutEvent::AppendChatMessage {
                            session_id: session_id.clone(),
                            message_type: MessageType::Assistant,
                            content: text,
                            images: vec![],
                        });
                    }
                    events.push(RolloutEvent::WorkStateChange {
                        session_id,
                        work_status: WorkStatus::Waiting,
                        attention_reason: Some("awaitingReply".to_string()),
                        pending_tool_name: Some(None),
                        pending_tool_input: Some(None),
                        pending_question: Some(None),
                        last_tool: None,
                        last_tool_at: None,
                    });
                    events
                } else {
                    vec![]
                }
            }
            ResponseItem::FunctionCall { call_id, name, .. } => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let tool = tool_label(Some(&name));
                if let Some(ref tool) = tool {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state.pending_tool_calls.insert(call_id, tool.clone());
                    }
                }
                if let Some(tool) = tool {
                    vec![RolloutEvent::WorkStateChange {
                        session_id,
                        work_status: WorkStatus::Working,
                        attention_reason: Some("none".to_string()),
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        last_tool: Some(Some(tool)),
                        last_tool_at: Some(Some(current_time_rfc3339())),
                    }]
                } else {
                    vec![]
                }
            }
            ResponseItem::FunctionCallOutput { call_id, .. } => {
                if self.saw_agent_event(path) {
                    return vec![];
                }
                let tool_name = if let Some(state) = self.file_states.get_mut(path) {
                    state.pending_tool_calls.remove(&call_id)
                } else {
                    None
                };
                if let Some(tool_name) = tool_name {
                    vec![RolloutEvent::ToolCompleted {
                        session_id,
                        tool: Some(tool_name),
                    }]
                } else {
                    vec![]
                }
            }
            _ => vec![],
        }
    }

    // ── File state helpers ───────────────────────────────────────────────

    pub fn file_session_id(&self, path: &str) -> Option<String> {
        self.file_states
            .get(path)
            .and_then(|s| s.session_id.clone())
    }

    pub fn mark_session_id(&mut self, path: &str, session_id: &str) {
        if let Some(state) = self.file_states.get_mut(path) {
            state.session_id = Some(session_id.to_string());
        }
    }

    fn saw_agent_event(&self, path: &str) -> bool {
        self.file_states
            .get(path)
            .map(|s| s.saw_agent_event)
            .unwrap_or(false)
    }

    pub fn ensure_file_state(&mut self, path: &str, size: u64, created_at: Option<SystemTime>) {
        if self.file_states.contains_key(path) {
            return;
        }

        if let Some(persisted) = self.persisted_state.files.get(path) {
            self.file_states.insert(
                path.to_string(),
                FileState {
                    offset: persisted.offset,
                    tail: String::new(),
                    session_id: persisted.session_id.clone(),
                    project_path: persisted.project_path.clone(),
                    model_provider: persisted.model_provider.clone(),
                    ignore_existing: persisted.ignore_existing.unwrap_or(false),
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            );
            return;
        }

        let mut ignore_existing = false;
        let mut offset = 0;

        if let Some(created_at) = created_at {
            if created_at < self.watcher_started_at {
                ignore_existing = true;
                offset = size;
            }
        }

        self.file_states.insert(
            path.to_string(),
            FileState {
                offset,
                tail: String::new(),
                session_id: None,
                project_path: None,
                model_provider: None,
                ignore_existing,
                pending_tool_calls: HashMap::new(),
                next_message_seq: 0,
                saw_user_event: false,
                saw_agent_event: false,
            },
        );
    }

    pub fn persist_state(&mut self, path: &str) {
        if let Some(state) = self.file_states.get(path) {
            self.persisted_state.files.insert(
                path.to_string(),
                PersistedFileState {
                    offset: state.offset,
                    session_id: state.session_id.clone(),
                    project_path: state.project_path.clone(),
                    model_provider: state.model_provider.clone(),
                    ignore_existing: Some(state.ignore_existing),
                },
            );
            if let Err(err) = save_persisted_state(&self.state_path, &self.persisted_state) {
                warn!(
                    component = "rollout_watcher",
                    event = "rollout_watcher.state_persist_failed",
                    path = %self.state_path.display(),
                    error = %err,
                    "Failed writing rollout state"
                );
            }
        }
    }

    /// Return file paths that have new bytes since last process.
    pub fn sweep_candidates(&self) -> Vec<PathBuf> {
        let mut candidates = Vec::new();
        for (path, state) in &self.file_states {
            let path_buf = PathBuf::from(path);
            if !path_buf.exists() {
                continue;
            }
            let Ok(metadata) = fs::metadata(&path_buf) else {
                continue;
            };
            if metadata.len() != state.offset {
                candidates.push(path_buf);
            }
        }
        candidates
    }
}

// ── Pure helper functions ────────────────────────────────────────────────────

fn extract_text_from_content(content: &[ContentItem]) -> Option<String> {
    let mut parts = Vec::new();
    for item in content {
        match item {
            ContentItem::InputText { text } | ContentItem::OutputText { text } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    parts.push(trimmed.to_string());
                }
            }
            _ => {}
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

fn extract_images_from_content(content: &[ContentItem]) -> Vec<ImageInput> {
    let mut images = Vec::new();
    for item in content {
        if let ContentItem::InputImage { image_url } = item {
            images.push(ImageInput {
                input_type: "url".to_string(),
                value: image_url.clone(),
            });
        }
    }
    images
}

fn tool_label(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    if raw.is_empty() {
        return None;
    }
    Some(match raw {
        "exec_command" => "Shell".to_string(),
        "patch_apply" | "apply_patch" => "Edit".to_string(),
        "web_search" => "WebSearch".to_string(),
        "view_image" => "ViewImage".to_string(),
        "mcp_tool_call" => "MCP".to_string(),
        other => other.to_string(),
    })
}

pub fn load_persisted_state(path: &Path) -> PersistedState {
    let Ok(data) = fs::read(path) else {
        return PersistedState::default();
    };
    serde_json::from_slice(&data).unwrap_or_default()
}

pub fn save_persisted_state(path: &Path, state: &PersistedState) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_vec(state)?;
    let tmp_path = path.with_extension("json.tmp");
    fs::write(&tmp_path, data)?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

pub fn collect_jsonl_files(root: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if is_jsonl_path(&path) {
                result.push(path);
            }
        }
    }
    result
}

pub fn is_recent_file(path: &Path, within_secs: u64) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    let Ok(modified) = meta.modified() else {
        return false;
    };
    let Ok(age) = SystemTime::now().duration_since(modified) else {
        return true;
    };
    age.as_secs() <= within_secs
}

fn read_first_line(path: &Path) -> anyhow::Result<Option<String>> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let read = reader.read_line(&mut line)?;
    if read == 0 {
        return Ok(None);
    }
    Ok(Some(line.trim_end_matches(['\r', '\n']).to_string()))
}

fn read_file_chunk(path: &Path, offset: u64) -> anyhow::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;
    file.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

pub fn is_jsonl_path(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some("jsonl")
}

pub fn rollout_session_id_hint(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    if stem.len() < 36 {
        return None;
    }
    let tail = &stem[stem.len() - 36..];
    if is_uuid_like(tail) {
        Some(tail.to_string())
    } else {
        None
    }
}

fn is_uuid_like(value: &str) -> bool {
    if value.len() != 36 {
        return false;
    }
    for (idx, ch) in value.chars().enumerate() {
        let is_dash = matches!(idx, 8 | 13 | 18 | 23);
        if is_dash {
            if ch != '-' {
                return false;
            }
        } else if !ch.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

pub async fn resolve_git_info(path: &str) -> (Option<String>, Option<String>) {
    let branch = run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path).await;
    let repo_root = run_git(&["rev-parse", "--show-toplevel"], path).await;
    let repo_name = repo_root
        .as_deref()
        .and_then(|root| Path::new(root).file_name())
        .map(|name| name.to_string_lossy().to_string());
    (branch, repo_name)
}

async fn run_git(args: &[&str], cwd: &str) -> Option<String> {
    let output = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

pub fn current_time_rfc3339() -> String {
    let duration = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}Z", duration.as_secs())
}

pub fn current_time_unix_z() -> String {
    let secs = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
}

pub fn matches_supported_event_kind(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Access(_) | EventKind::Any
    )
}
