//! Pure state transition function
//!
//! All business logic for session state changes lives here as a pure,
//! synchronous function: `transition(state, input) -> (state, effects)`.
//! No IO, no async, no locking — fully unit-testable.

use std::collections::HashMap;
use std::path::Path;

use orbitdock_connectors::{ApprovalType as ConnectorApprovalType, ConnectorEvent};
use orbitdock_protocol::{
    ApprovalPreview, ApprovalPreviewSegment, ApprovalPreviewType, ApprovalRequest, ApprovalType,
    McpAuthStatus, McpResource, McpResourceTemplate, McpStartupFailure, McpStartupStatus, McpTool,
    Message, MessageChanges, MessageType, RemoteSkillSummary, ServerMessage, SessionStatus,
    SkillErrorInfo, SkillsListEntry, StateChanges, TokenUsage, TurnDiff, WorkStatus,
};
use serde_json::{Map as JsonMap, Value as JsonValue};

// ---------------------------------------------------------------------------
// WorkPhase — internal state machine (maps to WorkStatus for the wire)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkPhase {
    Idle,
    Working,
    AwaitingApproval {
        request_id: String,
        approval_type: ApprovalType,
        proposed_amendment: Option<Vec<String>>,
    },
    Ended {
        reason: String,
    },
}

impl WorkPhase {
    pub fn to_work_status(&self) -> WorkStatus {
        match self {
            WorkPhase::Idle => WorkStatus::Waiting,
            WorkPhase::Working => WorkStatus::Working,
            WorkPhase::AwaitingApproval { approval_type, .. } => match approval_type {
                ApprovalType::Question => WorkStatus::Question,
                _ => WorkStatus::Permission,
            },
            WorkPhase::Ended { .. } => WorkStatus::Ended,
        }
    }
}

// ---------------------------------------------------------------------------
// TransitionState — pure data snapshot of a session
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TransitionState {
    pub id: String,
    pub revision: u64,
    pub phase: WorkPhase,
    pub messages: Vec<Message>,
    pub token_usage: TokenUsage,
    pub current_diff: Option<String>,
    pub current_plan: Option<String>,
    pub custom_name: Option<String>,
    pub project_path: String,
    pub last_activity_at: Option<String>,
    pub current_turn_id: Option<String>,
    pub turn_count: u64,
    pub turn_diffs: Vec<TurnDiff>,
    pub git_branch: Option<String>,
    pub git_sha: Option<String>,
    pub current_cwd: Option<String>,
    pub pending_approval: Option<ApprovalRequest>,
}

// ---------------------------------------------------------------------------
// Input — one variant per ConnectorEvent
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum Input {
    TurnStarted,
    TurnCompleted,
    TurnAborted {
        reason: String,
    },
    MessageCreated(Message),
    MessageUpdated {
        message_id: String,
        content: Option<String>,
        tool_output: Option<String>,
        is_error: Option<bool>,
        duration_ms: Option<u64>,
    },
    ApprovalRequested {
        request_id: String,
        approval_type: ApprovalType,
        tool_name: Option<String>,
        tool_input: Option<String>,
        command: Option<String>,
        file_path: Option<String>,
        diff: Option<String>,
        question: Option<String>,
        proposed_amendment: Option<Vec<String>>,
    },
    TokensUpdated(TokenUsage),
    DiffUpdated(String),
    PlanUpdated(String),
    ThreadNameUpdated(String),
    SessionEnded {
        reason: String,
    },
    SkillsList {
        skills: Vec<SkillsListEntry>,
        errors: Vec<SkillErrorInfo>,
    },
    RemoteSkillsList {
        skills: Vec<RemoteSkillSummary>,
    },
    RemoteSkillDownloaded {
        id: String,
        name: String,
        path: String,
    },
    SkillsUpdateAvailable,
    McpToolsList {
        tools: HashMap<String, McpTool>,
        resources: HashMap<String, Vec<McpResource>>,
        resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
        auth_statuses: HashMap<String, McpAuthStatus>,
    },
    McpStartupUpdate {
        server: String,
        status: McpStartupStatus,
    },
    McpStartupComplete {
        ready: Vec<String>,
        failed: Vec<McpStartupFailure>,
        cancelled: Vec<String>,
    },
    ClaudeInitialized {
        slash_commands: Vec<String>,
        skills: Vec<String>,
        tools: Vec<String>,
        models: Vec<orbitdock_protocol::ClaudeModelOption>,
    },
    ModelUpdated(String),
    ContextCompacted,
    UndoStarted {
        message: Option<String>,
    },
    UndoCompleted {
        success: bool,
        message: Option<String>,
    },
    ThreadRolledBack {
        num_turns: u32,
    },
    EnvironmentChanged {
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
    },
    Error(String),
}

