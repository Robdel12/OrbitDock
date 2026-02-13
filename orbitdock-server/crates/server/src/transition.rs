//! Pure state transition function
//!
//! All business logic for session state changes lives here as a pure,
//! synchronous function: `transition(state, input) -> (state, effects)`.
//! No IO, no async, no locking — fully unit-testable.

use std::collections::HashMap;

use orbitdock_connectors::{ApprovalType as ConnectorApprovalType, ConnectorEvent};
use orbitdock_protocol::{
    ApprovalRequest, ApprovalType, McpAuthStatus, McpResource, McpResourceTemplate,
    McpStartupFailure, McpStartupStatus, McpTool, Message, MessageChanges, MessageType,
    RemoteSkillSummary, ServerMessage, SessionStatus, SkillErrorInfo, SkillsListEntry,
    StateChanges, TokenUsage, WorkStatus,
};

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
            ConnectorEvent::ContextCompacted => Input::ContextCompacted,
            ConnectorEvent::UndoStarted { message } => Input::UndoStarted { message },
            ConnectorEvent::UndoCompleted { success, message } => {
                Input::UndoCompleted { success, message }
            }
            ConnectorEvent::ThreadRolledBack { num_turns } => Input::ThreadRolledBack { num_turns },
            ConnectorEvent::Error(msg) => Input::Error(msg),
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
                    ..Default::default()
                },
            })));
        }

        Input::TurnCompleted => {
            // Only transition if we're actually working
            if matches!(state.phase, WorkPhase::Working) {
                state.phase = WorkPhase::Idle;
            }
            state.last_activity_at = Some(now.to_string());

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

        Input::TurnAborted { .. } => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

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

        Input::Error(_) => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

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

            let tool_name = Some(match approval_type {
                ApprovalType::Exec => "Bash".to_string(),
                ApprovalType::Patch => "Edit".to_string(),
                ApprovalType::Question => "Question".to_string(),
            });

            let request = ApprovalRequest {
                id: request_id.clone(),
                session_id: sid.clone(),
                approval_type,
                command: command.clone(),
                file_path: file_path.clone(),
                diff,
                question,
                proposed_amendment: proposed_amendment.clone(),
            };

            effects.push(Effect::Persist(Box::new(PersistOp::ApprovalRequested {
                session_id: sid.clone(),
                request_id,
                approval_type,
                tool_name,
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
                session_id: sid,
                diff: Some(diff),
                plan: None,
            })));
        }

        Input::PlanUpdated(plan) => {
            state.current_plan = Some(plan.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
                session_id: sid,
                diff: None,
                plan: Some(plan),
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

        // -- Pass-through (broadcast only, no state change) -------------------
        Input::ContextCompacted => {
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

    (state, effects)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use orbitdock_protocol::{Message, MessageType, TokenUsage};

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
    fn pass_through_events_only_emit() {
        let state = test_state();

        let (new_state, effects) = transition(state.clone(), Input::ContextCompacted, NOW);
        assert_eq!(new_state.phase, state.phase);
        assert_eq!(effects.len(), 1);
        assert!(matches!(effects[0], Effect::Emit(_)));

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
        assert_eq!(effects.len(), 2);
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
}
