//! Rollout file parser for passive Codex session watching.
//!
//! Reads `.codex/sessions/*.jsonl` files incrementally and emits typed
//! [`RolloutEvent`]s. All server orchestration (persistence, session handles,
//! broadcasts) lives in the server crate's `rollout_watcher` — this module is
//! pure parsing + file state tracking.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::SystemTime;

use codex_protocol::models::{ContentItem, ResponseItem};
use codex_protocol::protocol::{
    EventMsg, RolloutItem, RolloutLine, SessionMetaLine, TurnContextItem,
};

// Re-export SessionSource so the server crate can use it without depending on codex-protocol
pub use codex_protocol::protocol::{SessionSource, SubAgentSource};
use notify::EventKind;
use orbitdock_protocol::provider_normalization::shared::{
    NormalizedApprovalKind, NormalizedApprovalRequest, NormalizedHandoff, NormalizedHandoffKind,
    NormalizedHookEvent, NormalizedHookLifecycle, NormalizedPlanEvent, NormalizedQuestion,
    NormalizedQuestionKind, NormalizedWorkerLifecycle, NormalizedWorkerLifecycleKind,
    ProviderEventEnvelope, SharedNormalizedProviderEvent,
};
use orbitdock_protocol::{ImageInput, Provider, SubagentInfo, TokenUsage, WorkStatus};
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::debug;

use crate::timeline::{
    hook_completed_text, hook_output_text, hook_run_is_error, hook_started_text,
    realtime_text_from_handoff_request,
};

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
        role: String,
        content: String,
        tool_name: Option<String>,
        tool_input: Option<String>,
        is_error: bool,
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
    DiffUpdated {
        session_id: String,
        diff: String,
    },
    PlanUpdated {
        session_id: String,
        plan: String,
    },
    ProviderEvent {
        session_id: String,
        event: ProviderEventEnvelope,
    },
    SessionEnded {
        session_id: String,
        reason: String,
    },
    SubagentsUpdated {
        session_id: String,
        subagents: Vec<SubagentInfo>,
    },
}

// ── Parser state types ───────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct ParseState {
    pub session_id: Option<String>,
    pub project_path: Option<String>,
    pub model_provider: Option<String>,
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
    pub parse_states: HashMap<String, ParseState>,
    checkpoint_seeds: HashMap<String, PersistedFileState>,
}

impl RolloutFileProcessor {
    pub fn new(checkpoint_seeds: HashMap<String, PersistedFileState>) -> Self {
        Self {
            parse_states: HashMap::new(),
            checkpoint_seeds,
        }
    }

    pub async fn ensure_session_meta_line(
        &mut self,
        path: &str,
        line: Option<&str>,
    ) -> anyhow::Result<Vec<RolloutEvent>> {
        let Some(line) = line else {
            return Ok(vec![]);
        };
        let Ok(rollout_line) = serde_json::from_str::<RolloutLine>(line) else {
            return Ok(vec![]);
        };
        if let RolloutItem::SessionMeta(meta) = rollout_line.item {
            return Ok(self.parse_session_meta(meta, path).await);
        }
        Ok(vec![])
    }

    pub fn reset_session_binding(&mut self, path: &str) {
        if let Some(state) = self.parse_states.get_mut(path) {
            state.session_id = None;
            state.project_path = None;
            state.model_provider = None;
        }
    }

    pub fn remove_path(&mut self, path: &str) {
        self.parse_states.remove(path);
    }

    pub fn binding_snapshot(&self, path: &str) -> Option<PersistedFileState> {
        self.parse_states.get(path).map(|state| PersistedFileState {
            offset: 0,
            session_id: state.session_id.clone(),
            project_path: state.project_path.clone(),
            model_provider: state.model_provider.clone(),
            ignore_existing: None,
        })
    }