impl From<ConnectorEvent> for Input {
    fn from(event: ConnectorEvent) -> Self {
        match event {
            ConnectorEvent::TurnStarted => Input::TurnStarted,
            ConnectorEvent::TurnCompleted => Input::TurnCompleted,
            ConnectorEvent::TurnAborted { reason } => Input::TurnAborted { reason },
            ConnectorEvent::MessageCreated(msg) => Input::MessageCreated(msg),
            ConnectorEvent::MessageUpdated {
                message_id,
                content,
                tool_output,
                is_error,
                duration_ms,
            } => Input::MessageUpdated {
                message_id,
                content,
                tool_output,
                is_error,
                duration_ms,
            },
            ConnectorEvent::ApprovalRequested {
                request_id,
                approval_type,
                tool_name,
                tool_input,
                command,
                file_path,
                diff,
                question,
                proposed_amendment,
            } => Input::ApprovalRequested {
                request_id,
                approval_type: match approval_type {
                    ConnectorApprovalType::Exec => ApprovalType::Exec,
                    ConnectorApprovalType::Patch => ApprovalType::Patch,
                    ConnectorApprovalType::Question => ApprovalType::Question,
                },
                tool_name,
                tool_input,
                command,
                file_path,
                diff,
                question,
                proposed_amendment,
            },
            ConnectorEvent::TokensUpdated(usage) => Input::TokensUpdated(usage),
            ConnectorEvent::DiffUpdated(diff) => Input::DiffUpdated(diff),
            ConnectorEvent::PlanUpdated(plan) => Input::PlanUpdated(plan),
            ConnectorEvent::ThreadNameUpdated(name) => Input::ThreadNameUpdated(name),
            ConnectorEvent::SessionEnded { reason } => Input::SessionEnded { reason },
            ConnectorEvent::SkillsList { skills, errors } => Input::SkillsList { skills, errors },
            ConnectorEvent::RemoteSkillsList { skills } => Input::RemoteSkillsList { skills },
            ConnectorEvent::RemoteSkillDownloaded { id, name, path } => {
                Input::RemoteSkillDownloaded { id, name, path }
            }
            ConnectorEvent::SkillsUpdateAvailable => Input::SkillsUpdateAvailable,
            ConnectorEvent::McpToolsList {
                tools,
                resources,
                resource_templates,
                auth_statuses,
            } => Input::McpToolsList {
                tools,
                resources,
                resource_templates,
                auth_statuses,
            },
            ConnectorEvent::McpStartupUpdate { server, status } => {
                Input::McpStartupUpdate { server, status }
            }
            ConnectorEvent::McpStartupComplete {
                ready,
                failed,
                cancelled,
            } => Input::McpStartupComplete {
                ready,
                failed,
                cancelled,
            },
            ConnectorEvent::ClaudeInitialized {
                slash_commands,
                skills,
                tools,
                models,
            } => Input::ClaudeInitialized {
                slash_commands,
                skills,
                tools,
                models,
            },
            ConnectorEvent::ModelUpdated(model) => Input::ModelUpdated(model),
            ConnectorEvent::ContextCompacted => Input::ContextCompacted,
            ConnectorEvent::UndoStarted { message } => Input::UndoStarted { message },
            ConnectorEvent::UndoCompleted { success, message } => {
                Input::UndoCompleted { success, message }
            }
            ConnectorEvent::ThreadRolledBack { num_turns } => Input::ThreadRolledBack { num_turns },
            ConnectorEvent::EnvironmentChanged {
                cwd,
                git_branch,
                git_sha,
            } => Input::EnvironmentChanged {
                cwd,
                git_branch,
                git_sha,
            },
            ConnectorEvent::Error(msg) => Input::Error(msg),
            // Handled in event loop before reaching transitions
            ConnectorEvent::HookSessionId(_) => unreachable!(),
        }
    }
}

// ---------------------------------------------------------------------------
// Effects — describe IO to be executed by the caller
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum Effect {
    Persist(Box<PersistOp>),
    Emit(Box<ServerMessage>),
}

#[derive(Debug, Clone)]
pub enum PersistOp {
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
    },
    SessionEnd {
        id: String,
        reason: String,
    },
    MessageAppend {
        session_id: String,
        message: Message,
    },
    MessageUpdate {
        session_id: String,
        message_id: String,
        content: Option<String>,
        tool_output: Option<String>,
        duration_ms: Option<u64>,
        is_error: Option<bool>,
    },
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
    },
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },
    TurnDiffInsert {
        session_id: String,
        turn_id: String,
        diff: String,
        input_tokens: u64,
        output_tokens: u64,
        cached_tokens: u64,
        context_window: u64,
    },
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },
    ApprovalRequested {
        session_id: String,
        request_id: String,
        approval_type: ApprovalType,
        tool_name: Option<String>,
        command: Option<String>,
        file_path: Option<String>,
        cwd: Option<String>,
        proposed_amendment: Option<Vec<String>>,
    },
    EnvironmentUpdate {
        session_id: String,
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
    },
    ToolCountIncrement {
        session_id: String,
    },
    ModelUpdate {
        session_id: String,
        model: String,
    },
    SaveClaudeModels {
        models: Vec<orbitdock_protocol::ClaudeModelOption>,
    },
}

impl PersistOp {
    /// Convert to the existing PersistCommand used by the persistence layer
    pub fn into_persist_command(self) -> crate::persistence::PersistCommand {
        use crate::persistence::PersistCommand;
        match self {
            PersistOp::SessionUpdate {
                id,
                status,
                work_status,
                last_activity_at,
            } => PersistCommand::SessionUpdate {
                id,
                status,
                work_status,
                last_activity_at,
            },
            PersistOp::SessionEnd { id, reason } => PersistCommand::SessionEnd { id, reason },
            PersistOp::MessageAppend {
                session_id,
                message,
            } => PersistCommand::MessageAppend {
                session_id,
                message,
            },
            PersistOp::MessageUpdate {
                session_id,
                message_id,
                content,
                tool_output,
                duration_ms,
                is_error,
            } => PersistCommand::MessageUpdate {
                session_id,
                message_id,
                content,
                tool_output,
                duration_ms,
                is_error,
            },
            PersistOp::TokensUpdate { session_id, usage } => {
                PersistCommand::TokensUpdate { session_id, usage }
            }
            PersistOp::TurnStateUpdate {
                session_id,
                diff,
                plan,
            } => PersistCommand::TurnStateUpdate {
                session_id,
                diff,
                plan,
            },
            PersistOp::TurnDiffInsert {
                session_id,
                turn_id,
                diff,
                input_tokens,
                output_tokens,
                cached_tokens,
                context_window,
            } => PersistCommand::TurnDiffInsert {
                session_id,
                turn_id,
                diff,
                input_tokens,
                output_tokens,
                cached_tokens,
                context_window,
            },
            PersistOp::SetCustomName {
                session_id,
                custom_name,
            } => PersistCommand::SetCustomName {
                session_id,
                custom_name,
            },
            PersistOp::ApprovalRequested {
                session_id,
                request_id,
                approval_type,
                tool_name,
                command,
                file_path,
                cwd,
                proposed_amendment,
            } => PersistCommand::ApprovalRequested {
                session_id,
                request_id,
                approval_type,
                tool_name,
                command,
                file_path,
                cwd,
                proposed_amendment,
            },
            PersistOp::EnvironmentUpdate {
                session_id,
                cwd,
                git_branch,
                git_sha,
            } => PersistCommand::EnvironmentUpdate {
                session_id,
                cwd,
                git_branch,
                git_sha,
            },
            PersistOp::ToolCountIncrement { session_id } => {
                PersistCommand::ToolCountIncrement { session_id }
            }
            PersistOp::ModelUpdate { session_id, model } => {
                PersistCommand::ModelUpdate { session_id, model }
            }
            PersistOp::SaveClaudeModels { models } => PersistCommand::SaveClaudeModels { models },
        }
    }
}

// ---------------------------------------------------------------------------
// transition() — the pure core
// ---------------------------------------------------------------------------

