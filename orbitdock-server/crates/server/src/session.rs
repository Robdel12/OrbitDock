//! Session management

use std::collections::VecDeque;
use std::sync::Arc;

use arc_swap::ArcSwap;
use orbitdock_protocol::{
    ApprovalQuestionOption, ApprovalQuestionPrompt, ApprovalRequest, ApprovalType,
    ClaudeIntegrationMode, CodexIntegrationMode, Message, Provider, SessionState, SessionStatus,
    SessionSummary, StateChanges, SubagentInfo, TokenUsage, TokenUsageSnapshotKind, TurnDiff,
    WorkStatus,
};
use tokio::sync::broadcast;
use tracing::info;

use orbitdock_protocol::ServerMessage;

use crate::transition::{TransitionState, WorkPhase};

/// Events that matter for the session list sidebar (status, mode, name changes).
/// Per-message events (streaming deltas, message appends) are excluded to avoid
/// overflowing the list broadcast channel during active turns.
fn is_list_relevant(msg: &ServerMessage) -> bool {
    matches!(
        msg,
        ServerMessage::SessionCreated { .. }
            | ServerMessage::SessionEnded { .. }
            | ServerMessage::SessionDelta { .. }
            | ServerMessage::SessionForked { .. }
            | ServerMessage::SessionSnapshot { .. }
    )
}

fn fallback_tool_name(approval: &ApprovalRequest) -> Option<String> {
    if let Some(name) = approval.tool_name.as_ref().filter(|name| !name.is_empty()) {
        return Some(name.clone());
    }

    match approval.approval_type {
        ApprovalType::Exec => Some("Bash".to_string()),
        ApprovalType::Patch => Some("Edit".to_string()),
        ApprovalType::Question => None,
    }
}

fn fallback_tool_input(approval: &ApprovalRequest) -> Option<String> {
    if let Some(input) = approval
        .tool_input
        .as_ref()
        .filter(|input| !input.is_empty())
    {
        return Some(input.clone());
    }

    let mut payload = serde_json::Map::new();
    if let Some(command) = approval.command.as_ref().filter(|cmd| !cmd.is_empty()) {
        payload.insert(
            "command".to_string(),
            serde_json::Value::String(command.clone()),
        );
    }
    if let Some(path) = approval.file_path.as_ref().filter(|path| !path.is_empty()) {
        payload.insert(
            "file_path".to_string(),
            serde_json::Value::String(path.clone()),
        );
    }
    if payload.is_empty() {
        if let Some(preview) = approval.preview.as_ref() {
            let key = match preview.preview_type {
                orbitdock_protocol::ApprovalPreviewType::ShellCommand => "command",
                orbitdock_protocol::ApprovalPreviewType::Url => "url",
                orbitdock_protocol::ApprovalPreviewType::SearchQuery => "query",
                orbitdock_protocol::ApprovalPreviewType::Pattern => "pattern",
                orbitdock_protocol::ApprovalPreviewType::Prompt => "prompt",
                orbitdock_protocol::ApprovalPreviewType::Diff => "diff",
                orbitdock_protocol::ApprovalPreviewType::FilePath => "file_path",
                orbitdock_protocol::ApprovalPreviewType::Value
                | orbitdock_protocol::ApprovalPreviewType::Action => "value",
            };
            payload.insert(
                key.to_string(),
                serde_json::Value::String(preview.value.clone()),
            );
        }
    }

    if payload.is_empty() {
        None
    } else {
        Some(serde_json::Value::Object(payload).to_string())
    }
}

fn parse_bool_value(value: Option<&serde_json::Value>) -> bool {
    let Some(value) = value else {
        return false;
    };
    if let Some(flag) = value.as_bool() {
        return flag;
    }
    if let Some(number) = value.as_u64() {
        return number > 0;
    }
    if let Some(text) = value.as_str() {
        let normalized = text.trim().to_ascii_lowercase();
        return normalized == "true" || normalized == "1" || normalized == "yes";
    }
    false
}

fn parse_question_options(
    payload: &serde_json::Map<String, serde_json::Value>,
) -> Vec<ApprovalQuestionOption> {
    let Some(options) = payload.get("options").and_then(serde_json::Value::as_array) else {
        return vec![];
    };

    options
        .iter()
        .filter_map(|raw_option| {
            let option = raw_option.as_object()?;
            let label = option
                .get("label")
                .or_else(|| option.get("value"))
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|text| !text.is_empty())?
                .to_string();
            let description = option
                .get("description")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(ToString::to_string);
            Some(ApprovalQuestionOption { label, description })
        })
        .collect()
}

fn parse_question_prompt(
    payload: &serde_json::Map<String, serde_json::Value>,
    fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
    let id = payload
        .get("id")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .unwrap_or(fallback_id)
        .to_string();
    let header = payload
        .get("header")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToString::to_string);
    let question = payload
        .get("question")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .unwrap_or("Question")
        .to_string();
    if question.is_empty() {
        return None;
    }

    Some(ApprovalQuestionPrompt {
        id,
        header,
        question,
        options: parse_question_options(payload),
        allows_multiple_selection: parse_bool_value(
            payload
                .get("multiSelect")
                .or_else(|| payload.get("multi_select")),
        ),
        allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
        is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
    })
}

fn extract_question_prompts(
    tool_input: Option<&str>,
    fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
    let from_tool_input: Vec<ApprovalQuestionPrompt> = tool_input
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
        .and_then(|value| value.as_object().cloned())
        .map(|payload| {
            if let Some(questions) = payload
                .get("questions")
                .and_then(serde_json::Value::as_array)
            {
                return questions
                    .iter()
                    .enumerate()
                    .filter_map(|(index, raw_question)| {
                        let prompt = raw_question.as_object()?;
                        parse_question_prompt(prompt, index.to_string().as_str())
                    })
                    .collect();
            }
            if payload.contains_key("question") || payload.contains_key("options") {
                return parse_question_prompt(&payload, "0")
                    .map(|prompt| vec![prompt])
                    .unwrap_or_default();
            }
            vec![]
        })
        .unwrap_or_default();

    if !from_tool_input.is_empty() {
        return from_tool_input;
    }

    let fallback_question = fallback_question
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToString::to_string);
    match fallback_question {
        Some(question) => vec![ApprovalQuestionPrompt {
            id: "0".to_string(),
            header: None,
            question,
            options: vec![],
            allows_multiple_selection: false,
            allows_other: true,
            is_secret: false,
        }],
        None => vec![],
    }
}