    pub async fn parse_lines(
        &mut self,
        path: &str,
        lines: &[String],
    ) -> anyhow::Result<Vec<RolloutEvent>> {
        self.ensure_parse_state(path);

        let mut events = Vec::new();
        for line in lines {
            events.extend(self.parse_line(line, path).await);
        }

        if !events.is_empty() {
            debug!(
                component = "rollout_watcher",
                event = "rollout_watcher.lines_processed",
                path = %path,
                line_count = lines.len(),
                "Processed rollout lines"
            );
        }

        Ok(events)
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

        self.ensure_parse_state(path);
        if let Some(state) = self.parse_states.get_mut(path) {
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
                .parse_states
                .get(path)
                .and_then(|s| s.project_path.as_deref())
                .map(|existing| existing != cwd_str)
                .unwrap_or(true);
            if changed {
                if let Some(state) = self.parse_states.get_mut(path) {
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

    fn next_rollout_event_id(&mut self, path: &str, prefix: &str) -> String {
        let seq = if let Some(state) = self.parse_states.get_mut(path) {
            let seq = state.next_message_seq;
            state.next_message_seq = state.next_message_seq.saturating_add(1);
            seq
        } else {
            0
        };
        let session_id = self
            .file_session_id(path)
            .unwrap_or_else(|| "unknown-session".to_string());
        format!("{prefix}-{session_id}-{seq}")
    }

    fn provider_rollout_event(
        &mut self,
        path: &str,
        event: SharedNormalizedProviderEvent,
    ) -> Option<RolloutEvent> {
        let session_id = self.file_session_id(path)?;
        Some(RolloutEvent::ProviderEvent {
            session_id: session_id.clone(),
            event: ProviderEventEnvelope {
                provider: Provider::Codex,
                session_id,
                turn_id: None,
                timestamp: Some(current_time_rfc3339()),
                event,
            },
        })
    }

    fn parse_event_msg(&mut self, event: EventMsg, path: &str) -> Vec<RolloutEvent> {
        let Some(session_id) = self.file_session_id(path) else {
            return vec![];
        };

        match event {
            EventMsg::TurnStarted(_) => {
                if let Some(state) = self.parse_states.get_mut(path) {
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
                if let Some(state) = self.parse_states.get_mut(path) {
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
                if let Some(state) = self.parse_states.get_mut(path) {
                    state.saw_user_event = true;
                    state.saw_agent_event = false;
                }
                vec![RolloutEvent::UserMessage {
                    session_id,
                    message: Some(e.message),
                }]
            }
            EventMsg::AgentMessage(_) => {
                if let Some(state) = self.parse_states.get_mut(path) {
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
                let command = _e.command.join(" ");
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::ApprovalRequest(NormalizedApprovalRequest {
                        id: _e.approval_id.clone().unwrap_or_else(|| _e.call_id.clone()),
                        kind: NormalizedApprovalKind::Exec,
                        tool_name: Some("execcommand".to_string()),
                        title: Some("Command approval requested".to_string()),
                        summary: (!command.is_empty()).then_some(command.clone()),
                        details: serde_json::to_value(&_e).ok(),
                        requestor_worker_id: None,
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Permission,
                    attention_reason: Some("awaitingPermission".to_string()),
                    pending_tool_name: Some(Some("ExecCommand".to_string())),
                    pending_tool_input: Some(payload_json),
                    pending_question: None,
                    last_tool: None,
                    last_tool_at: None,
                });
                events
            }
            EventMsg::ApplyPatchApprovalRequest(_e) => {
                let payload_json = serde_json::to_string(&_e).ok();
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::ApprovalRequest(NormalizedApprovalRequest {
                        id: _e.call_id.clone(),
                        kind: NormalizedApprovalKind::Patch,
                        tool_name: Some("applypatch".to_string()),
                        title: Some("Patch approval requested".to_string()),
                        summary: Some(format!("{} file changes pending", _e.changes.len())),
                        details: serde_json::to_value(&_e).ok(),
                        requestor_worker_id: None,
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Permission,
                    attention_reason: Some("awaitingPermission".to_string()),
                    pending_tool_name: Some(Some("ApplyPatch".to_string())),
                    pending_tool_input: Some(payload_json),
                    pending_question: None,
                    last_tool: None,
                    last_tool_at: None,
                });
                events
            }
            EventMsg::RequestPermissions(e) => {
                let payload_json = serde_json::to_string(&serde_json::json!({
                    "reason": e.reason,
                    "permissions": e.permissions,
                }))
                .ok();
                let content = e
                    .reason
                    .clone()
                    .unwrap_or_else(|| "Permission requested".to_string());
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::ApprovalRequest(NormalizedApprovalRequest {
                        id: e.call_id.clone(),
                        kind: NormalizedApprovalKind::Permissions,
                        tool_name: Some("request_permissions".to_string()),
                        title: Some("Permission request".to_string()),
                        summary: Some(content.clone()),
                        details: serde_json::to_value(&e).ok(),
                        requestor_worker_id: None,
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Permission,
                    attention_reason: Some("awaitingPermission".to_string()),
                    pending_tool_name: Some(Some("RequestPermissions".to_string())),
                    pending_tool_input: Some(payload_json),
                    pending_question: Some(Some(content)),
                    last_tool: None,
                    last_tool_at: None,
                });
                events
            }
            EventMsg::CollabAgentSpawnEnd(e) => {
                let Some(thread_id) = e.new_thread_id else {
                    return vec![];
                };
                let subagent = build_rollout_subagent_for_status(
                    thread_id.to_string(),
                    e.new_agent_role.clone(),
                    e.new_agent_nickname.clone(),
                    Some(e.prompt.clone()),
                    Some(e.sender_thread_id.to_string()),
                    &e.status,
                );
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::WorkerLifecycle(NormalizedWorkerLifecycle {
                        worker_id: thread_id.to_string(),
                        lifecycle: NormalizedWorkerLifecycleKind::Spawned,
                        operation: Some("spawn".to_string()),
                        sender_worker_id: Some(e.sender_thread_id.to_string()),
                        receiver_worker_id: None,
                        label: subagent.label.clone(),
                        summary: subagent.task_summary.clone(),
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents: vec![subagent],
                });
                events
            }
            EventMsg::CollabAgentInteractionBegin(e) => {
                let worker_id = e.receiver_thread_id.to_string();
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::WorkerLifecycle(NormalizedWorkerLifecycle {
                        worker_id: worker_id.clone(),
                        lifecycle: NormalizedWorkerLifecycleKind::InteractionStarted,
                        operation: Some("interact".to_string()),
                        sender_worker_id: Some(e.sender_thread_id.to_string()),
                        receiver_worker_id: Some(worker_id.clone()),
                        label: None,
                        summary: Some(e.prompt.clone()),
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents: vec![build_running_rollout_subagent(
                        worker_id,
                        None,
                        None,
                        Some(e.prompt.clone()),
                        Some(e.sender_thread_id.to_string()),
                    )],
                });
                events
            }
            EventMsg::CollabAgentInteractionEnd(e) => {
                let subagent = build_rollout_subagent_for_status(
                    e.receiver_thread_id.to_string(),
                    e.receiver_agent_role.clone(),
                    e.receiver_agent_nickname.clone(),
                    Some(e.prompt.clone()),
                    Some(e.sender_thread_id.to_string()),
                    &e.status,
                );
                let mut events = Vec::new();
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::WorkerLifecycle(NormalizedWorkerLifecycle {
                        worker_id: e.receiver_thread_id.to_string(),
                        lifecycle: NormalizedWorkerLifecycleKind::InteractionCompleted,
                        operation: Some("interact".to_string()),
                        sender_worker_id: Some(e.sender_thread_id.to_string()),
                        receiver_worker_id: Some(e.receiver_thread_id.to_string()),
                        label: subagent.label.clone(),
                        summary: subagent
                            .result_summary
                            .clone()
                            .or(subagent.task_summary.clone()),
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents: vec![subagent],
                });
                events
            }
            EventMsg::CollabWaitingBegin(e) => {
                let subagents: Vec<SubagentInfo> = if !e.receiver_agents.is_empty() {
                    e.receiver_agents
                        .iter()
                        .map(|agent| {
                            build_running_rollout_subagent(
                                agent.thread_id.to_string(),
                                agent.agent_role.clone(),
                                agent.agent_nickname.clone(),
                                None,
                                Some(e.sender_thread_id.to_string()),
                            )
                        })
                        .collect()
                } else {
                    e.receiver_thread_ids
                        .iter()
                        .map(|thread_id| {
                            build_running_rollout_subagent(
                                thread_id.to_string(),
                                None,
                                None,
                                None,
                                Some(e.sender_thread_id.to_string()),
                            )
                        })
                        .collect()
                };

                if subagents.is_empty() {
                    vec![]
                } else {
                    let mut events = self
                        .provider_rollout_event(
                            path,
                            SharedNormalizedProviderEvent::WorkerLifecycle(
                                NormalizedWorkerLifecycle {
                                    worker_id: e.sender_thread_id.to_string(),
                                    lifecycle: NormalizedWorkerLifecycleKind::Waiting,
                                    operation: Some("wait".to_string()),
                                    sender_worker_id: Some(e.sender_thread_id.to_string()),
                                    receiver_worker_id: None,
                                    label: None,
                                    summary: Some(format!(
                                        "Waiting for {} agent(s)",
                                        subagents.len()
                                    )),
                                    details: serde_json::to_value(&e).ok(),
                                },
                            ),
                        )
                        .into_iter()
                        .collect::<Vec<_>>();
                    events.push(RolloutEvent::SubagentsUpdated {
                        session_id,
                        subagents,
                    });
                    events
                }
            }
            EventMsg::CollabWaitingEnd(e) => {
                let mut subagents = Vec::new();
                if !e.agent_statuses.is_empty() {
                    for entry in &e.agent_statuses {
                        subagents.push(build_authoritative_rollout_subagent(
                            entry.thread_id.to_string(),
                            entry.agent_role.clone(),
                            entry.agent_nickname.clone(),
                            None,
                            Some(e.sender_thread_id.to_string()),
                            &entry.status,
                        ));
                    }
                } else {
                    for (thread_id, status) in &e.statuses {
                        subagents.push(build_authoritative_rollout_subagent(
                            thread_id.to_string(),
                            None,
                            None,
                            None,
                            Some(e.sender_thread_id.to_string()),
                            status,
                        ));
                    }
                }

                if subagents.is_empty() {
                    vec![]
                } else {
                    let mut events = self
                        .provider_rollout_event(
                            path,
                            SharedNormalizedProviderEvent::WorkerLifecycle(
                                NormalizedWorkerLifecycle {
                                    worker_id: e.sender_thread_id.to_string(),
                                    lifecycle: NormalizedWorkerLifecycleKind::Updated,
                                    operation: Some("wait".to_string()),
                                    sender_worker_id: Some(e.sender_thread_id.to_string()),
                                    receiver_worker_id: None,
                                    label: None,
                                    summary: Some(format!(
                                        "Updated {} worker status(es)",
                                        subagents.len()
                                    )),
                                    details: serde_json::to_value(&e).ok(),
                                },
                            ),
                        )
                        .into_iter()
                        .collect::<Vec<_>>();
                    events.push(RolloutEvent::SubagentsUpdated {
                        session_id,
                        subagents,
                    });
                    events
                }
            }
            EventMsg::CollabResumeBegin(e) => {
                let worker_id = e.receiver_thread_id.to_string();
                let mut events = self
                    .provider_rollout_event(
                        path,
                        SharedNormalizedProviderEvent::WorkerLifecycle(NormalizedWorkerLifecycle {
                            worker_id: worker_id.clone(),
                            lifecycle: NormalizedWorkerLifecycleKind::Resumed,
                            operation: Some("resume".to_string()),
                            sender_worker_id: Some(e.sender_thread_id.to_string()),
                            receiver_worker_id: Some(worker_id.clone()),
                            label: e.receiver_agent_nickname.clone(),
                            summary: None,
                            details: serde_json::to_value(&e).ok(),
                        }),
                    )
                    .into_iter()
                    .collect::<Vec<_>>();
                events.push(RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents: vec![build_running_rollout_subagent(
                        worker_id,
                        e.receiver_agent_role.clone(),
                        e.receiver_agent_nickname.clone(),
                        None,
                        Some(e.sender_thread_id.to_string()),
                    )],
                });
                events
            }
            EventMsg::CollabResumeEnd(e) => {
                let subagent = build_rollout_subagent_for_status(
                    e.receiver_thread_id.to_string(),
                    e.receiver_agent_role.clone(),
                    e.receiver_agent_nickname.clone(),
                    None,
                    Some(e.sender_thread_id.to_string()),
                    &e.status,
                );
                let mut events = self
                    .provider_rollout_event(
                        path,
                        SharedNormalizedProviderEvent::WorkerLifecycle(NormalizedWorkerLifecycle {
                            worker_id: e.receiver_thread_id.to_string(),
                            lifecycle: NormalizedWorkerLifecycleKind::Updated,
                            operation: Some("resume".to_string()),
                            sender_worker_id: Some(e.sender_thread_id.to_string()),
                            receiver_worker_id: Some(e.receiver_thread_id.to_string()),
                            label: subagent.label.clone(),
                            summary: subagent
                                .result_summary
                                .clone()
                                .or(subagent.task_summary.clone()),
                            details: serde_json::to_value(&e).ok(),
                        }),
                    )
                    .into_iter()
                    .collect::<Vec<_>>();
                events.push(RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents: vec![subagent],
                });
                events
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
                let _tool_input = serde_json::to_string(&serde_json::json!({
                    "questions": e.questions,
                }))
                .ok();
                let mut events = Vec::new();
                let event_id = self.next_rollout_event_id(path, "ask-user-question");
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::Question(NormalizedQuestion {
                        id: event_id,
                        kind: NormalizedQuestionKind::AskUser,
                        prompt: question
                            .clone()
                            .unwrap_or_else(|| "Question requested".to_string()),
                        title: None,
                        summary: Some(format!("{} prompt(s)", e.questions.len())),
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Question,
                    attention_reason: Some("awaitingQuestion".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: Some(question),
                    last_tool: None,
                    last_tool_at: None,
                });
                events
            }
            EventMsg::ElicitationRequest(e) => {
                let question = if e.request.message().is_empty() {
                    Some(e.server_name.clone())
                } else {
                    Some(e.request.message().to_string())
                };
                let mut events = Vec::new();
                let event_id = self.next_rollout_event_id(path, "elicitation-request");
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::Question(NormalizedQuestion {
                        id: event_id,
                        kind: NormalizedQuestionKind::Elicitation,
                        prompt: question
                            .clone()
                            .unwrap_or_else(|| "MCP approval requested".to_string()),
                        title: Some(format!("{} request", e.server_name)),
                        summary: None,
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events.push(RolloutEvent::WorkStateChange {
                    session_id,
                    work_status: WorkStatus::Question,
                    attention_reason: Some("awaitingQuestion".to_string()),
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: Some(question),
                    last_tool: None,
                    last_tool_at: None,
                });
                events
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
            EventMsg::TurnDiff(e) => vec![RolloutEvent::DiffUpdated {
                session_id,
                diff: e.unified_diff,
            }],
            EventMsg::PlanUpdate(e) => {
                let plan = serde_json::to_string(&e).unwrap_or_default();
                let explanation = e
                    .explanation
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("Plan updated");
                let content = format!("{} ({} steps)", explanation, e.plan.len());
                let mut events = vec![RolloutEvent::PlanUpdated {
                    session_id: session_id.clone(),
                    plan,
                }];
                let event_id = self.next_rollout_event_id(path, "plan-update");
                if let Some(event) = self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::Plan(NormalizedPlanEvent {
                        id: event_id,
                        title: Some("Plan updated".to_string()),
                        summary: Some(content),
                        steps: e.plan.iter().map(|step| step.step.clone()).collect(),
                        details: serde_json::to_value(&e).ok(),
                    }),
                ) {
                    events.push(event);
                }
                events
            }
            EventMsg::ThreadNameUpdated(e) => {
                if let Some(name) = e.thread_name {
                    vec![RolloutEvent::ThreadNameUpdated { session_id, name }]
                } else {
                    vec![]
                }
            }
            EventMsg::RealtimeConversationRealtime(e) => match e.payload {
                codex_protocol::protocol::RealtimeEvent::SessionUpdated { .. }
                | codex_protocol::protocol::RealtimeEvent::InputTranscriptDelta(_)
                | codex_protocol::protocol::RealtimeEvent::OutputTranscriptDelta(_)
                | codex_protocol::protocol::RealtimeEvent::ConversationItemDone { .. }
                | codex_protocol::protocol::RealtimeEvent::ConversationItemAdded(_)
                | codex_protocol::protocol::RealtimeEvent::AudioOut(_) => vec![],
                codex_protocol::protocol::RealtimeEvent::HandoffRequested(handoff) => {
                    let Some(content) = realtime_text_from_handoff_request(&handoff) else {
                        return vec![];
                    };
                    let event_id = self.next_rollout_event_id(path, "handoff");
                    self.provider_rollout_event(
                        path,
                        SharedNormalizedProviderEvent::Handoff(NormalizedHandoff {
                            id: event_id,
                            kind: NormalizedHandoffKind::Requested,
                            target: None,
                            summary: Some(content),
                            details: serde_json::to_value(&handoff).ok(),
                        }),
                    )
                    .into_iter()
                    .collect()
                }
                codex_protocol::protocol::RealtimeEvent::Error(message_text) => {
                    vec![RolloutEvent::AppendChatMessage {
                        session_id,
                        role: "assistant".to_string(),
                        content: format!("Realtime conversation error: {}", message_text),
                        tool_name: None,
                        tool_input: None,
                        is_error: true,
                        images: vec![],
                    }]
                }
            },
            EventMsg::BackgroundEvent(e) => vec![RolloutEvent::AppendChatMessage {
                session_id,
                role: "assistant".to_string(),
                content: e.message,
                tool_name: None,
                tool_input: None,
                is_error: false,
                images: vec![],
            }],
            EventMsg::HookStarted(e) => {
                let event_id = self.next_rollout_event_id(path, "hook");
                self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::Hook(NormalizedHookEvent {
                        id: event_id,
                        lifecycle: NormalizedHookLifecycle::Started,
                        hook_name: Some(format!("{:?}", e.run.event_name)),
                        summary: Some(hook_started_text(&e.run)),
                        output: None,
                        had_error: Some(false),
                        details: serde_json::to_value(&e.run).ok(),
                    }),
                )
                .into_iter()
                .collect()
            }
            EventMsg::HookCompleted(e) => {
                let event_id = self.next_rollout_event_id(path, "hook");
                self.provider_rollout_event(
                    path,
                    SharedNormalizedProviderEvent::Hook(NormalizedHookEvent {
                        id: event_id,
                        lifecycle: NormalizedHookLifecycle::Completed,
                        hook_name: Some(format!("{:?}", e.run.event_name)),
                        summary: Some(hook_completed_text(&e.run)),
                        output: hook_output_text(&e.run),
                        had_error: Some(hook_run_is_error(e.run.status)),
                        details: serde_json::to_value(&e.run).ok(),
                    }),
                )
                .into_iter()
                .collect()
            }
            EventMsg::ShutdownComplete => vec![RolloutEvent::SessionEnded {
                session_id,
                reason: "shutdown".to_string(),
            }],
            EventMsg::Warning(e) => {
                vec![RolloutEvent::AppendChatMessage {
                    session_id,
                    role: "assistant".to_string(),
                    content: e.message,
                    tool_name: None,
                    tool_input: None,
                    is_error: false,
                    images: vec![],
                }]
            }
            EventMsg::ModelReroute(e) => {
                vec![RolloutEvent::AppendChatMessage {
                    session_id,
                    role: "assistant".to_string(),
                    content: format!(
                        "Model rerouted from {} to {} ({:?})",
                        e.from_model, e.to_model, e.reason
                    ),
                    tool_name: None,
                    tool_input: None,
                    is_error: false,
                    images: vec![],
                }]
            }
            EventMsg::DeprecationNotice(e) => {
                let details = e.details.unwrap_or_default();
                let content = if details.is_empty() {
                    e.summary
                } else {
                    format!("{}\n\n{}", e.summary, details)
                };
                vec![RolloutEvent::AppendChatMessage {
                    session_id,
                    role: "assistant".to_string(),
                    content,
                    tool_name: None,
                    tool_input: None,
                    is_error: false,
                    images: vec![],
                }]
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
                    if let Some(state) = self.parse_states.get_mut(path) {
                        state.saw_user_event = true;
                        state.saw_agent_event = false;
                    }
                    let text = extract_text_from_content(&content);
                    let images = extract_images_from_content(&content);
                    let mut events = Vec::new();
                    if text.is_some() || !images.is_empty() {
                        events.push(RolloutEvent::AppendChatMessage {
                            session_id: session_id.clone(),
                            role: "user".to_string(),
                            content: text.clone().unwrap_or_default(),
                            tool_name: None,
                            tool_input: None,
                            is_error: false,
                            images,
                        });
                    }
                    events.push(RolloutEvent::UserMessage {
                        session_id,
                        message: text,
                    });
                    events
                } else if role == "assistant" {
                    if let Some(state) = self.parse_states.get_mut(path) {
                        state.saw_agent_event = true;
                    }
                    let mut events = Vec::new();
                    if let Some(text) = extract_text_from_content(&content) {
                        events.push(RolloutEvent::AppendChatMessage {
                            session_id: session_id.clone(),
                            role: "assistant".to_string(),
                            content: text,
                            tool_name: None,
                            tool_input: None,
                            is_error: false,
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
                    if let Some(state) = self.parse_states.get_mut(path) {
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
                let tool_name = if let Some(state) = self.parse_states.get_mut(path) {
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
        self.parse_states
            .get(path)
            .and_then(|s| s.session_id.clone())
    }

    pub fn mark_session_id(&mut self, path: &str, session_id: &str) {
        self.ensure_parse_state(path);
        if let Some(state) = self.parse_states.get_mut(path) {
            state.session_id = Some(session_id.to_string());
        }
    }

    fn saw_agent_event(&self, path: &str) -> bool {
        self.parse_states
            .get(path)
            .map(|s| s.saw_agent_event)
            .unwrap_or(false)
    }

    fn ensure_parse_state(&mut self, path: &str) {
        if self.parse_states.contains_key(path) {
            return;
        }

        let seeded = self.checkpoint_seeds.get(path).cloned().unwrap_or_default();

        self.parse_states.insert(
            path.to_string(),
            ParseState {
                session_id: seeded.session_id,
                project_path: seeded.project_path,
                model_provider: seeded.model_provider,
                pending_tool_calls: HashMap::new(),
                next_message_seq: 0,
                saw_user_event: false,
                saw_agent_event: false,
            },
        );
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
                ..Default::default()
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

fn normalized_rollout_summary(value: Option<String>) -> Option<String> {
    value.and_then(|summary| {
        let trimmed = summary.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
}

fn build_authoritative_rollout_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &codex_protocol::protocol::AgentStatus,
) -> SubagentInfo {
    let now = current_time_rfc3339();
    let (mapped_status, ended_at, result_summary, error_summary) =
        map_rollout_agent_status(status, &now);

    SubagentInfo {
        id: id.clone(),
        agent_type: normalized_rollout_agent_type(agent_role.as_deref()),
        started_at: now.clone(),
        ended_at,
        provider: Some(orbitdock_protocol::Provider::Codex),
        label: normalized_rollout_agent_label(
            agent_nickname.as_deref(),
            agent_role.as_deref(),
            &id,
        ),
        status: mapped_status,
        task_summary: normalized_rollout_summary(task_summary),
        result_summary,
        error_summary,
        parent_subagent_id,
        model: None,
        last_activity_at: Some(now),
    }
}

fn build_inflight_rollout_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &codex_protocol::protocol::AgentStatus,
) -> Option<SubagentInfo> {
    let mapped_status = match status {
        codex_protocol::protocol::AgentStatus::PendingInit => {
            orbitdock_protocol::SubagentStatus::Pending
        }
        codex_protocol::protocol::AgentStatus::Running => {
            orbitdock_protocol::SubagentStatus::Running
        }
        codex_protocol::protocol::AgentStatus::Completed(_)
        | codex_protocol::protocol::AgentStatus::Errored(_)
        | codex_protocol::protocol::AgentStatus::Shutdown
        | codex_protocol::protocol::AgentStatus::NotFound => return None,
    };

    let now = current_time_rfc3339();
    Some(SubagentInfo {
        id: id.clone(),
        agent_type: normalized_rollout_agent_type(agent_role.as_deref()),
        started_at: now.clone(),
        ended_at: None,
        provider: Some(orbitdock_protocol::Provider::Codex),
        label: normalized_rollout_agent_label(
            agent_nickname.as_deref(),
            agent_role.as_deref(),
            &id,
        ),
        status: mapped_status,
        task_summary: normalized_rollout_summary(task_summary),
        result_summary: None,
        error_summary: None,
        parent_subagent_id,
        model: None,
        last_activity_at: Some(now),
    })
}

fn build_running_rollout_subagent(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
) -> SubagentInfo {
    build_inflight_rollout_subagent(
        id,
        agent_role,
        agent_nickname,
        task_summary,
        parent_subagent_id,
        &codex_protocol::protocol::AgentStatus::Running,
    )
    .expect("running rollout subagent should always build")
}

fn build_rollout_subagent_for_status(
    id: String,
    agent_role: Option<String>,
    agent_nickname: Option<String>,
    task_summary: Option<String>,
    parent_subagent_id: Option<String>,
    status: &codex_protocol::protocol::AgentStatus,
) -> SubagentInfo {
    match status {
        codex_protocol::protocol::AgentStatus::PendingInit
        | codex_protocol::protocol::AgentStatus::Running => build_inflight_rollout_subagent(
            id,
            agent_role,
            agent_nickname,
            task_summary,
            parent_subagent_id,
            status,
        )
        .expect("non-terminal rollout subagent should always build"),
        codex_protocol::protocol::AgentStatus::Completed(_)
        | codex_protocol::protocol::AgentStatus::Errored(_)
        | codex_protocol::protocol::AgentStatus::Shutdown
        | codex_protocol::protocol::AgentStatus::NotFound => build_authoritative_rollout_subagent(
            id,
            agent_role,
            agent_nickname,
            task_summary,
            parent_subagent_id,
            status,
        ),
    }
}

fn map_rollout_agent_status(
    status: &codex_protocol::protocol::AgentStatus,
    now: &str,
) -> (
    orbitdock_protocol::SubagentStatus,
    Option<String>,
    Option<String>,
    Option<String>,
) {
    match status {
        codex_protocol::protocol::AgentStatus::PendingInit => (
            orbitdock_protocol::SubagentStatus::Pending,
            None,
            None,
            None,
        ),
        codex_protocol::protocol::AgentStatus::Running => (
            orbitdock_protocol::SubagentStatus::Running,
            None,
            None,
            None,
        ),
        codex_protocol::protocol::AgentStatus::Completed(summary) => (
            orbitdock_protocol::SubagentStatus::Completed,
            Some(now.to_string()),
            normalized_rollout_summary(summary.clone()),
            None,
        ),
        codex_protocol::protocol::AgentStatus::Errored(message) => (
            orbitdock_protocol::SubagentStatus::Failed,
            Some(now.to_string()),
            None,
            normalized_rollout_summary(Some(message.clone())),
        ),
        codex_protocol::protocol::AgentStatus::Shutdown => (
            orbitdock_protocol::SubagentStatus::Shutdown,
            Some(now.to_string()),
            None,
            None,
        ),
        codex_protocol::protocol::AgentStatus::NotFound => (
            orbitdock_protocol::SubagentStatus::NotFound,
            Some(now.to_string()),
            None,
            Some("Agent not found".to_string()),
        ),
    }
}

fn normalized_rollout_agent_type(role: Option<&str>) -> String {
    role.map(str::trim)
        .filter(|role| !role.is_empty())
        .unwrap_or("agent")
        .to_string()
}

fn normalized_rollout_agent_label(
    nickname: Option<&str>,
    role: Option<&str>,
    id: &str,
) -> Option<String> {
    nickname
        .map(str::trim)
        .filter(|nickname| !nickname.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            role.map(str::trim)
                .filter(|role| !role.is_empty())
                .map(ToOwned::to_owned)
        })
        .or_else(|| Some(id.to_string()))
}

pub fn load_legacy_persisted_state(path: &Path) -> PersistedState {
    let Ok(data) = fs::read(path) else {
        return PersistedState::default();
    };
    serde_json::from_slice(&data).unwrap_or_default()
}

pub fn load_legacy_rollout_checkpoints(path: &Path) -> HashMap<String, PersistedFileState> {
    load_legacy_persisted_state(path).files
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

pub fn matches_supported_event_kind(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Access(_) | EventKind::Any
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binding_snapshot_reflects_current_parse_state() {
        let path = "/tmp/rollout.jsonl";
        let mut processor = RolloutFileProcessor::new(HashMap::new());
        processor.parse_states.insert(
            path.to_string(),
            ParseState {
                session_id: Some("session-1".to_string()),
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("gpt-5".to_string()),
                pending_tool_calls: HashMap::new(),
                next_message_seq: 7,
                saw_user_event: true,
                saw_agent_event: true,
            },
        );

        let snapshot = processor.binding_snapshot(path).expect("binding snapshot");

        assert_eq!(snapshot.offset, 0);
        assert_eq!(snapshot.session_id.as_deref(), Some("session-1"));
        assert_eq!(snapshot.project_path.as_deref(), Some("/tmp/repo"));
        assert_eq!(snapshot.model_provider.as_deref(), Some("gpt-5"));
        assert_eq!(snapshot.ignore_existing, None);
    }

    #[test]
    fn mark_session_id_initializes_seeded_parse_state() {
        let path = "/tmp/rollout.jsonl";
        let mut processor = RolloutFileProcessor::new(HashMap::from([(
            path.to_string(),
            PersistedFileState {
                offset: 128,
                session_id: Some("session-2".to_string()),
                project_path: Some("/tmp/project".to_string()),
                model_provider: Some("codex".to_string()),
                ignore_existing: Some(false),
            },
        )]));

        processor.mark_session_id(path, "session-3");

        let state = processor.parse_states.get(path).expect("parse state");
        assert_eq!(state.session_id.as_deref(), Some("session-3"));
        assert_eq!(state.project_path.as_deref(), Some("/tmp/project"));
        assert_eq!(state.model_provider.as_deref(), Some("codex"));
    }
}