/// Pure, synchronous state transition.
///
/// Given the current state and an input event, returns the new state
/// and a list of effects (persistence writes, broadcasts) to execute.
pub fn transition(
    mut state: TransitionState,
    input: Input,
    now: &str,
) -> (TransitionState, Vec<Effect>) {
    let sid = state.id.clone();
    let mut effects: Vec<Effect> = Vec::new();

    match input {
        // -- Status transitions -----------------------------------------------
        Input::TurnStarted => {
            state.phase = WorkPhase::Working;
            state.last_activity_at = Some(now.to_string());
            state.turn_count += 1;
            let turn_id = format!("turn-{}", state.turn_count);
            state.current_turn_id = Some(turn_id.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    work_status: Some(WorkStatus::Working),
                    last_activity_at: Some(now.to_string()),
                    current_turn_id: Some(Some(turn_id)),
                    turn_count: Some(state.turn_count),
                    ..Default::default()
                },
            })));
        }

        Input::TurnCompleted => {
            // Snapshot the current diff for this turn before clearing
            if let (Some(turn_id), Some(diff)) =
                (state.current_turn_id.as_ref(), state.current_diff.as_ref())
            {
                let usage = &state.token_usage;
                let snapshot = TurnDiff {
                    turn_id: turn_id.clone(),
                    diff: diff.clone(),
                    token_usage: Some(usage.clone()),
                };
                state.turn_diffs.push(snapshot);
                effects.push(Effect::Persist(Box::new(PersistOp::TurnDiffInsert {
                    session_id: sid.clone(),
                    turn_id: turn_id.clone(),
                    diff: diff.clone(),
                    input_tokens: usage.input_tokens,
                    output_tokens: usage.output_tokens,
                    cached_tokens: usage.cached_tokens,
                    context_window: usage.context_window,
                })));
                effects.push(Effect::Emit(Box::new(ServerMessage::TurnDiffSnapshot {
                    session_id: sid.clone(),
                    turn_id: turn_id.clone(),
                    diff: diff.clone(),
                    input_tokens: Some(usage.input_tokens),
                    output_tokens: Some(usage.output_tokens),
                    cached_tokens: Some(usage.cached_tokens),
                    context_window: Some(usage.context_window),
                })));
            }

            // Only transition if we're actually working
            if matches!(state.phase, WorkPhase::Working) {
                state.phase = WorkPhase::Idle;
            }
            state.last_activity_at = Some(now.to_string());
            state.current_turn_id = None;

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(now.to_string()),
                    current_turn_id: Some(None),
                    ..Default::default()
                },
            })));
        }

        Input::TurnAborted { .. } => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());
            state.current_turn_id = None;

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(now.to_string()),
                    current_turn_id: Some(None),
                    ..Default::default()
                },
            })));
        }

        Input::Error(msg) => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

            // Create an error message so the user sees what happened
            let error_msg = Message {
                id: format!("error-{}", uuid::Uuid::new_v4()),
                session_id: sid.clone(),
                message_type: MessageType::Assistant,
                content: msg,
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: true,
                timestamp: now.to_string(),
                duration_ms: None,
                images: vec![],
            };
            state.messages.push(error_msg.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::MessageAppend {
                session_id: sid.clone(),
                message: error_msg.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::MessageAppended {
                session_id: sid.clone(),
                message: error_msg,
            })));
            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(now.to_string()),
                    ..Default::default()
                },
            })));
        }

        // -- Messages ---------------------------------------------------------
        Input::MessageCreated(mut message) => {
            message.session_id = sid.clone();

            // Dedup: skip echoed user messages from the connector
            let is_dup =
                message.message_type == MessageType::User
                    && state.messages.iter().rev().take(5).any(|m| {
                        m.message_type == MessageType::User && m.content == message.content
                    });

            if !is_dup {
                state.messages.push(message.clone());
                state.last_activity_at = Some(now.to_string());

                effects.push(Effect::Persist(Box::new(PersistOp::MessageAppend {
                    session_id: sid.clone(),
                    message: message.clone(),
                })));

                // Increment tool_count for tool messages
                if message.message_type == MessageType::Tool {
                    effects.push(Effect::Persist(Box::new(PersistOp::ToolCountIncrement {
                        session_id: sid.clone(),
                    })));
                }

                effects.push(Effect::Emit(Box::new(ServerMessage::MessageAppended {
                    session_id: sid,
                    message,
                })));
            }
        }

        Input::MessageUpdated {
            message_id,
            content,
            tool_output,
            is_error,
            duration_ms,
        } => {
            if let Some(existing) = state
                .messages
                .iter_mut()
                .find(|message| message.id.as_str() == message_id.as_str())
            {
                if let Some(content) = content.as_ref() {
                    existing.content = content.clone();
                }
                if let Some(tool_output) = tool_output.as_ref() {
                    existing.tool_output = Some(tool_output.clone());
                }
                if let Some(is_error) = is_error {
                    existing.is_error = is_error;
                }
                if let Some(duration_ms) = duration_ms {
                    existing.duration_ms = Some(duration_ms);
                }
            }

            effects.push(Effect::Persist(Box::new(PersistOp::MessageUpdate {
                session_id: sid.clone(),
                message_id: message_id.clone(),
                content: content.clone(),
                tool_output: tool_output.clone(),
                duration_ms,
                is_error,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::MessageUpdated {
                session_id: sid,
                message_id,
                changes: MessageChanges {
                    content,
                    tool_output,
                    is_error,
                    duration_ms,
                },
            })));
        }

        // -- Approval ---------------------------------------------------------
        Input::ApprovalRequested {
            request_id,
            approval_type,
            tool_name,
            tool_input,
            command,
            file_path,
            diff,
            question,
            proposed_amendment,
        } => {
            state.phase = WorkPhase::AwaitingApproval {
                request_id: request_id.clone(),
                approval_type,
                proposed_amendment: proposed_amendment.clone(),
            };
            state.last_activity_at = Some(now.to_string());

            // Use real tool_name from connector when available, fall back to type-based name
            let resolved_tool_name = tool_name.unwrap_or_else(|| match approval_type {
                ApprovalType::Exec => "Bash".to_string(),
                ApprovalType::Patch => "Edit".to_string(),
                ApprovalType::Question => "Question".to_string(),
            });
            let preview = build_approval_preview(
                approval_type,
                Some(resolved_tool_name.as_str()),
                tool_input.as_deref(),
                command.as_deref(),
                file_path.as_deref(),
            );

            let request = ApprovalRequest {
                id: request_id.clone(),
                session_id: sid.clone(),
                approval_type,
                tool_name: Some(resolved_tool_name.clone()),
                tool_input: tool_input.clone(),
                command: command.clone(),
                file_path: file_path.clone(),
                diff,
                question,
                preview,
                proposed_amendment: proposed_amendment.clone(),
            };

            state.pending_approval = Some(request.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::ApprovalRequested {
                session_id: sid.clone(),
                request_id,
                approval_type,
                tool_name: Some(resolved_tool_name),
                command,
                file_path,
                cwd: Some(state.project_path.clone()),
                proposed_amendment,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::ApprovalRequested {
                session_id: sid,
                request,
            })));
        }

        // -- Metadata ---------------------------------------------------------
        Input::TokensUpdated(usage) => {
            state.token_usage = usage.clone();

            effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
                session_id: sid.clone(),
                usage: usage.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
                session_id: sid,
                usage,
            })));
        }

        Input::DiffUpdated(diff) => {
            state.current_diff = Some(diff.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
                session_id: sid.clone(),
                diff: Some(diff.clone()),
                plan: None,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    current_diff: Some(Some(diff)),
                    ..Default::default()
                },
            })));
        }

        Input::PlanUpdated(plan) => {
            state.current_plan = Some(plan.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
                session_id: sid.clone(),
                diff: None,
                plan: Some(plan.clone()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    current_plan: Some(Some(plan)),
                    ..Default::default()
                },
            })));
        }

        Input::ThreadNameUpdated(name) => {
            state.custom_name = Some(name.clone());
            state.last_activity_at = Some(now.to_string());

            effects.push(Effect::Persist(Box::new(PersistOp::SetCustomName {
                session_id: sid.clone(),
                custom_name: Some(name.clone()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    custom_name: Some(Some(name)),
                    ..Default::default()
                },
            })));
        }

        // -- Lifecycle --------------------------------------------------------
        Input::SessionEnded { reason } => {
            state.phase = WorkPhase::Ended {
                reason: reason.clone(),
            };
            state.last_activity_at = Some(now.to_string());

            effects.push(Effect::Persist(Box::new(PersistOp::SessionEnd {
                id: sid.clone(),
                reason: reason.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionEnded {
                session_id: sid,
                reason,
            })));
        }

        // -- Undo/Rollback ----------------------------------------------------
        Input::UndoStarted { message } => {
            state.phase = WorkPhase::Working;
            state.last_activity_at = Some(now.to_string());

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid.clone(),
                changes: StateChanges {
                    work_status: Some(WorkStatus::Working),
                    last_activity_at: Some(now.to_string()),
                    ..Default::default()
                },
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::UndoStarted {
                session_id: sid,
                message,
            })));
        }

        Input::UndoCompleted { success, message } => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid.clone(),
                changes: StateChanges {
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(now.to_string()),
                    ..Default::default()
                },
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::UndoCompleted {
                session_id: sid,
                success,
                message,
            })));
        }

        Input::ThreadRolledBack { num_turns } => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

            effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
                id: sid.clone(),
                status: None,
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now.to_string()),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid.clone(),
                changes: StateChanges {
                    work_status: Some(WorkStatus::Waiting),
                    last_activity_at: Some(now.to_string()),
                    ..Default::default()
                },
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::ThreadRolledBack {
                session_id: sid,
                num_turns,
            })));
        }

        // -- Environment --------------------------------------------------------
        Input::EnvironmentChanged {
            cwd,
            git_branch,
            git_sha,
        } => {
            let mut changed = false;
            if cwd.is_some() && cwd != state.current_cwd {
                state.current_cwd = cwd.clone();
                changed = true;
            }
            if git_branch.is_some() && git_branch != state.git_branch {
                state.git_branch = git_branch.clone();
                changed = true;
            }
            if git_sha.is_some() && git_sha != state.git_sha {
                state.git_sha = git_sha.clone();
                changed = true;
            }

            if changed {
                state.last_activity_at = Some(now.to_string());

                effects.push(Effect::Persist(Box::new(PersistOp::EnvironmentUpdate {
                    session_id: sid.clone(),
                    cwd: state.current_cwd.clone(),
                    git_branch: state.git_branch.clone(),
                    git_sha: state.git_sha.clone(),
                })));
                effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                    session_id: sid,
                    changes: StateChanges {
                        current_cwd: Some(state.current_cwd.clone()),
                        git_branch: Some(state.git_branch.clone()),
                        git_sha: Some(state.git_sha.clone()),
                        last_activity_at: Some(now.to_string()),
                        ..Default::default()
                    },
                })));
            }
        }

        // -- Model ---------------------------------------------------------------
        Input::ModelUpdated(model) => {
            effects.push(Effect::Persist(Box::new(PersistOp::ModelUpdate {
                session_id: sid.clone(),
                model: model.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    model: Some(Some(model)),
                    ..Default::default()
                },
            })));
        }

        // -- Claude capabilities (from init message) ---------------------------
        Input::ClaudeInitialized {
            slash_commands,
            skills,
            tools,
            models,
        } => {
            if !models.is_empty() {
                effects.push(Effect::Persist(Box::new(PersistOp::SaveClaudeModels {
                    models: models.clone(),
                })));
            }
            effects.push(Effect::Emit(Box::new(ServerMessage::ClaudeCapabilities {
                session_id: sid,
                slash_commands,
                skills,
                tools,
                models,
            })));
        }

        // -- Context management -----------------------------------------------
        Input::ContextCompacted => {
            state.last_activity_at = Some(now.to_string());
            let compacted_usage = TokenUsage {
                input_tokens: 0,
                output_tokens: state.token_usage.output_tokens,
                cached_tokens: 0,
                context_window: state.token_usage.context_window,
            };
            state.token_usage = compacted_usage.clone();

            effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
                session_id: sid.clone(),
                usage: compacted_usage.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
                session_id: sid.clone(),
                usage: compacted_usage,
            })));

            // Record compaction as a first-class transcript event so it is visible
            // in chat history and persisted in SQLite for reloads.
            let compact_msg = Message {
                id: format!("context-compacted-{}", uuid::Uuid::new_v4()),
                session_id: sid.clone(),
                message_type: MessageType::Assistant,
                content: "Context compacted to keep this session within the model context window."
                    .to_string(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                timestamp: now.to_string(),
                duration_ms: None,
                images: vec![],
            };
            state.messages.push(compact_msg.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::MessageAppend {
                session_id: sid.clone(),
                message: compact_msg.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::MessageAppended {
                session_id: sid.clone(),
                message: compact_msg,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::ContextCompacted {
                session_id: sid,
            })));
        }

        Input::SkillsList { skills, errors } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::SkillsList {
                session_id: sid,
                skills,
                errors,
            })));
        }

        Input::RemoteSkillsList { skills } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::RemoteSkillsList {
                session_id: sid,
                skills,
            })));
        }

        Input::RemoteSkillDownloaded { id, name, path } => {
            effects.push(Effect::Emit(Box::new(
                ServerMessage::RemoteSkillDownloaded {
                    session_id: sid,
                    id,
                    name,
                    path,
                },
            )));
        }

        Input::SkillsUpdateAvailable => {
            effects.push(Effect::Emit(Box::new(
                ServerMessage::SkillsUpdateAvailable { session_id: sid },
            )));
        }

        Input::McpToolsList {
            tools,
            resources,
            resource_templates,
            auth_statuses,
        } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::McpToolsList {
                session_id: sid,
                tools,
                resources,
                resource_templates,
                auth_statuses,
            })));
        }

        Input::McpStartupUpdate { server, status } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::McpStartupUpdate {
                session_id: sid,
                server,
                status,
            })));
        }

        Input::McpStartupComplete {
            ready,
            failed,
            cancelled,
        } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::McpStartupComplete {
                session_id: sid,
                ready,
                failed,
                cancelled,
            })));
        }
    }

    // Clear pending_approval whenever phase transitions away from AwaitingApproval.
    // The ApprovalRequested handler sets it; all other transitions clear it.
    if !matches!(state.phase, WorkPhase::AwaitingApproval { .. }) {
        state.pending_approval = None;
    }

    (state, effects)
}