/// Lightweight, lock-free snapshot of session metadata.
/// Used by `ArcSwap` so list subscribers and snapshot readers never block
/// the actor.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct SessionSnapshot {
    pub id: String,
    pub provider: Provider,
    pub status: SessionStatus,
    pub work_status: WorkStatus,
    pub project_path: String,
    pub project_name: Option<String>,
    pub transcript_path: Option<String>,
    pub custom_name: Option<String>,
    pub summary: Option<String>,
    pub first_prompt: Option<String>,
    pub last_message: Option<String>,
    pub model: Option<String>,
    pub codex_integration_mode: Option<CodexIntegrationMode>,
    pub claude_integration_mode: Option<ClaudeIntegrationMode>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub has_pending_approval: bool,
    pub pending_tool_name: Option<String>,
    pub pending_tool_input: Option<String>,
    pub pending_question: Option<String>,
    pub pending_approval_id: Option<String>,
    pub message_count: usize,
    pub token_usage: TokenUsage,
    pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
    pub started_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub revision: u64,
    pub git_branch: Option<String>,
    pub git_sha: Option<String>,
    pub current_cwd: Option<String>,
    pub effort: Option<String>,
    pub terminal_session_id: Option<String>,
    pub terminal_app: Option<String>,
    pub approval_version: u64,
    pub repository_root: Option<String>,
    pub is_worktree: bool,
    pub worktree_id: Option<String>,
    /// Number of active WebSocket subscribers (for subscriber-gated background tasks).
    pub subscriber_count: usize,
    /// Cached count of unread messages.
    pub unread_count: u64,
}

#[derive(Debug, Clone)]
struct PendingApprovalEntry {
    request: ApprovalRequest,
    approval_type: ApprovalType,
    proposed_amendment: Option<Vec<String>>,
}

const EVENT_LOG_CAPACITY: usize = 1000;
const BROADCAST_CAPACITY: usize = 512;

/// Handle to a running session
pub struct SessionHandle {
    id: String,
    provider: Provider,
    project_path: String,
    transcript_path: Option<String>,
    project_name: Option<String>,
    model: Option<String>,
    custom_name: Option<String>,
    summary: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    codex_integration_mode: Option<CodexIntegrationMode>,
    claude_integration_mode: Option<ClaudeIntegrationMode>,
    status: SessionStatus,
    work_status: WorkStatus,
    last_tool: Option<String>,
    messages: Vec<Message>,
    token_usage: TokenUsage,
    token_usage_snapshot_kind: TokenUsageSnapshotKind,
    current_diff: Option<String>,
    current_plan: Option<String>,
    current_turn_id: Option<String>,
    turn_count: u64,
    turn_diffs: Vec<TurnDiff>,
    started_at: Option<String>,
    last_activity_at: Option<String>,
    forked_from_session_id: Option<String>,
    git_branch: Option<String>,
    git_sha: Option<String>,
    current_cwd: Option<String>,
    first_prompt: Option<String>,
    last_message: Option<String>,
    effort: Option<String>,
    terminal_session_id: Option<String>,
    terminal_app: Option<String>,
    subagents: Vec<SubagentInfo>,
    pending_approval: Option<ApprovalRequest>,
    permission_mode: Option<String>,
    pending_tool_name: Option<String>,
    pending_tool_input: Option<String>,
    pending_question: Option<String>,
    /// Persisted connector-path request_id for the current pending approval.
    /// Loaded from DB on restore so approval routing works after server restart.
    pending_approval_id: Option<String>,
    /// Server-authoritative queue of unresolved approvals for this session.
    pending_approvals: VecDeque<PendingApprovalEntry>,
    /// Monotonic counter incremented on every approval state change (enqueue, decide, clear).
    approval_version: u64,
    /// Canonical repo root (resolves worktrees to parent repo).
    repository_root: Option<String>,
    /// True if the session's cwd is inside a linked git worktree.
    is_worktree: bool,
    /// ID of the tracked worktree record (if any).
    worktree_id: Option<String>,
    /// Cached count of unread messages (non-user, non-steer with sequence > last_read).
    unread_count: u64,
    broadcast_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,
    /// Optional sender for list-level broadcasts (dashboard sidebar updates)
    list_tx: Option<broadcast::Sender<orbitdock_protocol::ServerMessage>>,
    /// Monotonic revision counter, incremented on every broadcast
    revision: u64,
    /// Ring buffer of (revision, pre-serialized JSON with revision injected)
    event_log: VecDeque<(u64, String)>,
    /// Lock-free snapshot for read-only access from outside the actor
    snapshot_handle: Arc<ArcSwap<SessionSnapshot>>,
}

impl SessionHandle {
    /// Create a new session handle
    pub fn new(id: String, provider: Provider, project_path: String) -> Self {
        let now = chrono_now();
        let (broadcast_tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        let snapshot = SessionSnapshot {
            id: id.clone(),
            provider,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            project_path: project_path.clone(),
            project_name: None,
            transcript_path: None,
            custom_name: None,
            summary: None,
            first_prompt: None,
            last_message: None,
            model: None,
            codex_integration_mode: None,
            claude_integration_mode: None,
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            has_pending_approval: false,
            pending_tool_name: None,
            pending_tool_input: None,
            pending_question: None,
            pending_approval_id: None,
            message_count: 0,
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
            started_at: Some(now.clone()),
            last_activity_at: Some(now.clone()),
            revision: 0,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            effort: None,
            terminal_session_id: None,
            terminal_app: None,
            approval_version: 0,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            subscriber_count: 0,
            unread_count: 0,
        };
        Self {
            id,
            provider,
            project_path,
            transcript_path: None,
            project_name: None,
            model: None,
            custom_name: None,
            summary: None,
            approval_policy: None,
            sandbox_mode: None,
            codex_integration_mode: None,
            claude_integration_mode: None,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            last_tool: None,
            messages: Vec::new(),
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
            current_diff: None,
            current_plan: None,
            current_turn_id: None,
            turn_count: 0,
            turn_diffs: Vec::new(),
            started_at: Some(now.clone()),
            last_activity_at: Some(now),
            forked_from_session_id: None,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            first_prompt: None,
            last_message: None,
            effort: None,
            terminal_session_id: None,
            terminal_app: None,
            subagents: Vec::new(),
            pending_approval: None,
            permission_mode: None,
            pending_tool_name: None,
            pending_tool_input: None,
            pending_question: None,
            pending_approval_id: None,
            pending_approvals: VecDeque::new(),
            approval_version: 0,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            unread_count: 0,
            broadcast_tx,
            list_tx: None,
            revision: 0,
            event_log: VecDeque::new(),
            snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
        }
    }

    /// Restore a session from the database (for server restart recovery)
    #[allow(clippy::too_many_arguments)]
    pub fn restore(
        id: String,
        provider: Provider,
        project_path: String,
        transcript_path: Option<String>,
        project_name: Option<String>,
        model: Option<String>,
        custom_name: Option<String>,
        summary: Option<String>,
        status: SessionStatus,
        work_status: WorkStatus,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        permission_mode: Option<String>,
        token_usage: TokenUsage,
        token_usage_snapshot_kind: TokenUsageSnapshotKind,
        started_at: Option<String>,
        last_activity_at: Option<String>,
        messages: Vec<Message>,
        current_diff: Option<String>,
        current_plan: Option<String>,
        turn_diffs: Vec<TurnDiff>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        current_cwd: Option<String>,
        first_prompt: Option<String>,
        last_message: Option<String>,
        pending_tool_name: Option<String>,
        pending_tool_input: Option<String>,
        pending_question: Option<String>,
        pending_approval_id: Option<String>,
        effort: Option<String>,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
        approval_version: u64,
        unread_count: u64,
    ) -> Self {
        let (broadcast_tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        let snapshot = SessionSnapshot {
            id: id.clone(),
            provider,
            status,
            work_status,
            project_path: project_path.clone(),
            project_name: project_name.clone(),
            transcript_path: transcript_path.clone(),
            custom_name: custom_name.clone(),
            summary: summary.clone(),
            model: model.clone(),
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            claude_integration_mode: None,
            approval_policy: approval_policy.clone(),
            sandbox_mode: sandbox_mode.clone(),
            permission_mode: permission_mode.clone(),
            has_pending_approval: pending_tool_name.is_some()
                || pending_question.is_some()
                || pending_approval_id.is_some(),
            pending_tool_name: pending_tool_name.clone(),
            pending_tool_input: pending_tool_input.clone(),
            pending_question: pending_question.clone(),
            pending_approval_id: pending_approval_id.clone(),
            message_count: messages.len(),
            token_usage: token_usage.clone(),
            token_usage_snapshot_kind,
            started_at: started_at.clone(),
            last_activity_at: last_activity_at.clone(),
            revision: 0,
            git_branch: git_branch.clone(),
            git_sha: git_sha.clone(),
            current_cwd: current_cwd.clone(),
            effort: effort.clone(),
            first_prompt: first_prompt.clone(),
            last_message: last_message.clone(),
            terminal_session_id: terminal_session_id.clone(),
            terminal_app: terminal_app.clone(),
            approval_version,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            subscriber_count: 0,
            unread_count,
        };
        let mut handle = Self {
            id,
            provider,
            project_path,
            transcript_path,
            project_name,
            model,
            custom_name,
            summary,
            approval_policy,
            sandbox_mode,
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            claude_integration_mode: None,
            status,
            work_status,
            last_tool: None,
            messages,
            token_usage,
            token_usage_snapshot_kind,
            current_diff,
            current_plan,
            current_turn_id: None,
            turn_count: turn_diffs.len() as u64,
            turn_diffs,
            started_at,
            last_activity_at,
            forked_from_session_id: None,
            git_branch,
            git_sha,
            current_cwd,
            first_prompt,
            last_message,
            effort,
            terminal_session_id,
            terminal_app,
            subagents: Vec::new(),
            pending_approval: None,
            permission_mode,
            pending_tool_name,
            pending_tool_input,
            pending_question,
            pending_approval_id,
            pending_approvals: VecDeque::new(),
            approval_version,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            unread_count,
            broadcast_tx,
            list_tx: None,
            revision: 0,
            event_log: VecDeque::new(),
            snapshot_handle: Arc::new(ArcSwap::from_pointee(snapshot)),
        };
        handle.bootstrap_pending_approval_from_persisted_fields();
        handle.refresh_snapshot();
        handle
    }

    /// Set the list broadcast sender (for dashboard sidebar updates)
    pub fn set_list_tx(&mut self, tx: broadcast::Sender<orbitdock_protocol::ServerMessage>) {
        self.list_tx = Some(tx);
    }

    /// Get session ID
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Get session project path
    pub fn project_path(&self) -> &str {
        &self.project_path
    }

    /// Get provider
    pub fn provider(&self) -> Provider {
        self.provider
    }

    /// Get a summary of this session
    pub fn summary(&self) -> SessionSummary {
        SessionSummary {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            transcript_path: self.transcript_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            custom_name: self.custom_name.clone(),
            summary: self.summary.clone(),
            status: self.status,
            work_status: self.work_status,
            token_usage: self.token_usage.clone(),
            token_usage_snapshot_kind: self.token_usage_snapshot_kind,
            has_pending_approval: self.pending_approval.is_some()
                || self.pending_tool_name.is_some()
                || self.pending_question.is_some()
                || self.pending_approval_id.is_some(),
            codex_integration_mode: self.codex_integration_mode,
            claude_integration_mode: self.claude_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
            permission_mode: self.permission_mode.clone(),
            pending_tool_name: self.pending_tool_name.clone(),
            pending_tool_input: self.pending_tool_input.clone(),
            pending_question: self.pending_question.clone(),
            pending_approval_id: self
                .pending_approval_id
                .clone()
                .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
            effort: self.effort.clone(),
            first_prompt: self.first_prompt.clone(),
            last_message: self.last_message.clone(),
            approval_version: Some(self.approval_version),
            repository_root: self.repository_root.clone(),
            is_worktree: self.is_worktree,
            worktree_id: self.worktree_id.clone(),
            unread_count: self.unread_count,
        }
    }

    /// Get the full session state
    pub fn state(&self) -> SessionState {
        SessionState {
            id: self.id.clone(),
            provider: self.provider,
            project_path: self.project_path.clone(),
            transcript_path: self.transcript_path.clone(),
            project_name: self.project_name.clone(),
            model: self.model.clone(),
            custom_name: self.custom_name.clone(),
            summary: self.summary.clone(),
            status: self.status,
            work_status: self.work_status,
            messages: self.messages.clone(),
            pending_approval: self.pending_approval.clone(),
            permission_mode: self.permission_mode.clone(),
            pending_tool_name: self.pending_tool_name.clone(),
            pending_tool_input: self.pending_tool_input.clone(),
            pending_question: self.pending_question.clone(),
            pending_approval_id: self
                .pending_approval_id
                .clone()
                .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
            token_usage: self.token_usage.clone(),
            token_usage_snapshot_kind: self.token_usage_snapshot_kind,
            current_diff: self.current_diff.clone(),
            current_plan: self.current_plan.clone(),
            codex_integration_mode: self.codex_integration_mode,
            claude_integration_mode: self.claude_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
            forked_from_session_id: self.forked_from_session_id.clone(),
            revision: Some(self.revision),
            current_turn_id: self.current_turn_id.clone(),
            turn_count: self.turn_count,
            turn_diffs: self.turn_diffs.clone(),
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
            first_prompt: self.first_prompt.clone(),
            last_message: self.last_message.clone(),
            subagents: self.subagents.clone(),
            effort: self.effort.clone(),
            terminal_session_id: self.terminal_session_id.clone(),
            terminal_app: self.terminal_app.clone(),
            approval_version: Some(self.approval_version),
            repository_root: self.repository_root.clone(),
            is_worktree: self.is_worktree,
            worktree_id: self.worktree_id.clone(),
            unread_count: self.unread_count,
        }
    }

    /// Get subagents
    #[allow(dead_code)]
    pub fn subagents(&self) -> &[SubagentInfo] {
        &self.subagents
    }

    /// Set subagents list
    #[allow(dead_code)]
    pub fn set_subagents(&mut self, subagents: Vec<SubagentInfo>) {
        self.subagents = subagents;
    }

    /// Subscribe to session updates
    pub fn subscribe(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
        self.broadcast_tx.subscribe()
    }

    /// Set the custom name for this session
    pub fn set_custom_name(&mut self, name: Option<String>) {
        self.custom_name = name;
        self.last_activity_at = Some(chrono_now());
    }

    /// Get custom name
    pub fn custom_name(&self) -> Option<&str> {
        self.custom_name.as_deref()
    }

    /// Set first prompt
    #[allow(dead_code)]
    pub fn set_first_prompt(&mut self, prompt: Option<String>) {
        self.first_prompt = prompt;
    }

    /// Set last message (for dashboard context lines)
    pub fn set_last_message(&mut self, message: Option<String>) {
        self.last_message = message;
    }

    /// Get messages
    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    /// Get first prompt
    #[allow(dead_code)]
    pub fn first_prompt(&self) -> Option<&str> {
        self.first_prompt.as_deref()
    }

    /// Set codex integration mode
    pub fn set_codex_integration_mode(&mut self, mode: Option<CodexIntegrationMode>) {
        self.codex_integration_mode = mode;
        self.refresh_snapshot();
    }

    /// Set claude integration mode
    pub fn set_claude_integration_mode(&mut self, mode: Option<ClaudeIntegrationMode>) {
        self.claude_integration_mode = mode;
        self.refresh_snapshot();
    }

    /// Set project name
    pub fn set_project_name(&mut self, project_name: Option<String>) {
        self.project_name = project_name;
    }

    pub fn set_git_branch(&mut self, branch: Option<String>) {
        self.git_branch = branch;
    }

    /// Set transcript path
    pub fn set_transcript_path(&mut self, transcript_path: Option<String>) {
        self.transcript_path = transcript_path;
    }

    #[allow(dead_code)]
    pub fn transcript_path(&self) -> Option<&str> {
        self.transcript_path.as_deref()
    }

    pub fn message_count(&self) -> usize {
        self.messages.len()
    }

    /// Check if a user message with this content already exists (dedup for connector echo)
    #[allow(dead_code)]
    pub fn has_user_message_with_content(&self, content: &str) -> bool {
        use orbitdock_protocol::MessageType;
        self.messages
            .iter()
            .rev()
            .take(5)
            .any(|m| m.message_type == MessageType::User && m.content == content)
    }

    /// Set model
    pub fn set_model(&mut self, model: Option<String>) {
        self.model = model;
        self.refresh_snapshot();
    }

    /// Set reasoning effort
    pub fn set_effort(&mut self, effort: Option<String>) {
        self.effort = effort;
        self.refresh_snapshot();
    }

    /// Set autonomy configuration
    pub fn set_config(&mut self, approval_policy: Option<String>, sandbox_mode: Option<String>) {
        self.approval_policy = approval_policy;
        self.sandbox_mode = sandbox_mode;
        self.refresh_snapshot();
    }

    /// Set fork origin
    pub fn set_forked_from(&mut self, source_session_id: String) {
        self.forked_from_session_id = Some(source_session_id);
    }

    /// Set terminal session ID and app
    pub fn set_terminal_info(
        &mut self,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
    ) {
        self.terminal_session_id = terminal_session_id;
        self.terminal_app = terminal_app;
    }

    /// Set worktree-related fields
    #[allow(dead_code)] // Used in Phase 6 (hook_handler enrichment)
    pub fn set_worktree_info(
        &mut self,
        repository_root: Option<String>,
        is_worktree: bool,
        worktree_id: Option<String>,
    ) {
        self.repository_root = repository_root;
        self.is_worktree = is_worktree;
        self.worktree_id = worktree_id;
    }

    #[allow(dead_code)] // Used in Phase 6+
    pub fn repository_root(&self) -> Option<&str> {
        self.repository_root.as_deref()
    }

    #[allow(dead_code)] // Used in Phase 6+
    pub fn is_worktree(&self) -> bool {
        self.is_worktree
    }

    #[allow(dead_code)] // Used in Phase 6+
    pub fn worktree_id(&self) -> Option<&str> {
        self.worktree_id.as_deref()
    }

    /// Set status
    pub fn set_status(&mut self, status: SessionStatus) {
        self.status = status;
        if status == SessionStatus::Ended {
            self.clear_pending_approvals();
        }
        self.last_activity_at = Some(chrono_now());
    }

    /// Set started_at timestamp
    pub fn set_started_at(&mut self, started_at: Option<String>) {
        self.started_at = started_at;
    }

    /// Set last_activity_at timestamp
    pub fn set_last_activity_at(&mut self, last_activity_at: Option<String>) {
        self.last_activity_at = last_activity_at;
    }

    /// Set work status
    pub fn set_work_status(&mut self, status: WorkStatus) {
        self.work_status = status;
        if status == WorkStatus::Ended {
            self.clear_pending_approvals();
        }
        self.last_activity_at = Some(chrono_now());
    }

    /// Get work status
    pub fn work_status(&self) -> WorkStatus {
        self.work_status
    }

    /// Set last tool name
    pub fn set_last_tool(&mut self, tool: Option<String>) {
        self.last_tool = tool;
        self.last_activity_at = Some(chrono_now());
    }

    /// Get last tool name
    pub fn last_tool(&self) -> Option<&str> {
        self.last_tool.as_deref()
    }

    /// Update token usage
    #[allow(dead_code)]
    pub fn update_tokens(&mut self, usage: TokenUsage) {
        self.token_usage = usage;
    }

    /// Add a message
    pub fn add_message(&mut self, message: Message) {
        if !matches!(
            message.message_type,
            orbitdock_protocol::MessageType::User | orbitdock_protocol::MessageType::Steer
        ) {
            self.unread_count += 1;
        }
        self.messages.push(message);
        self.last_activity_at = Some(chrono_now());
    }

    /// Mark the session as fully read. Returns the previous unread count.
    pub fn mark_read(&mut self) -> u64 {
        let prev = self.unread_count;
        self.unread_count = 0;
        prev
    }

    /// Get current unread count
    pub fn unread_count(&self) -> u64 {
        self.unread_count
    }

    /// Replace all messages (used for snapshot hydration from transcript fallback)
    pub fn replace_messages(&mut self, messages: Vec<Message>) {
        self.messages = messages;
    }

    /// Update aggregated diff
    #[allow(dead_code)]
    pub fn update_diff(&mut self, diff: String) {
        self.current_diff = Some(diff);
    }

    /// Update plan
    #[allow(dead_code)]
    pub fn update_plan(&mut self, plan: String) {
        self.current_plan = Some(plan);
    }

    fn inferred_approval_type_from_pending_fields(&self) -> ApprovalType {
        if self.pending_question.is_some() {
            return ApprovalType::Question;
        }
        if let Some(tool_name) = self.pending_tool_name.as_ref() {
            let normalized = tool_name.to_ascii_lowercase();
            if normalized.contains("edit")
                || normalized.contains("patch")
                || normalized.contains("write")
            {
                return ApprovalType::Patch;
            }
        }
        ApprovalType::Exec
    }

    fn work_status_for_approval_type(approval_type: ApprovalType) -> WorkStatus {
        match approval_type {
            ApprovalType::Question => WorkStatus::Question,
            ApprovalType::Exec | ApprovalType::Patch => WorkStatus::Permission,
        }
    }

    /// Get the current approval version.
    pub fn approval_version(&self) -> u64 {
        self.approval_version
    }

    fn queue_pending_approval(
        &mut self,
        approval: ApprovalRequest,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    ) {
        let normalized_request_id = normalize_request_id(&approval.id).to_string();
        if let Some(index) = self
            .pending_approvals
            .iter()
            .position(|entry| normalize_request_id(&entry.request.id) == normalized_request_id)
        {
            if let Some(existing) = self.pending_approvals.get_mut(index) {
                existing.request = approval;
                existing.approval_type = approval_type;
                existing.proposed_amendment = proposed_amendment;
            }
            // Update in place — still bump version since state changed.
            self.approval_version += 1;
            info!(
                component = "approval",
                event = "approval.updated",
                session_id = %self.id,
                request_id = %normalized_request_id,
                approval_version = self.approval_version,
                approval_type = ?approval_type,
                queue_depth = self.pending_approvals.len(),
                "Approval request updated in place"
            );
            return;
        }

        self.pending_approvals.push_back(PendingApprovalEntry {
            request: approval,
            approval_type,
            proposed_amendment,
        });
        self.approval_version += 1;
        info!(
            component = "approval",
            event = "approval.enqueued",
            session_id = %self.id,
            request_id = %normalized_request_id,
            approval_version = self.approval_version,
            approval_type = ?approval_type,
            queue_depth = self.pending_approvals.len(),
            "Approval request enqueued"
        );
    }

    fn promote_queue_front(&mut self) {
        if let Some(entry) = self.pending_approvals.front() {
            self.pending_approval = Some(entry.request.clone());
            self.pending_tool_name = fallback_tool_name(&entry.request);
            self.pending_tool_input = fallback_tool_input(&entry.request);
            self.pending_question = entry.request.question.clone();
            self.pending_approval_id = Some(entry.request.id.clone());
            self.work_status = Self::work_status_for_approval_type(entry.approval_type);
            info!(
                component = "approval",
                event = "approval.promoted",
                session_id = %self.id,
                request_id = %entry.request.id,
                approval_version = self.approval_version,
                approval_type = ?entry.approval_type,
                queue_depth = self.pending_approvals.len(),
                "Promoted next approval to active"
            );
            return;
        }

        self.pending_approval = None;
        self.pending_tool_name = None;
        self.pending_tool_input = None;
        self.pending_question = None;
        self.pending_approval_id = None;
    }

    fn clear_pending_approvals(&mut self) {
        let had_approvals = !self.pending_approvals.is_empty() || self.pending_approval.is_some();
        let cleared_count = self.pending_approvals.len();
        self.pending_approvals.clear();
        self.pending_approval = None;
        self.pending_tool_name = None;
        self.pending_tool_input = None;
        self.pending_question = None;
        self.pending_approval_id = None;
        if had_approvals {
            self.approval_version += 1;
            info!(
                component = "approval",
                event = "approval.cleared",
                session_id = %self.id,
                approval_version = self.approval_version,
                cleared_count,
                "Cleared all pending approvals"
            );
        }
    }

    fn bootstrap_pending_approval_from_persisted_fields(&mut self) {
        if self.pending_approvals.is_empty() {
            if let Some(request_id) = self.pending_approval_id.clone() {
                let approval_type = self.inferred_approval_type_from_pending_fields();
                let approval = ApprovalRequest {
                    id: request_id,
                    session_id: self.id.clone(),
                    approval_type,
                    tool_name: self.pending_tool_name.clone(),
                    tool_input: self.pending_tool_input.clone(),
                    command: None,
                    file_path: None,
                    diff: None,
                    question: self.pending_question.clone(),
                    question_prompts: extract_question_prompts(
                        self.pending_tool_input.as_deref(),
                        self.pending_question.as_deref(),
                    ),
                    preview: None,
                    proposed_amendment: None,
                };
                self.queue_pending_approval(approval, approval_type, None);
                self.promote_queue_front();
            }
        }
    }

    /// Register a pending approval with optional proposed amendment and tool metadata.
    pub fn set_pending_approval(
        &mut self,
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
        tool_name: Option<String>,
        tool_input: Option<String>,
        question: Option<String>,
    ) {
        let question_prompts = parse_question_prompts(tool_input.as_deref());
        let resolved_question = question.or_else(|| {
            question_prompts
                .first()
                .map(|p| p.question.clone())
                .filter(|t| !t.is_empty())
        });
        let request = ApprovalRequest {
            id: request_id,
            session_id: self.id.clone(),
            approval_type,
            tool_name,
            tool_input,
            command: None,
            file_path: None,
            diff: None,
            question: resolved_question,
            question_prompts,
            preview: None,
            proposed_amendment: proposed_amendment.clone(),
        };
        self.queue_pending_approval(request, approval_type, proposed_amendment);
        self.promote_queue_front();
    }

    /// Resolve a pending approval request and promote the next queued request.
    pub fn resolve_pending_approval(
        &mut self,
        request_id: &str,
        fallback_work_status: WorkStatus,
    ) -> (
        Option<ApprovalType>,
        Option<Vec<String>>,
        Option<ApprovalRequest>,
        WorkStatus,
    ) {
        let Some(head) = self.pending_approvals.front() else {
            return (None, None, self.pending_approval.clone(), self.work_status);
        };
        if normalize_request_id(&head.request.id) != normalize_request_id(request_id) {
            return (None, None, self.pending_approval.clone(), self.work_status);
        }

        let removed = self
            .pending_approvals
            .pop_front()
            .expect("pending approval queue should have head entry");
        let removed_request_id = normalize_request_id(&removed.request.id);
        while matches!(
            self.pending_approvals.front(),
            Some(entry) if normalize_request_id(&entry.request.id) == removed_request_id
        ) {
            let _ = self.pending_approvals.pop_front();
        }
        self.approval_version += 1;
        info!(
            component = "approval",
            event = "approval.decided",
            session_id = %self.id,
            request_id = %removed.request.id,
            approval_version = self.approval_version,
            approval_type = ?removed.approval_type,
            queue_depth = self.pending_approvals.len(),
            "Approval decided and removed from queue"
        );
        self.promote_queue_front();
        if self.pending_approvals.is_empty() {
            self.work_status = fallback_work_status;
        }

        (
            Some(removed.approval_type),
            removed.proposed_amendment,
            self.pending_approval.clone(),
            self.work_status,
        )
    }

    /// Apply a `StateChanges` delta to the handle fields.
    /// Each `Some` field overwrites the corresponding handle field.
    pub fn apply_changes(&mut self, changes: &StateChanges) {
        if let Some(status) = changes.status {
            self.status = status;
        }
        if let Some(work_status) = changes.work_status {
            self.work_status = work_status;
        }
        if let Some(ref pending_approval) = changes.pending_approval {
            if let Some(approval) = pending_approval.as_ref() {
                self.queue_pending_approval(
                    approval.clone(),
                    approval.approval_type,
                    approval.proposed_amendment.clone(),
                );
            } else {
                self.clear_pending_approvals();
            }
        }
        if let Some(ref custom_name) = changes.custom_name {
            self.custom_name = custom_name.clone();
        }
        if let Some(ref summary) = changes.summary {
            self.summary = summary.clone();
        }
        if let Some(ref model) = changes.model {
            self.model = model.clone();
        }
        if let Some(ref approval_policy) = changes.approval_policy {
            self.approval_policy = approval_policy.clone();
        }
        if let Some(ref sandbox_mode) = changes.sandbox_mode {
            self.sandbox_mode = sandbox_mode.clone();
        }
        if let Some(ref permission_mode) = changes.permission_mode {
            self.permission_mode = permission_mode.clone();
        }
        if let Some(ref codex_integration_mode) = changes.codex_integration_mode {
            self.codex_integration_mode = *codex_integration_mode;
        }
        if let Some(ref claude_integration_mode) = changes.claude_integration_mode {
            self.claude_integration_mode = *claude_integration_mode;
        }
        if let Some(ref last_activity_at) = changes.last_activity_at {
            self.last_activity_at = Some(last_activity_at.clone());
        }
        if let Some(ref token_usage) = changes.token_usage {
            self.token_usage = token_usage.clone();
        }
        if let Some(snapshot_kind) = changes.token_usage_snapshot_kind {
            self.token_usage_snapshot_kind = snapshot_kind;
        }
        if let Some(ref current_diff) = changes.current_diff {
            self.current_diff = current_diff.clone();
        }
        if let Some(ref current_plan) = changes.current_plan {
            self.current_plan = current_plan.clone();
        }
        if let Some(ref current_turn_id) = changes.current_turn_id {
            self.current_turn_id = current_turn_id.clone();
        }
        if let Some(turn_count) = changes.turn_count {
            self.turn_count = turn_count;
        }
        if let Some(ref git_branch) = changes.git_branch {
            self.git_branch = git_branch.clone();
        }
        if let Some(ref git_sha) = changes.git_sha {
            self.git_sha = git_sha.clone();
        }
        if let Some(ref current_cwd) = changes.current_cwd {
            self.current_cwd = current_cwd.clone();
        }
        if let Some(ref first_prompt) = changes.first_prompt {
            self.first_prompt = first_prompt.clone();
        }
        if let Some(ref last_message) = changes.last_message {
            self.last_message = last_message.clone();
        }
        if let Some(ref effort) = changes.effort {
            self.effort = effort.clone();
        }

        if self.status == SessionStatus::Ended || self.work_status == WorkStatus::Ended {
            self.clear_pending_approvals();
        } else if !self.pending_approvals.is_empty() {
            self.promote_queue_front();
        } else if !matches!(
            self.work_status,
            WorkStatus::Permission | WorkStatus::Question
        ) {
            self.pending_approval = None;
            self.pending_tool_name = None;
            self.pending_tool_input = None;
            self.pending_question = None;
            self.pending_approval_id = None;
        }
    }

    /// Create a snapshot of current session metadata
    pub fn to_snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            id: self.id.clone(),
            provider: self.provider,
            status: self.status,
            work_status: self.work_status,
            project_path: self.project_path.clone(),
            project_name: self.project_name.clone(),
            transcript_path: self.transcript_path.clone(),
            custom_name: self.custom_name.clone(),
            summary: self.summary.clone(),
            model: self.model.clone(),
            codex_integration_mode: self.codex_integration_mode,
            claude_integration_mode: self.claude_integration_mode,
            approval_policy: self.approval_policy.clone(),
            sandbox_mode: self.sandbox_mode.clone(),
            permission_mode: self.permission_mode.clone(),
            has_pending_approval: self.pending_approval.is_some()
                || self.pending_tool_name.is_some()
                || self.pending_question.is_some()
                || self.pending_approval_id.is_some(),
            pending_tool_name: self.pending_tool_name.clone(),
            pending_tool_input: self.pending_tool_input.clone(),
            pending_question: self.pending_question.clone(),
            pending_approval_id: self
                .pending_approval_id
                .clone()
                .or_else(|| self.pending_approval.as_ref().map(|a| a.id.clone())),
            message_count: self.messages.len(),
            token_usage: self.token_usage.clone(),
            token_usage_snapshot_kind: self.token_usage_snapshot_kind,
            started_at: self.started_at.clone(),
            last_activity_at: self.last_activity_at.clone(),
            revision: self.revision,
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
            effort: self.effort.clone(),
            first_prompt: self.first_prompt.clone(),
            last_message: self.last_message.clone(),
            terminal_session_id: self.terminal_session_id.clone(),
            terminal_app: self.terminal_app.clone(),
            approval_version: self.approval_version,
            repository_root: self.repository_root.clone(),
            is_worktree: self.is_worktree,
            worktree_id: self.worktree_id.clone(),
            subscriber_count: self.broadcast_tx.receiver_count(),
            unread_count: self.unread_count,
        }
    }