fn build_approval_preview(
    approval_type: ApprovalType,
    tool_name: Option<&str>,
    tool_input: Option<&str>,
    command: Option<&str>,
    file_path: Option<&str>,
) -> Option<ApprovalPreview> {
    let input = parse_tool_input_object(tool_input);
    let normalized_tool_name = trim_non_empty(tool_name)
        .map(|name| name.to_lowercase())
        .unwrap_or_default();

    let command_from_input = input
        .as_ref()
        .and_then(|dict| dict.get("command").or_else(|| dict.get("cmd")))
        .and_then(shell_command_from_json_value);
    let command = command_from_input.or_else(|| trim_non_empty(command));

    let file_path_from_input = input.as_ref().and_then(|dict| {
        dict.get("path")
            .and_then(|value| value.as_str())
            .and_then(trim_non_empty_str)
            .or_else(|| {
                dict.get("file_path")
                    .and_then(|value| value.as_str())
                    .and_then(trim_non_empty_str)
            })
    });
    let file_path = file_path_from_input.or_else(|| trim_non_empty(file_path));

    let url = input.as_ref().and_then(|dict| {
        dict.get("url")
            .and_then(|value| value.as_str())
            .and_then(trim_non_empty_str)
    });
    let query = input.as_ref().and_then(|dict| {
        dict.get("query")
            .and_then(|value| value.as_str())
            .and_then(trim_non_empty_str)
    });
    let pattern = input.as_ref().and_then(|dict| {
        dict.get("pattern")
            .and_then(|value| value.as_str())
            .and_then(trim_non_empty_str)
    });
    let prompt = input.as_ref().and_then(|dict| {
        dict.get("prompt")
            .and_then(|value| value.as_str())
            .and_then(trim_non_empty_str)
    });
    let fallback_input_value = input.as_ref().and_then(first_string_value_from_json_object);

    if let Some(command) = command {
        let shell_segments = shell_segments_for_preview(&command);
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::ShellCommand,
            &command,
            &shell_segments,
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::ShellCommand,
            value: command,
            shell_segments,
            compact,
        });
    }

    if let Some(url) = url {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::Url,
            &url,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::Url,
            value: url,
            shell_segments: vec![],
            compact,
        });
    }

    if let Some(query) = query {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::SearchQuery,
            &query,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::SearchQuery,
            value: query,
            shell_segments: vec![],
            compact,
        });
    }

    if let Some(pattern) = pattern {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::Pattern,
            &pattern,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::Pattern,
            value: pattern,
            shell_segments: vec![],
            compact,
        });
    }

    if let Some(prompt) = prompt {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::Prompt,
            &prompt,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::Prompt,
            value: prompt,
            shell_segments: vec![],
            compact,
        });
    }

    if let Some(path) = file_path {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::FilePath,
            &path,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::FilePath,
            value: path,
            shell_segments: vec![],
            compact,
        });
    }

    if let Some(value) = fallback_input_value {
        let compact = compact_detail_for_preview(
            ApprovalPreviewType::Value,
            &value,
            &[],
            normalized_tool_name.as_str(),
        );
        return Some(ApprovalPreview {
            preview_type: ApprovalPreviewType::Value,
            value,
            shell_segments: vec![],
            compact,
        });
    }

    let fallback_action = match approval_type {
        ApprovalType::Question => {
            trim_non_empty(tool_name).unwrap_or_else(|| "Question".to_string())
        }
        _ => trim_non_empty(tool_name)
            .map(|name| format!("Approve {name} action?"))
            .unwrap_or_else(|| "Approve action?".to_string()),
    };

    let compact = compact_detail_for_preview(
        ApprovalPreviewType::Action,
        &fallback_action,
        &[],
        normalized_tool_name.as_str(),
    );

    Some(ApprovalPreview {
        preview_type: ApprovalPreviewType::Action,
        value: fallback_action,
        shell_segments: vec![],
        compact,
    })
}