    /// Update the ArcSwap snapshot (call after mutations)
    pub fn refresh_snapshot(&self) {
        self.snapshot_handle.store(Arc::new(self.to_snapshot()));
    }

    /// Get the ArcSwap handle for lock-free reads
    pub fn snapshot_arc(&self) -> Arc<ArcSwap<SessionSnapshot>> {
        self.snapshot_handle.clone()
    }

    /// Broadcast a message to all subscribers
    pub fn broadcast(&mut self, msg: orbitdock_protocol::ServerMessage) {
        self.revision += 1;
        let rev = self.revision;

        // Pre-serialize with revision for event log
        if let Ok(json) = serialize_with_revision(&msg, rev) {
            self.event_log.push_back((rev, json));
            if self.event_log.len() > EVENT_LOG_CAPACITY {
                self.event_log.pop_front();
            }
        }

        // Non-blocking fan-out to all receivers
        let _ = self.broadcast_tx.send(msg.clone());

        // Forward session-level events to list subscribers (dashboard sidebar).
        // Per-message events (streaming deltas, message appends, etc.) are too
        // frequent and overflow the list channel during active turns.
        if let Some(ref list_tx) = self.list_tx {
            if is_list_relevant(&msg) {
                let _ = list_tx.send(msg);
            }
        }

        // Update lock-free snapshot
        self.refresh_snapshot();
    }