fn parse_tool_input_object(tool_input: Option<&str>) -> Option<JsonMap<String, JsonValue>> {
    let raw = trim_non_empty(tool_input)?;
    let parsed: JsonValue = serde_json::from_str(&raw).ok()?;
    parsed.as_object().cloned()
}

fn shell_command_from_json_value(value: &JsonValue) -> Option<String> {
    if let Some(command) = value.as_str() {
        return trim_non_empty(Some(command));
    }

    let parts = value.as_array()?;
    let tokens: Option<Vec<String>> = parts
        .iter()
        .map(|item| item.as_str().map(|token| token.to_string()))
        .collect();
    let joined = tokens?.join(" ");
    trim_non_empty(Some(joined.as_str()))
}

fn first_string_value_from_json_object(dict: &JsonMap<String, JsonValue>) -> Option<String> {
    let mut keys: Vec<&String> = dict.keys().collect();
    keys.sort_unstable();

    for key in keys {
        if let Some(value) = dict.get(key).and_then(|raw| raw.as_str()) {
            if let Some(trimmed) = trim_non_empty(Some(value)) {
                return Some(trimmed);
            }
        }
    }

    None
}

fn compact_detail_for_preview(
    preview_type: ApprovalPreviewType,
    value: &str,
    shell_segments: &[ApprovalPreviewSegment],
    normalized_tool_name: &str,
) -> Option<String> {
    let summary = match preview_type {
        ApprovalPreviewType::ShellCommand => {
            if shell_segments.len() > 1 {
                let first = shell_segments
                    .first()
                    .map(|segment| segment.command.clone())
                    .unwrap_or_else(|| value.to_string());
                let remaining = shell_segments.len().saturating_sub(1);
                let noun = if remaining == 1 {
                    "segment"
                } else {
                    "segments"
                };
                format!("{first} +{remaining} {noun}")
            } else {
                value.to_string()
            }
        }
        ApprovalPreviewType::Url => format!("url: {value}"),
        ApprovalPreviewType::SearchQuery => format!("query: {value}"),
        ApprovalPreviewType::Pattern => format!("pattern: {value}"),
        ApprovalPreviewType::Prompt => format!("prompt: {value}"),
        ApprovalPreviewType::FilePath
            if matches!(
                normalized_tool_name,
                "edit" | "write" | "read" | "notebookedit"
            ) =>
        {
            Path::new(value)
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.to_string())
                .unwrap_or_else(|| value.to_string())
        }
        ApprovalPreviewType::Value
        | ApprovalPreviewType::FilePath
        | ApprovalPreviewType::Action => value.to_string(),
    };

    let trimmed = trim_non_empty(Some(summary.as_str()))?;
    Some(compact_truncate(trimmed, 50))
}