    /// Replay events since a given revision.
    /// Returns `None` if the gap is too large (caller should send full snapshot).
    pub fn replay_since(&self, since_revision: u64) -> Option<Vec<String>> {
        let oldest = self.event_log.front().map(|(rev, _)| *rev)?;
        if oldest > since_revision + 1 {
            return None; // Gap too large, need full snapshot
        }
        let events: Vec<String> = self
            .event_log
            .iter()
            .filter(|(rev, _)| *rev > since_revision)
            .map(|(_, json)| json.clone())
            .collect();
        Some(events)
    }

    // -- Transition bridge (temporary until Phase 4 actor model) ---------------

    /// Extract a pure data snapshot for the transition function
    pub fn extract_state(&self) -> TransitionState {
        let phase = if let Some(entry) = self.pending_approvals.front() {
            WorkPhase::AwaitingApproval {
                request_id: entry.request.id.clone(),
                approval_type: entry.approval_type,
                proposed_amendment: entry.proposed_amendment.clone(),
            }
        } else {
            match self.work_status {
                WorkStatus::Working => WorkPhase::Working,
                WorkStatus::Permission => WorkPhase::AwaitingApproval {
                    request_id: String::new(),
                    approval_type: ApprovalType::Exec,
                    proposed_amendment: None,
                },
                WorkStatus::Question => WorkPhase::AwaitingApproval {
                    request_id: String::new(),
                    approval_type: ApprovalType::Question,
                    proposed_amendment: None,
                },
                WorkStatus::Ended => WorkPhase::Ended {
                    reason: String::new(),
                },
                _ => WorkPhase::Idle,
            }
        };

        TransitionState {
            id: self.id.clone(),
            revision: self.revision,
            phase,
            messages: self.messages.clone(),
            token_usage: self.token_usage.clone(),
            token_usage_snapshot_kind: self.token_usage_snapshot_kind,
            current_diff: self.current_diff.clone(),
            current_plan: self.current_plan.clone(),
            custom_name: self.custom_name.clone(),
            project_path: self.project_path.clone(),
            last_activity_at: self.last_activity_at.clone(),
            current_turn_id: self.current_turn_id.clone(),
            turn_count: self.turn_count,
            turn_diffs: self.turn_diffs.clone(),
            git_branch: self.git_branch.clone(),
            git_sha: self.git_sha.clone(),
            current_cwd: self.current_cwd.clone(),
            pending_approval: self.pending_approval.clone(),
            repository_root: self.repository_root.clone(),
            is_worktree: self.is_worktree,
        }
    }