fn compact_truncate(text: String, max_length: usize) -> String {
    if max_length == 0 {
        return String::new();
    }
    if max_length <= 3 {
        return text.chars().take(max_length).collect();
    }
    if text.chars().count() <= max_length {
        return text;
    }
    let prefix: String = text.chars().take(max_length.saturating_sub(3)).collect();
    format!("{prefix}...")
}

fn trim_non_empty(value: Option<&str>) -> Option<String> {
    let value = value?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn trim_non_empty_str(value: &str) -> Option<String> {
    trim_non_empty(Some(value))
}

fn flush_shell_segment(
    buffer: &mut String,
    segments: &mut Vec<ApprovalPreviewSegment>,
    pending_operator: &mut Option<String>,
) {
    let trimmed = buffer.trim();
    if trimmed.is_empty() {
        buffer.clear();
        return;
    }

    let leading_operator = if segments.is_empty() {
        None
    } else {
        pending_operator.clone()
    };
    segments.push(ApprovalPreviewSegment {
        command: trimmed.to_string(),
        leading_operator,
    });
    buffer.clear();
    *pending_operator = None;
}

fn shell_segments_for_preview(command: &str) -> Vec<ApprovalPreviewSegment> {
    let chars: Vec<char> = command.chars().collect();
    let mut segments: Vec<ApprovalPreviewSegment> = Vec::new();
    let mut buffer = String::new();
    let mut pending_operator: Option<String> = None;

    let mut in_single_quote = false;
    let mut in_double_quote = false;
    let mut in_backtick = false;
    let mut escaped = false;
    let mut paren_depth: usize = 0;

    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];

        if escaped {
            buffer.push(ch);
            escaped = false;
            index += 1;
            continue;
        }

        if ch == '\\' {
            if !in_single_quote {
                escaped = true;
            }
            buffer.push(ch);
            index += 1;
            continue;
        }

        if !in_double_quote && !in_backtick && ch == '\'' {
            in_single_quote = !in_single_quote;
            buffer.push(ch);
            index += 1;
            continue;
        }

        if !in_single_quote && !in_backtick && ch == '"' {
            in_double_quote = !in_double_quote;
            buffer.push(ch);
            index += 1;
            continue;
        }

        if !in_single_quote && !in_double_quote && ch == '`' {
            in_backtick = !in_backtick;
            buffer.push(ch);
            index += 1;
            continue;
        }

        let can_split = !in_single_quote && !in_double_quote && !in_backtick && paren_depth == 0;

        if !in_single_quote && !in_double_quote && !in_backtick {
            if ch == '(' {
                paren_depth += 1;
            } else if ch == ')' {
                paren_depth = paren_depth.saturating_sub(1);
            }
        }

        if can_split {
            if ch == '|' {
                let is_double = (index + 1) < chars.len() && chars[index + 1] == '|';
                flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
                pending_operator = Some(if is_double { "||" } else { "|" }.to_string());
                index += if is_double { 2 } else { 1 };
                continue;
            }

            if ch == '&' && (index + 1) < chars.len() && chars[index + 1] == '&' {
                flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
                pending_operator = Some("&&".to_string());
                index += 2;
                continue;
            }

            if ch == ';' || ch == '\n' {
                flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
                pending_operator = Some(";".to_string());
                index += 1;
                continue;
            }
        }

        buffer.push(ch);
        index += 1;
    }

    flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
    segments
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use orbitdock_protocol::{ApprovalPreviewType, Message, MessageType, TokenUsage};

    fn test_state() -> TransitionState {
        TransitionState {
            id: "test-session".to_string(),
            revision: 0,
            phase: WorkPhase::Idle,
            messages: Vec::new(),
            token_usage: TokenUsage::default(),
            current_diff: None,
            current_plan: None,
            custom_name: None,
            project_path: "/tmp/project".to_string(),
            last_activity_at: None,
            current_turn_id: None,
            turn_count: 0,
            turn_diffs: Vec::new(),
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            pending_approval: None,
        }
    }

    fn test_message(msg_type: MessageType, content: &str) -> Message {
        Message {
            id: format!("msg-{}", content.len()),
            session_id: String::new(),
            message_type: msg_type,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            timestamp: "0Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    const NOW: &str = "1000Z";

    #[test]
    fn turn_started_transitions_to_working() {
        let state = test_state();
        let (new_state, effects) = transition(state, Input::TurnStarted, NOW);

        assert_eq!(new_state.phase, WorkPhase::Working);
        assert_eq!(effects.len(), 2); // Persist + Emit
        assert!(matches!(
            effects[0],
            Effect::Persist(ref op) if matches!(**op, PersistOp::SessionUpdate { .. })
        ));
        assert!(matches!(
            effects[1],
            Effect::Emit(ref msg) if matches!(**msg, ServerMessage::SessionDelta { .. })
        ));
    }

    #[test]
    fn turn_completed_transitions_to_idle() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        assert_eq!(new_state.phase, WorkPhase::Idle);
        assert_eq!(effects.len(), 2);
    }

    #[test]
    fn turn_completed_when_idle_stays_idle() {
        let state = test_state();
        assert_eq!(state.phase, WorkPhase::Idle);

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        // Phase stays Idle (guard prevents transition from non-Working)
        assert_eq!(new_state.phase, WorkPhase::Idle);
        // Still emits persist + broadcast for consistency
        assert_eq!(effects.len(), 2);
    }

    #[test]
    fn approval_requested_sets_awaiting_phase() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-1".to_string(),
                approval_type: ApprovalType::Exec,
                tool_name: None,
                tool_input: None,
                command: Some("rm -rf /".to_string()),
                file_path: None,
                diff: None,
                question: None,
                proposed_amendment: None,
            },
            NOW,
        );

        assert!(matches!(
            new_state.phase,
            WorkPhase::AwaitingApproval {
                ref request_id,
                approval_type: ApprovalType::Exec,
                ..
            } if request_id == "req-1"
        ));
        // Persist(ApprovalRequested) + Emit(ApprovalRequested)
        assert_eq!(effects.len(), 2);

        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::ApprovalRequested { request, .. } => {
                    let preview = request.preview.as_ref().expect("expected preview");
                    assert_eq!(preview.preview_type, ApprovalPreviewType::ShellCommand);
                    assert_eq!(preview.compact.as_deref(), Some("rm -rf /"));
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn approval_requested_preview_segments_shell_control_operators() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-shell".to_string(),
                approval_type: ApprovalType::Exec,
                tool_name: Some("Bash".to_string()),
                tool_input: Some(r#"{"command":"echo one || echo two"}"#.to_string()),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                proposed_amendment: None,
            },
            NOW,
        );

        assert!(matches!(
            new_state.phase,
            WorkPhase::AwaitingApproval {
                ref request_id,
                approval_type: ApprovalType::Exec,
                ..
            } if request_id == "req-shell"
        ));
        assert_eq!(effects.len(), 2);

        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::ApprovalRequested { request, .. } => {
                    let preview = request.preview.as_ref().expect("expected preview");
                    assert_eq!(preview.preview_type, ApprovalPreviewType::ShellCommand);
                    assert_eq!(preview.shell_segments.len(), 2);
                    assert_eq!(preview.shell_segments[0].leading_operator, None);
                    assert_eq!(
                        preview.shell_segments[1].leading_operator.as_deref(),
                        Some("||")
                    );
                    assert_eq!(preview.compact.as_deref(), Some("echo one +1 segment"));
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn approval_requested_preview_uses_basename_for_patch_like_tools() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (_, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-edit".to_string(),
                approval_type: ApprovalType::Patch,
                tool_name: Some("Edit".to_string()),
                tool_input: Some(r#"{"file_path":"/tmp/OrbitDock/docs/approvals.md"}"#.to_string()),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                proposed_amendment: None,
            },
            NOW,
        );

        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::ApprovalRequested { request, .. } => {
                    let preview = request.preview.as_ref().expect("expected preview");
                    assert_eq!(preview.preview_type, ApprovalPreviewType::FilePath);
                    assert_eq!(preview.value, "/tmp/OrbitDock/docs/approvals.md");
                    assert_eq!(preview.compact.as_deref(), Some("approvals.md"));
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn message_created_appends_to_state() {
        let state = test_state();
        let msg = test_message(MessageType::Assistant, "Hello world");

        let (new_state, effects) = transition(state, Input::MessageCreated(msg), NOW);

        assert_eq!(new_state.messages.len(), 1);
        assert_eq!(new_state.messages[0].content, "Hello world");
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn message_updated_mutates_existing_state_message() {
        let mut state = test_state();
        let mut msg = test_message(MessageType::Assistant, "I");
        msg.id = "msg-stream".to_string();
        msg.tool_output = Some("old output".to_string());
        state.messages.push(msg);

        let (new_state, effects) = transition(
            state,
            Input::MessageUpdated {
                message_id: "msg-stream".to_string(),
                content: Some("I'm now cross-checking the highest-risk claims".to_string()),
                tool_output: Some("new output".to_string()),
                is_error: Some(false),
                duration_ms: Some(420),
            },
            NOW,
        );

        assert_eq!(new_state.messages.len(), 1);
        let updated = &new_state.messages[0];
        assert_eq!(updated.id, "msg-stream");
        assert_eq!(
            updated.content,
            "I'm now cross-checking the highest-risk claims"
        );
        assert_eq!(updated.tool_output.as_deref(), Some("new output"));
        assert!(!updated.is_error);
        assert_eq!(updated.duration_ms, Some(420));
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn user_message_dedup_skips_echo() {
        let mut state = test_state();
        state
            .messages
            .push(test_message(MessageType::User, "do something"));

        let echo = test_message(MessageType::User, "do something");
        let (new_state, effects) = transition(state, Input::MessageCreated(echo), NOW);

        // Should NOT add duplicate
        assert_eq!(new_state.messages.len(), 1);
        assert!(effects.is_empty());
    }

    #[test]
    fn session_ended_transitions_to_ended() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(
            state,
            Input::SessionEnded {
                reason: "user_quit".to_string(),
            },
            NOW,
        );

        assert!(matches!(
            new_state.phase,
            WorkPhase::Ended { ref reason } if reason == "user_quit"
        ));
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn undo_started_transitions_to_working() {
        let state = test_state();

        let (new_state, effects) = transition(
            state,
            Input::UndoStarted {
                message: Some("reverting".to_string()),
            },
            NOW,
        );

        assert_eq!(new_state.phase, WorkPhase::Working);
        // Persist + SessionDelta + UndoStarted
        assert_eq!(effects.len(), 3);
    }

    #[test]
    fn undo_completed_transitions_to_idle() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(
            state,
            Input::UndoCompleted {
                success: true,
                message: None,
            },
            NOW,
        );

        assert_eq!(new_state.phase, WorkPhase::Idle);
        // Persist + SessionDelta + UndoCompleted
        assert_eq!(effects.len(), 3);
    }

    #[test]
    fn context_compacted_appends_message_and_emits_event() {
        let mut state = test_state();
        state.token_usage = TokenUsage {
            input_tokens: 120_000,
            output_tokens: 9_500,
            cached_tokens: 2_400,
            context_window: 200_000,
        };

        let (new_state, effects) = transition(state.clone(), Input::ContextCompacted, NOW);
        assert_eq!(new_state.phase, state.phase);
        assert_eq!(new_state.token_usage.input_tokens, 0);
        assert_eq!(new_state.token_usage.cached_tokens, 0);
        assert_eq!(new_state.token_usage.output_tokens, 9_500);
        assert_eq!(new_state.token_usage.context_window, 200_000);
        assert_eq!(effects.len(), 5);
        assert!(matches!(effects[0], Effect::Persist(_)));
        assert!(matches!(effects[1], Effect::Emit(_)));
        assert!(matches!(effects[2], Effect::Persist(_)));
        assert!(matches!(effects[3], Effect::Emit(_)));
        assert!(matches!(effects[4], Effect::Emit(_)));
        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::TokensUpdated { usage, .. } => {
                    assert_eq!(usage.input_tokens, 0);
                    assert_eq!(usage.cached_tokens, 0);
                    assert_eq!(usage.output_tokens, 9_500);
                    assert_eq!(usage.context_window, 200_000);
                }
                other => panic!("expected tokens_updated effect, got {:?}", other),
            }
        }
        let last_msg = new_state
            .messages
            .last()
            .expect("expected compaction message");
        assert_eq!(last_msg.message_type, MessageType::Assistant);
        assert_eq!(
            last_msg.content,
            "Context compacted to keep this session within the model context window."
        );
    }

    #[test]
    fn pass_through_events_only_emit() {
        let state = test_state();

        let (_, effects) = transition(state, Input::SkillsUpdateAvailable, NOW);
        assert_eq!(effects.len(), 1);
        assert!(matches!(effects[0], Effect::Emit(_)));
    }

    #[test]
    fn error_transitions_to_idle() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) =
            transition(state, Input::Error("something broke".to_string()), NOW);

        assert_eq!(new_state.phase, WorkPhase::Idle);
        // 4 effects: message persist, message emit, session update, session delta
        assert_eq!(effects.len(), 4);
        // Verify the error message was added to state
        let last_msg = new_state.messages.last().unwrap();
        assert!(last_msg.id.starts_with("error-"));
        assert_eq!(last_msg.content, "something broke");
        assert!(last_msg.is_error);
        assert_eq!(last_msg.message_type, MessageType::Assistant);
    }

    #[test]
    fn tokens_updated_stores_usage() {
        let state = test_state();
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cached_tokens: 20,
            context_window: 128000,
        };

        let (new_state, effects) = transition(state, Input::TokensUpdated(usage.clone()), NOW);

        assert_eq!(new_state.token_usage.input_tokens, 100);
        assert_eq!(new_state.token_usage.output_tokens, 50);
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn thread_rolled_back_transitions_to_idle() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (new_state, effects) = transition(state, Input::ThreadRolledBack { num_turns: 3 }, NOW);

        assert_eq!(new_state.phase, WorkPhase::Idle);
        // Persist + SessionDelta + ThreadRolledBack
        assert_eq!(effects.len(), 3);
    }

    #[test]
    fn turn_started_generates_turn_id() {
        let state = test_state();
        assert_eq!(state.turn_count, 0);
        assert!(state.current_turn_id.is_none());

        let (new_state, effects) = transition(state, Input::TurnStarted, NOW);

        assert_eq!(new_state.turn_count, 1);
        assert_eq!(new_state.current_turn_id, Some("turn-1".to_string()));

        // Verify turn_id and turn_count are in the delta
        if let Effect::Emit(ref msg) = effects[1] {
            if let ServerMessage::SessionDelta { changes, .. } = msg.as_ref() {
                assert_eq!(changes.current_turn_id, Some(Some("turn-1".to_string())));
                assert_eq!(changes.turn_count, Some(1));
            } else {
                panic!("expected SessionDelta");
            }
        }
    }

    #[test]
    fn turn_count_increments_across_turns() {
        let state = test_state();

        // First turn
        let (state1, _) = transition(state, Input::TurnStarted, NOW);
        assert_eq!(state1.turn_count, 1);
        assert_eq!(state1.current_turn_id, Some("turn-1".to_string()));

        let (state2, _) = transition(state1, Input::TurnCompleted, NOW);
        assert!(state2.current_turn_id.is_none());

        // Second turn
        let (state3, _) = transition(state2, Input::TurnStarted, NOW);
        assert_eq!(state3.turn_count, 2);
        assert_eq!(state3.current_turn_id, Some("turn-2".to_string()));
    }

    #[test]
    fn turn_completed_snapshots_diff() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state.current_turn_id = Some("turn-1".to_string());
        state.turn_count = 1;
        state.current_diff =
            Some("--- a/file.rs\n+++ b/file.rs\n@@ -1 +1 @@\n-old\n+new".to_string());

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        // Diff should be snapshotted
        assert_eq!(new_state.turn_diffs.len(), 1);
        assert_eq!(new_state.turn_diffs[0].turn_id, "turn-1");
        assert!(new_state.turn_diffs[0].diff.contains("+new"));

        // Turn ID should be cleared
        assert!(new_state.current_turn_id.is_none());

        // Should emit TurnDiffSnapshot
        let has_snapshot = effects.iter().any(|e| matches!(
            e,
            Effect::Emit(ref msg) if matches!(msg.as_ref(), ServerMessage::TurnDiffSnapshot { .. })
        ));
        assert!(has_snapshot, "should emit TurnDiffSnapshot");
    }

    #[test]
    fn turn_completed_without_diff_skips_snapshot() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state.current_turn_id = Some("turn-1".to_string());
        state.turn_count = 1;
        state.current_diff = None;

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        assert!(new_state.turn_diffs.is_empty());

        let has_snapshot = effects.iter().any(|e| matches!(
            e,
            Effect::Emit(ref msg) if matches!(msg.as_ref(), ServerMessage::TurnDiffSnapshot { .. })
        ));
        assert!(
            !has_snapshot,
            "should NOT emit TurnDiffSnapshot without diff"
        );
    }

    #[test]
    fn turn_aborted_clears_turn_id() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state.current_turn_id = Some("turn-1".to_string());

        let (new_state, _) = transition(
            state,
            Input::TurnAborted {
                reason: "interrupted".to_string(),
            },
            NOW,
        );

        assert!(new_state.current_turn_id.is_none());
    }
}