    /// Apply the transition result back to this handle
    pub fn apply_state(&mut self, state: TransitionState) {
        let phase = state.phase.clone();
        self.work_status = phase.to_work_status();
        self.messages = state.messages;
        self.token_usage = state.token_usage;
        self.token_usage_snapshot_kind = state.token_usage_snapshot_kind;
        self.current_diff = state.current_diff;
        self.current_plan = state.current_plan;
        self.custom_name = state.custom_name;
        self.last_activity_at = state.last_activity_at;
        self.current_turn_id = state.current_turn_id;
        self.turn_count = state.turn_count;
        self.turn_diffs = state.turn_diffs;
        self.git_branch = state.git_branch;
        self.git_sha = state.git_sha;
        self.current_cwd = state.current_cwd;
        self.repository_root = state.repository_root;
        self.is_worktree = state.is_worktree;

        if let Some(approval) = state.pending_approval {
            let (approval_type, proposed_amendment) = match &phase {
                WorkPhase::AwaitingApproval {
                    approval_type,
                    proposed_amendment,
                    ..
                } => (*approval_type, proposed_amendment.clone()),
                _ => (approval.approval_type, approval.proposed_amendment.clone()),
            };
            self.queue_pending_approval(approval, approval_type, proposed_amendment);
        }

        if matches!(phase, WorkPhase::Ended { .. }) {
            self.clear_pending_approvals();
        } else if !self.pending_approvals.is_empty() {
            self.promote_queue_front();
        } else if !matches!(
            self.work_status,
            WorkStatus::Permission | WorkStatus::Question
        ) {
            self.pending_approval = None;
            self.pending_tool_name = None;
            self.pending_tool_input = None;
            self.pending_question = None;
            self.pending_approval_id = None;
        }

        self.refresh_snapshot();
    }
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::*;
    use crate::transition::WorkPhase;
    use orbitdock_protocol::Provider;

    fn approval_request(
        session_id: &str,
        request_id: &str,
        approval_type: ApprovalType,
    ) -> ApprovalRequest {
        ApprovalRequest {
            id: request_id.to_string(),
            session_id: session_id.to_string(),
            approval_type,
            tool_name: Some("Bash".to_string()),
            tool_input: Some("{\"command\":\"echo hi\"}".to_string()),
            command: Some("echo hi".to_string()),
            file_path: None,
            diff: None,
            question: None,
            question_prompts: vec![],
            preview: None,
            proposed_amendment: None,
        }
    }

    fn apply_approval_event(
        handle: &mut SessionHandle,
        request_id: &str,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    ) {
        let mut state = handle.extract_state();
        state.phase = WorkPhase::AwaitingApproval {
            request_id: request_id.to_string(),
            approval_type,
            proposed_amendment: proposed_amendment.clone(),
        };
        let mut request = approval_request(handle.id(), request_id, approval_type);
        request.proposed_amendment = proposed_amendment;
        state.pending_approval = Some(request);
        handle.apply_state(state);
    }

    #[test]
    fn resolve_pending_approval_promotes_next_request() {
        let mut handle = SessionHandle::new(
            "session-queue".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );

        apply_approval_event(&mut handle, "req-1", ApprovalType::Exec, None);
        apply_approval_event(
            &mut handle,
            "req-2",
            ApprovalType::Patch,
            Some(vec!["git add .".to_string()]),
        );

        let (approval_type, proposed_amendment, next_pending, work_status) =
            handle.resolve_pending_approval("req-1", WorkStatus::Working);

        assert_eq!(approval_type, Some(ApprovalType::Exec));
        assert_eq!(
            proposed_amendment, None,
            "first request should not inherit amendment from queued entries"
        );
        assert_eq!(
            next_pending.as_ref().map(|approval| approval.id.as_str()),
            Some("req-2")
        );
        assert_eq!(work_status, WorkStatus::Permission);

        let state = handle.state();
        assert_eq!(state.pending_approval_id.as_deref(), Some("req-2"));
        assert_eq!(
            state
                .pending_approval
                .as_ref()
                .map(|approval| approval.id.as_str()),
            Some("req-2")
        );
    }

    #[test]
    fn resolve_pending_approval_returns_fallback_when_queue_is_empty() {
        let mut handle = SessionHandle::new(
            "session-empty".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );

        apply_approval_event(&mut handle, "req-only", ApprovalType::Question, None);

        let (approval_type, proposed_amendment, next_pending, work_status) =
            handle.resolve_pending_approval("req-only", WorkStatus::Waiting);

        assert_eq!(approval_type, Some(ApprovalType::Question));
        assert_eq!(proposed_amendment, None);
        assert!(next_pending.is_none());
        assert_eq!(work_status, WorkStatus::Waiting);

        let state = handle.state();
        assert_eq!(state.pending_approval_id, None);
        assert!(state.pending_approval.is_none());
    }

    #[test]
    fn apply_state_keeps_oldest_pending_request_at_queue_head() {
        let mut handle = SessionHandle::new(
            "session-order".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );

        apply_approval_event(&mut handle, "req-first", ApprovalType::Exec, None);
        apply_approval_event(&mut handle, "req-second", ApprovalType::Exec, None);

        let state = handle.state();
        assert_eq!(
            state.pending_approval_id.as_deref(),
            Some("req-first"),
            "new approvals should queue behind the current head"
        );
        assert_eq!(
            state
                .pending_approval
                .as_ref()
                .map(|approval| approval.id.as_str()),
            Some("req-first")
        );
    }

    #[test]
    fn resolve_pending_approval_requires_queue_head_request_id() {
        let mut handle = SessionHandle::new(
            "session-head-only".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );

        apply_approval_event(&mut handle, "req-1", ApprovalType::Exec, None);
        apply_approval_event(&mut handle, "req-2", ApprovalType::Exec, None);

        let (approval_type, proposed_amendment, next_pending, work_status) =
            handle.resolve_pending_approval("req-2", WorkStatus::Working);

        assert!(approval_type.is_none());
        assert!(proposed_amendment.is_none());
        assert_eq!(
            next_pending.as_ref().map(|approval| approval.id.as_str()),
            Some("req-1")
        );
        assert_eq!(work_status, WorkStatus::Permission);

        let state = handle.state();
        assert_eq!(state.pending_approval_id.as_deref(), Some("req-1"));
    }

    #[test]
    fn resolve_pending_approval_drops_duplicate_entries_for_same_request_id() {
        let mut handle = SessionHandle::new(
            "session-duplicate-head".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );

        apply_approval_event(&mut handle, "req-1", ApprovalType::Exec, None);
        handle.pending_approvals.push_back(PendingApprovalEntry {
            request: approval_request(handle.id(), "req-1", ApprovalType::Exec),
            approval_type: ApprovalType::Exec,
            proposed_amendment: None,
        });
        apply_approval_event(&mut handle, "req-2", ApprovalType::Exec, None);

        let (approval_type, proposed_amendment, next_pending, work_status) =
            handle.resolve_pending_approval("req-1", WorkStatus::Working);

        assert_eq!(approval_type, Some(ApprovalType::Exec));
        assert_eq!(proposed_amendment, None);
        assert_eq!(
            next_pending.as_ref().map(|approval| approval.id.as_str()),
            Some("req-2")
        );
        assert_eq!(work_status, WorkStatus::Permission);

        let state = handle.state();
        assert_eq!(state.pending_approval_id.as_deref(), Some("req-2"));
    }
}

/// Serialize a ServerMessage with a revision field injected at the top level
fn serialize_with_revision(
    msg: &orbitdock_protocol::ServerMessage,
    revision: u64,
) -> Result<String, serde_json::Error> {
    let mut val = serde_json::to_value(msg)?;
    if let Some(obj) = val.as_object_mut() {
        obj.insert("revision".to_string(), serde_json::json!(revision));
    }
    serde_json::to_string(&val)
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    // Using a simple format for now
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}Z", duration.as_secs())
}

fn normalize_request_id(value: &str) -> &str {
    value.trim()
}

/// Parse question prompts from serialized tool_input JSON (AskUserQuestion).
fn parse_question_prompts(tool_input: Option<&str>) -> Vec<ApprovalQuestionPrompt> {
    let input = match tool_input.and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok()) {
        Some(v) => v,
        None => return vec![],
    };

    let questions = match input.get("questions").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return vec![],
    };

    questions
        .iter()
        .enumerate()
        .map(|(i, q)| {
            let options = q
                .get("options")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .map(|o| ApprovalQuestionOption {
                            label: o
                                .get("label")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                            description: o
                                .get("description")
                                .and_then(|v| v.as_str())
                                .map(String::from),
                        })
                        .collect()
                })
                .unwrap_or_default();

            ApprovalQuestionPrompt {
                id: q
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                header: q.get("header").and_then(|v| v.as_str()).map(String::from),
                question: q
                    .get("question")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                    .unwrap_or_else(|| format!("Question {}", i + 1)),
                options,
                allows_multiple_selection: q
                    .get("multiSelect")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
                allows_other: true, // SDK always adds "Other" option
                is_secret: false,
            }
        })
        .collect()
}
