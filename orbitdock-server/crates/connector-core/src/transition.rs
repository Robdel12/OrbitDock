//! Pure state transition function
//!
//! All business logic for session state changes lives here as a pure,
//! synchronous function: `transition(state, input) -> (state, effects)`.
//! No IO, no async, no locking — fully unit-testable.

use std::collections::HashMap;
use std::path::Path;

use crate::ConnectorEvent;
#[cfg(test)]
use orbitdock_protocol::conversation_contracts::ToolRow;
use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent,
};
use orbitdock_protocol::domain_events::ToolStatus;
#[cfg(test)]
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind};
use orbitdock_protocol::{
    ApprovalPreview, ApprovalPreviewSegment, ApprovalPreviewType, ApprovalQuestionOption,
    ApprovalQuestionPrompt, ApprovalRequest, ApprovalRiskLevel, ApprovalType, McpAuthStatus,
    McpResource, McpResourceTemplate, McpStartupFailure, McpStartupStatus, McpTool, Provider,
    ServerMessage, SessionStatus, SkillErrorInfo, SkillsListEntry, StateChanges, TokenUsage,
    TokenUsageSnapshotKind, TurnDiff, WorkStatus,
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
    pub provider: Provider,
    pub revision: u64,
    pub phase: WorkPhase,
    pub rows: Vec<ConversationRowEntry>,
    pub total_row_count: u64,
    pub token_usage: TokenUsage,
    pub token_usage_snapshot_kind: TokenUsageSnapshotKind,
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
    pub repository_root: Option<String>,
    pub is_worktree: bool,
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
    RowCreated(ConversationRowEntry),
    RowUpdated {
        row_id: String,
        entry: ConversationRowEntry,
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
        permission_reason: Option<String>,
        requested_permissions: Option<serde_json::Value>,
        proposed_amendment: Option<Vec<String>>,
        permission_suggestions: Option<serde_json::Value>,
        elicitation_mode: Option<String>,
        elicitation_schema: Option<serde_json::Value>,
        elicitation_url: Option<String>,
        elicitation_message: Option<String>,
        mcp_server_name: Option<String>,
        network_host: Option<String>,
        network_protocol: Option<String>,
    },
    TokensUpdated {
        usage: TokenUsage,
        snapshot_kind: TokenUsageSnapshotKind,
    },
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
    ApprovalCancelled {
        request_id: String,
    },
    PermissionModeChanged {
        mode: String,
    },
    EnvironmentChanged {
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        repository_root: Option<String>,
        is_worktree: Option<bool>,
    },
    RateLimitEvent {
        info: orbitdock_protocol::RateLimitInfo,
    },
    PromptSuggestion {
        suggestion: String,
    },
    FilesPersisted {
        files: Vec<String>,
    },
    Error(String),
}

impl From<ConnectorEvent> for Input {
    fn from(event: ConnectorEvent) -> Self {
        match event {
            ConnectorEvent::TurnStarted => Input::TurnStarted,
            ConnectorEvent::TurnCompleted => Input::TurnCompleted,
            ConnectorEvent::TurnAborted { reason } => Input::TurnAborted { reason },
            ConnectorEvent::ConversationRowCreated(entry) => Input::RowCreated(entry),
            ConnectorEvent::ConversationRowUpdated { row_id, entry } => {
                Input::RowUpdated { row_id, entry }
            }
            ConnectorEvent::ApprovalRequested {
                request_id,
                approval_type,
                tool_name,
                tool_input,
                command,
                file_path,
                diff,
                question,
                permission_reason,
                requested_permissions,
                proposed_amendment,
                permission_suggestions,
                elicitation_mode,
                elicitation_schema,
                elicitation_url,
                elicitation_message,
                mcp_server_name,
                network_host,
                network_protocol,
            } => Input::ApprovalRequested {
                request_id,
                approval_type,
                tool_name,
                tool_input,
                command,
                file_path,
                diff,
                question,
                permission_reason,
                requested_permissions,
                proposed_amendment,
                permission_suggestions,
                elicitation_mode,
                elicitation_schema,
                elicitation_url,
                elicitation_message,
                mcp_server_name,
                network_host,
                network_protocol,
            },
            ConnectorEvent::TokensUpdated {
                usage,
                snapshot_kind,
            } => Input::TokensUpdated {
                usage,
                snapshot_kind,
            },
            ConnectorEvent::DiffUpdated(diff) => Input::DiffUpdated(diff),
            ConnectorEvent::PlanUpdated(plan) => Input::PlanUpdated(plan),
            ConnectorEvent::ThreadNameUpdated(name) => Input::ThreadNameUpdated(name),
            ConnectorEvent::SessionEnded { reason } => Input::SessionEnded { reason },
            ConnectorEvent::SkillsList { skills, errors } => Input::SkillsList { skills, errors },
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
                repository_root: None,
                is_worktree: None,
            },
            ConnectorEvent::ApprovalCancelled { request_id } => {
                Input::ApprovalCancelled { request_id }
            }
            ConnectorEvent::PermissionModeChanged { mode } => Input::PermissionModeChanged { mode },
            ConnectorEvent::RateLimitEvent { info } => Input::RateLimitEvent { info },
            ConnectorEvent::PromptSuggestion { suggestion } => {
                Input::PromptSuggestion { suggestion }
            }
            ConnectorEvent::FilesPersisted { files } => Input::FilesPersisted { files },
            ConnectorEvent::Error(msg) => Input::Error(msg),
            // Handled in event loop before reaching transitions
            ConnectorEvent::HookSessionId(_) | ConnectorEvent::SubagentsUpdated { .. } => {
                unreachable!()
            }
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
    RowAppend {
        session_id: String,
        entry: ConversationRowEntry,
    },
    RowUpsert {
        session_id: String,
        entry: ConversationRowEntry,
    },
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
        snapshot_kind: TokenUsageSnapshotKind,
    },
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },
    TurnDiffInsert {
        session_id: String,
        turn_id: String,
        turn_seq: u64,
        diff: String,
        input_tokens: u64,
        output_tokens: u64,
        cached_tokens: u64,
        context_window: u64,
        snapshot_kind: TokenUsageSnapshotKind,
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
        tool_input: Option<String>,
        command: Option<String>,
        file_path: Option<String>,
        diff: Option<String>,
        question: Option<String>,
        question_prompts: Vec<ApprovalQuestionPrompt>,
        preview: Box<Option<ApprovalPreview>>,
        permission_reason: Option<String>,
        requested_permissions: Option<serde_json::Value>,
        granted_permissions: Option<serde_json::Value>,
        cwd: Option<String>,
        proposed_amendment: Option<Vec<String>>,
        permission_suggestions: Option<serde_json::Value>,
        elicitation_mode: Option<String>,
        elicitation_schema: Option<serde_json::Value>,
        elicitation_url: Option<String>,
        elicitation_message: Option<String>,
        mcp_server_name: Option<String>,
        network_host: Option<String>,
        network_protocol: Option<String>,
    },
    EnvironmentUpdate {
        session_id: String,
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        repository_root: Option<String>,
        is_worktree: Option<bool>,
    },
    ToolCountIncrement {
        session_id: String,
    },
    ModelUpdate {
        session_id: String,
        model: String,
    },
    PermissionModeUpdate {
        session_id: String,
        permission_mode: String,
    },
}

// ---------------------------------------------------------------------------
// finalize_in_progress_messages — cleanup helper
// ---------------------------------------------------------------------------

/// Scans rows for any tool rows with `ToolStatus::Running`, flips them to
/// `Completed`, and returns Persist + Emit effects for each. Called on
/// TurnCompleted, TurnAborted, and SessionEnded to prevent tool rows stuck
/// at "running...".
fn finalize_in_progress_rows(
    sid: &str,
    rows: &mut [ConversationRowEntry],
    total_row_count: u64,
) -> Vec<Effect> {
    let mut effects = Vec::new();
    let mut finalized_entries = Vec::new();
    for entry in rows.iter_mut() {
        match &mut entry.row {
            ConversationRow::Tool(ref mut tool) => {
                if tool.status == ToolStatus::Running {
                    tool.status = ToolStatus::Completed;
                    finalized_entries.push(entry.clone());
                    effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
                        session_id: sid.to_string(),
                        entry: entry.clone(),
                    })));
                }
            }
            ConversationRow::Assistant(ref mut msg)
            | ConversationRow::Thinking(ref mut msg)
            | ConversationRow::System(ref mut msg) => {
                if msg.is_streaming {
                    msg.is_streaming = false;
                    finalized_entries.push(entry.clone());
                    effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
                        session_id: sid.to_string(),
                        entry: entry.clone(),
                    })));
                }
            }
            _ => {}
        }
    }
    if !finalized_entries.is_empty() {
        effects.push(Effect::Emit(Box::new(
            ServerMessage::ConversationRowsChanged {
                session_id: sid.to_string(),
                upserted: finalized_entries.iter().map(|e| e.to_summary()).collect(),
                removed_row_ids: vec![],
                total_row_count,
            },
        )));
    }
    effects
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
                    snapshot_kind: Some(state.token_usage_snapshot_kind),
                };
                state.turn_diffs.push(snapshot);
                effects.push(Effect::Persist(Box::new(PersistOp::TurnDiffInsert {
                    session_id: sid.clone(),
                    turn_id: turn_id.clone(),
                    turn_seq: state.turn_count,
                    diff: diff.clone(),
                    input_tokens: usage.input_tokens,
                    output_tokens: usage.output_tokens,
                    cached_tokens: usage.cached_tokens,
                    context_window: usage.context_window,
                    snapshot_kind: state.token_usage_snapshot_kind,
                })));
                effects.push(Effect::Emit(Box::new(ServerMessage::TurnDiffSnapshot {
                    session_id: sid.clone(),
                    turn_id: turn_id.clone(),
                    diff: diff.clone(),
                    input_tokens: Some(usage.input_tokens),
                    output_tokens: Some(usage.output_tokens),
                    cached_tokens: Some(usage.cached_tokens),
                    context_window: Some(usage.context_window),
                    snapshot_kind: state.token_usage_snapshot_kind,
                })));
            }

            // Clear current_diff now that it has been archived into turn_diffs
            state.current_diff = None;

            // Finalize any tool messages stuck at is_in_progress before status change
            effects.extend(finalize_in_progress_rows(
                &sid,
                &mut state.rows,
                state.total_row_count,
            ));

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
                    current_diff: Some(None),
                    ..Default::default()
                },
            })));
        }

        Input::TurnAborted { .. } => {
            // Guard: only transition if we're actually in an active phase.
            // A second TurnAborted (e.g. from watchdog after provider already aborted) is a no-op.
            if !matches!(state.phase, WorkPhase::Idle | WorkPhase::Ended { .. }) {
                // Finalize any tool messages stuck at is_in_progress before status change
                effects.extend(finalize_in_progress_rows(
                    &sid,
                    &mut state.rows,
                    state.total_row_count,
                ));

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
        }

        Input::Error(msg) => {
            state.phase = WorkPhase::Idle;
            state.last_activity_at = Some(now.to_string());

            // Create an error row so the user sees what happened
            let seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
            let entry = ConversationRowEntry {
                session_id: sid.clone(),
                sequence: seq,
                turn_id: state.current_turn_id.clone(),
                row: ConversationRow::System(MessageRowContent {
                    id: format!("error-{}", uuid::Uuid::new_v4()),
                    content: msg,
                    turn_id: state.current_turn_id.clone(),
                    timestamp: Some(now.to_string()),
                    is_streaming: false,
                    images: vec![],
                    memory_citation: None,
                }),
            };
            state.rows.push(entry.clone());
            state.total_row_count = seq + 1;

            effects.push(Effect::Persist(Box::new(PersistOp::RowAppend {
                session_id: sid.clone(),
                entry: entry.clone(),
            })));
            effects.push(Effect::Emit(Box::new(
                ServerMessage::ConversationRowsChanged {
                    session_id: sid.clone(),
                    upserted: vec![entry.to_summary()],
                    removed_row_ids: vec![],
                    total_row_count: state.total_row_count,
                },
            )));
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

        // -- Conversation rows ------------------------------------------------
        Input::RowCreated(mut entry) => {
            entry.session_id = sid.clone();

            // Dedup: skip echoed user rows from the connector
            let is_dup = matches!(&entry.row, ConversationRow::User(u) if {
                state.rows.iter().rev().take(5).any(|existing| {
                    matches!(&existing.row, ConversationRow::User(eu) if eu.content == u.content)
                })
            });

            if !is_dup {
                // In-memory sequence for live ordering; DB assigns authoritative sequence on persist.
                entry.sequence = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
                state.rows.push(entry.clone());
                state.total_row_count = entry.sequence + 1;
                state.last_activity_at = Some(now.to_string());

                effects.push(Effect::Persist(Box::new(PersistOp::RowAppend {
                    session_id: sid.clone(),
                    entry: entry.clone(),
                })));

                // Increment tool_count for tool rows
                if matches!(&entry.row, ConversationRow::Tool(_)) {
                    effects.push(Effect::Persist(Box::new(PersistOp::ToolCountIncrement {
                        session_id: sid.clone(),
                    })));
                }

                effects.push(Effect::Emit(Box::new(
                    ServerMessage::ConversationRowsChanged {
                        session_id: sid,
                        upserted: vec![entry.to_summary()],
                        removed_row_ids: vec![],
                        total_row_count: state.total_row_count,
                    },
                )));
            }
        }

        Input::RowUpdated { row_id, entry } => {
            let found = state
                .rows
                .iter()
                .any(|existing| existing.id() == row_id.as_str());
            tracing::info!(
                component = "transition",
                event = "transition.row_updated",
                session_id = %sid,
                row_id = %row_id,
                row_found_in_state = found,
                "Processing RowUpdated input"
            );

            // Replace the existing row in state if found
            if let Some(existing) = state.rows.iter_mut().find(|e| e.id() == row_id.as_str()) {
                *existing = entry.clone();
            }

            effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
                session_id: sid.clone(),
                entry: entry.clone(),
            })));
            effects.push(Effect::Emit(Box::new(
                ServerMessage::ConversationRowsChanged {
                    session_id: sid,
                    upserted: vec![entry.to_summary()],
                    removed_row_ids: vec![],
                    total_row_count: state.total_row_count,
                },
            )));
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
            permission_reason,
            requested_permissions,
            proposed_amendment,
            permission_suggestions,
            elicitation_mode,
            elicitation_schema,
            elicitation_url,
            elicitation_message,
            mcp_server_name,
            network_host,
            network_protocol,
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
                ApprovalType::Permissions => "Permissions".to_string(),
            });
            let question_prompts =
                extract_question_prompts_for_approval(tool_input.as_deref(), question.as_deref());
            let resolved_question = question.or_else(|| {
                question_prompts
                    .first()
                    .map(|prompt| prompt.question.clone())
                    .filter(|text| !text.is_empty())
            });
            let preview = build_approval_preview(ApprovalPreviewInput {
                request_id: request_id.as_str(),
                approval_type,
                tool_name: Some(resolved_tool_name.as_str()),
                tool_input: tool_input.as_deref(),
                command: command.as_deref(),
                file_path: file_path.as_deref(),
                diff: diff.as_deref(),
                question: resolved_question.as_deref(),
                permission_reason: permission_reason.as_deref(),
            });

            let request = ApprovalRequest {
                id: request_id.clone(),
                session_id: sid.clone(),
                approval_type,
                tool_name: Some(resolved_tool_name.clone()),
                tool_input: tool_input.clone(),
                command: command.clone(),
                file_path: file_path.clone(),
                diff,
                question: resolved_question,
                question_prompts,
                preview,
                permission_reason: permission_reason.clone(),
                requested_permissions: requested_permissions.clone(),
                granted_permissions: None,
                proposed_amendment: proposed_amendment.clone(),
                permission_suggestions,
                elicitation_mode: elicitation_mode.clone(),
                elicitation_schema: elicitation_schema.clone(),
                elicitation_url: elicitation_url.clone(),
                elicitation_message: elicitation_message.clone(),
                mcp_server_name: mcp_server_name.clone(),
                network_host: network_host.clone(),
                network_protocol: network_protocol.clone(),
            };

            state.pending_approval = Some(request.clone());

            effects.push(Effect::Persist(Box::new(PersistOp::ApprovalRequested {
                session_id: sid.clone(),
                request_id,
                approval_type,
                tool_name: Some(resolved_tool_name),
                tool_input,
                command,
                file_path,
                diff: request.diff.clone(),
                question: request.question.clone(),
                question_prompts: request.question_prompts.clone(),
                preview: Box::new(request.preview.clone()),
                permission_reason: request.permission_reason.clone(),
                requested_permissions: request.requested_permissions.clone(),
                granted_permissions: request.granted_permissions.clone(),
                cwd: Some(state.project_path.clone()),
                proposed_amendment,
                permission_suggestions: request.permission_suggestions.clone(),
                elicitation_mode,
                elicitation_schema,
                elicitation_url,
                elicitation_message,
                mcp_server_name,
                network_host,
                network_protocol,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::ApprovalRequested {
                session_id: sid,
                request,
                approval_version: None, // Filled by actor after apply_state
            })));
        }

        // -- Approval cancelled (SDK cancelled pending can_use_tool) ----------
        Input::ApprovalCancelled { request_id } => {
            // Only clear if this cancellation matches the currently pending approval
            let is_current = matches!(
                &state.phase,
                WorkPhase::AwaitingApproval { request_id: pending_id, .. }
                    if *pending_id == request_id
            );
            if is_current {
                state.phase = WorkPhase::Working;
                state.pending_approval = None;
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
                        pending_approval: Some(None),
                        last_activity_at: Some(now.to_string()),
                        ..Default::default()
                    },
                })));
            }
        }

        // -- Permission mode (e.g. /plan entered from terminal) ---------------
        Input::PermissionModeChanged { mode } => {
            effects.push(Effect::Persist(Box::new(PersistOp::PermissionModeUpdate {
                session_id: sid.clone(),
                permission_mode: mode.clone(),
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                session_id: sid,
                changes: StateChanges {
                    permission_mode: Some(Some(mode)),
                    ..Default::default()
                },
            })));
        }

        // -- Metadata ---------------------------------------------------------
        Input::TokensUpdated {
            usage,
            snapshot_kind,
        } => {
            state.token_usage = usage.clone();
            state.token_usage_snapshot_kind = snapshot_kind;

            effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
                session_id: sid.clone(),
                usage: usage.clone(),
                snapshot_kind,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
                session_id: sid,
                usage,
                snapshot_kind,
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
            // Finalize any tool messages stuck at is_in_progress before ending
            effects.extend(finalize_in_progress_rows(
                &sid,
                &mut state.rows,
                state.total_row_count,
            ));

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
            repository_root,
            is_worktree,
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
            if repository_root.is_some() && repository_root != state.repository_root {
                state.repository_root = repository_root.clone();
                changed = true;
            }
            if let Some(wt) = is_worktree {
                if wt != state.is_worktree {
                    state.is_worktree = wt;
                    changed = true;
                }
            }

            if changed {
                state.last_activity_at = Some(now.to_string());

                effects.push(Effect::Persist(Box::new(PersistOp::EnvironmentUpdate {
                    session_id: sid.clone(),
                    cwd: state.current_cwd.clone(),
                    git_branch: state.git_branch.clone(),
                    git_sha: state.git_sha.clone(),
                    repository_root: state.repository_root.clone(),
                    is_worktree: Some(state.is_worktree),
                })));
                effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
                    session_id: sid,
                    changes: StateChanges {
                        current_cwd: Some(state.current_cwd.clone()),
                        git_branch: Some(state.git_branch.clone()),
                        git_sha: Some(state.git_sha.clone()),
                        last_activity_at: Some(now.to_string()),
                        repository_root: Some(state.repository_root.clone()),
                        is_worktree: Some(state.is_worktree),
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
            state.token_usage_snapshot_kind = TokenUsageSnapshotKind::CompactionReset;

            effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
                session_id: sid.clone(),
                usage: compacted_usage.clone(),
                snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
            })));
            effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
                session_id: sid.clone(),
                usage: compacted_usage,
                snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
            })));

            // Record compaction as a first-class transcript event so it is visible
            // in chat history and persisted in SQLite for reloads.
            let compact_seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
            let compact_entry = ConversationRowEntry {
                session_id: sid.clone(),
                sequence: compact_seq,
                turn_id: state.current_turn_id.clone(),
                row: ConversationRow::System(MessageRowContent {
                    id: format!("context-compacted-{}", uuid::Uuid::new_v4()),
                    content:
                        "Context compacted to keep this session within the model context window."
                            .to_string(),
                    turn_id: state.current_turn_id.clone(),
                    timestamp: Some(now.to_string()),
                    is_streaming: false,
                    images: vec![],
                    memory_citation: None,
                }),
            };
            state.rows.push(compact_entry.clone());
            state.total_row_count = compact_seq + 1;

            effects.push(Effect::Persist(Box::new(PersistOp::RowAppend {
                session_id: sid.clone(),
                entry: compact_entry.clone(),
            })));
            effects.push(Effect::Emit(Box::new(
                ServerMessage::ConversationRowsChanged {
                    session_id: sid.clone(),
                    upserted: vec![compact_entry.to_summary()],
                    removed_row_ids: vec![],
                    total_row_count: state.total_row_count,
                },
            )));
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

        Input::RateLimitEvent { info } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::RateLimitEvent {
                session_id: sid,
                info,
            })));
        }

        Input::PromptSuggestion { suggestion } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::PromptSuggestion {
                session_id: sid,
                suggestion,
            })));
        }
        Input::FilesPersisted { files } => {
            effects.push(Effect::Emit(Box::new(ServerMessage::FilesPersisted {
                session_id: sid,
                files,
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

pub struct ApprovalPreviewInput<'a> {
    pub request_id: &'a str,
    pub approval_type: ApprovalType,
    pub tool_name: Option<&'a str>,
    pub tool_input: Option<&'a str>,
    pub command: Option<&'a str>,
    pub file_path: Option<&'a str>,
    pub diff: Option<&'a str>,
    pub question: Option<&'a str>,
    pub permission_reason: Option<&'a str>,
}

pub fn approval_question_prompts(
    tool_input: Option<&str>,
    fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
    extract_question_prompts_for_approval(tool_input, fallback_question)
}

pub fn approval_question(
    tool_input: Option<&str>,
    fallback_question: Option<&str>,
) -> Option<String> {
    let prompts = approval_question_prompts(tool_input, fallback_question);
    prompts
        .first()
        .map(|prompt| prompt.question.clone())
        .filter(|text| !text.is_empty())
        .or_else(|| trim_non_empty(fallback_question))
}

pub fn approval_preview(input: ApprovalPreviewInput<'_>) -> Option<ApprovalPreview> {
    build_approval_preview(input)
}

fn build_approval_preview(input_data: ApprovalPreviewInput<'_>) -> Option<ApprovalPreview> {
    let ApprovalPreviewInput {
        request_id,
        approval_type,
        tool_name,
        tool_input,
        command,
        file_path,
        diff,
        question,
        permission_reason,
    } = input_data;

    let input = parse_tool_input_object(tool_input);
    let normalized_tool_name = trim_non_empty(tool_name)
        .map(|name| name.to_lowercase())
        .unwrap_or_default();

    let command_from_input = input
        .as_ref()
        .and_then(|dict| dict.get("command").or_else(|| dict.get("cmd")))
        .and_then(shell_command_from_json_value);
    let command = command_from_input.or_else(|| trim_non_empty(command));
    let risk_assessment = assess_approval_risk(approval_type, command.as_deref());

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
    let question = trim_non_empty(question);
    let patch_diff = trim_non_empty(diff).or_else(|| {
        input
            .as_ref()
            .and_then(|dict| diff_preview_from_patch_input(dict, file_path.as_deref()))
    });

    let ctx = ApprovalPreviewContext {
        request_id,
        approval_type,
        tool_name,
        normalized_tool_name: normalized_tool_name.as_str(),
        risk_assessment: &risk_assessment,
    };

    if approval_type == ApprovalType::Patch {
        if let Some(diff_preview) = patch_diff {
            return Some(compose_approval_preview(
                &ctx,
                ApprovalPreviewType::Diff,
                normalize_diff_preview(diff_preview.as_str()),
                vec![],
            ));
        }
    }

    if let Some(command) = command {
        let shell_segments = shell_segments_for_preview(&command);
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::ShellCommand,
            command,
            shell_segments,
        ));
    }

    if let Some(url) = url {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::Url,
            url,
            vec![],
        ));
    }

    if let Some(query) = query {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::SearchQuery,
            query,
            vec![],
        ));
    }

    if let Some(pattern) = pattern {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::Pattern,
            pattern,
            vec![],
        ));
    }

    if let Some(prompt) = prompt {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::Prompt,
            prompt,
            vec![],
        ));
    }

    if matches!(
        approval_type,
        ApprovalType::Question | ApprovalType::Permissions
    ) {
        if let Some(question) = question.or_else(|| permission_reason.map(str::to_string)) {
            return Some(compose_approval_preview(
                &ctx,
                ApprovalPreviewType::Prompt,
                question,
                vec![],
            ));
        }
    }

    if let Some(path) = file_path {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::FilePath,
            path,
            vec![],
        ));
    }

    if let Some(value) = fallback_input_value {
        return Some(compose_approval_preview(
            &ctx,
            ApprovalPreviewType::Value,
            value,
            vec![],
        ));
    }

    let fallback_action = match approval_type {
        ApprovalType::Question => {
            trim_non_empty(tool_name).unwrap_or_else(|| "Question".to_string())
        }
        ApprovalType::Permissions => {
            trim_non_empty(tool_name).unwrap_or_else(|| "Review requested permissions".to_string())
        }
        _ => trim_non_empty(tool_name)
            .map(|name| format!("Approve {name} action"))
            .unwrap_or_else(|| "Approve action".to_string()),
    };

    Some(compose_approval_preview(
        &ctx,
        ApprovalPreviewType::Action,
        fallback_action,
        vec![],
    ))
}

#[derive(Debug, Clone)]
struct ApprovalRiskAssessment {
    level: ApprovalRiskLevel,
    findings: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
struct ExecRiskRule {
    pattern: &'static str,
    finding: &'static str,
}

const EXEC_RISK_RULES: &[ExecRiskRule] = &[
    ExecRiskRule {
        pattern: " sudo ",
        finding: "Uses elevated privileges via sudo.",
    },
    ExecRiskRule {
        pattern: " rm -rf",
        finding: "Deletes files recursively with rm -rf.",
    },
    ExecRiskRule {
        pattern: " rm -fr",
        finding: "Deletes files recursively with rm -fr.",
    },
    ExecRiskRule {
        pattern: " git reset --hard",
        finding: "Performs hard git reset and discards local changes.",
    },
    ExecRiskRule {
        pattern: " git clean -fd",
        finding: "Deletes untracked files with git clean -fd.",
    },
    ExecRiskRule {
        pattern: " git clean -xdf",
        finding: "Deletes ignored and untracked files with git clean -xdf.",
    },
    ExecRiskRule {
        pattern: " git push --force",
        finding: "Force-pushes git history.",
    },
    ExecRiskRule {
        pattern: " git push -f",
        finding: "Force-pushes git history.",
    },
    ExecRiskRule {
        pattern: " drop table",
        finding: "Contains SQL DROP TABLE statement.",
    },
    ExecRiskRule {
        pattern: " drop database",
        finding: "Contains SQL DROP DATABASE statement.",
    },
    ExecRiskRule {
        pattern: " truncate table",
        finding: "Contains SQL TRUNCATE TABLE statement.",
    },
    ExecRiskRule {
        pattern: " chmod 777",
        finding: "Sets permissive file mode (chmod 777).",
    },
    ExecRiskRule {
        pattern: " curl | sh",
        finding: "Pipes remote script directly into shell (curl | sh).",
    },
    ExecRiskRule {
        pattern: " wget | sh",
        finding: "Pipes remote script directly into shell (wget | sh).",
    },
    ExecRiskRule {
        pattern: " dd if=",
        finding: "Uses dd with direct device/file writes.",
    },
    ExecRiskRule {
        pattern: " > /dev/",
        finding: "Writes output directly to a /dev device path.",
    },
    ExecRiskRule {
        pattern: " mkfs",
        finding: "Formats a filesystem with mkfs.",
    },
    ExecRiskRule {
        pattern: ":(){ :|:& };:",
        finding: "Contains a shell fork bomb signature.",
    },
];

fn assess_approval_risk(
    approval_type: ApprovalType,
    command: Option<&str>,
) -> ApprovalRiskAssessment {
    match approval_type {
        ApprovalType::Question => ApprovalRiskAssessment {
            level: ApprovalRiskLevel::Low,
            findings: vec![],
        },
        ApprovalType::Permissions => ApprovalRiskAssessment {
            level: ApprovalRiskLevel::Normal,
            findings: vec![],
        },
        ApprovalType::Patch => ApprovalRiskAssessment {
            level: ApprovalRiskLevel::Normal,
            findings: vec![],
        },
        ApprovalType::Exec => {
            let Some(normalized_command) = normalize_command_for_risk(command) else {
                return ApprovalRiskAssessment {
                    level: ApprovalRiskLevel::Normal,
                    findings: vec![],
                };
            };

            let mut findings: Vec<String> = vec![];
            for rule in EXEC_RISK_RULES {
                if normalized_command.contains(rule.pattern) {
                    let finding = rule.finding.to_string();
                    if !findings.contains(&finding) {
                        findings.push(finding);
                    }
                }
            }

            let level = if findings.is_empty() {
                ApprovalRiskLevel::Normal
            } else {
                ApprovalRiskLevel::High
            };
            ApprovalRiskAssessment { level, findings }
        }
    }
}

fn normalize_command_for_risk(command: Option<&str>) -> Option<String> {
    let normalized = trim_non_empty(command)?.to_lowercase();
    // Pad with spaces so token-boundary patterns like " sudo " can match start/end.
    Some(format!(" {normalized} "))
}

struct ApprovalPreviewContext<'a> {
    request_id: &'a str,
    approval_type: ApprovalType,
    tool_name: Option<&'a str>,
    normalized_tool_name: &'a str,
    risk_assessment: &'a ApprovalRiskAssessment,
}

fn compose_approval_preview(
    ctx: &ApprovalPreviewContext<'_>,
    preview_type: ApprovalPreviewType,
    value: String,
    shell_segments: Vec<ApprovalPreviewSegment>,
) -> ApprovalPreview {
    let compact = compact_detail_for_preview(
        preview_type,
        value.as_str(),
        shell_segments.as_slice(),
        ctx.normalized_tool_name,
    );
    let decision_scope = decision_scope_for_preview(preview_type).to_string();
    let manifest = build_manifest_for_preview(
        ctx,
        preview_type,
        value.as_str(),
        shell_segments.as_slice(),
        decision_scope.as_str(),
    );

    ApprovalPreview {
        preview_type,
        value,
        shell_segments,
        compact,
        decision_scope: Some(decision_scope),
        risk_level: Some(ctx.risk_assessment.level),
        risk_findings: ctx.risk_assessment.findings.clone(),
        manifest: Some(manifest),
    }
}

fn decision_scope_for_preview(preview_type: ApprovalPreviewType) -> &'static str {
    match preview_type {
        ApprovalPreviewType::ShellCommand => {
            "approve/deny applies to all command segments in this request."
        }
        ApprovalPreviewType::Diff | ApprovalPreviewType::FilePath => {
            "approve/deny applies to this full file action."
        }
        ApprovalPreviewType::Action
        | ApprovalPreviewType::Value
        | ApprovalPreviewType::Url
        | ApprovalPreviewType::SearchQuery
        | ApprovalPreviewType::Pattern
        | ApprovalPreviewType::Prompt => "approve/deny applies to this full tool action.",
    }
}

fn build_manifest_for_preview(
    ctx: &ApprovalPreviewContext<'_>,
    preview_type: ApprovalPreviewType,
    value: &str,
    shell_segments: &[ApprovalPreviewSegment],
    decision_scope: &str,
) -> String {
    let resolved_tool = trim_non_empty(ctx.tool_name).unwrap_or_else(|| "unknown".to_string());
    let resolved_request_id =
        trim_non_empty(Some(ctx.request_id)).unwrap_or_else(|| "unknown".to_string());

    let mut lines: Vec<String> = vec![
        "APPROVAL MANIFEST".to_string(),
        format!("request_id: {resolved_request_id}"),
        format!("approval_type: {}", approval_type_label(ctx.approval_type)),
        format!("tool: {resolved_tool}"),
        format!("risk_tier: {}", risk_level_label(ctx.risk_assessment.level)),
    ];

    if !ctx.risk_assessment.findings.is_empty() {
        lines.push("risk_signals:".to_string());
        lines.extend(
            ctx.risk_assessment
                .findings
                .iter()
                .map(|finding| format!("- {finding}")),
        );
    }

    lines.push(String::new());
    lines.push(format!("decision_scope: {decision_scope}"));
    lines.extend(manifest_content_lines(preview_type, value, shell_segments));

    lines.join("\n")
}

fn manifest_content_lines(
    preview_type: ApprovalPreviewType,
    value: &str,
    shell_segments: &[ApprovalPreviewSegment],
) -> Vec<String> {
    match preview_type {
        ApprovalPreviewType::ShellCommand => {
            let mut lines = vec![format!(
                "command_segments: {}",
                std::cmp::max(shell_segments.len(), 1)
            )];
            lines.push("segments:".to_string());
            if shell_segments.is_empty() {
                lines.push(format!("[1] {value}"));
                return lines;
            }

            lines.extend(shell_segments.iter().enumerate().map(|(index, segment)| {
                let prefix = shell_operator_prefix(segment.leading_operator.as_deref());
                format!("[{}] {}{}", index + 1, prefix, segment.command)
            }));
            lines
        }
        ApprovalPreviewType::Diff => {
            let lines: Vec<&str> = value.lines().collect();
            let mut content = vec![format!("diff_lines: {}", lines.len())];
            if let Some(target_file) = diff_target_file(value) {
                content.push(format!("target_file: {target_file}"));
            }
            content.push("diff_preview:".to_string());
            let preview_limit = 40usize;
            content.extend(
                lines
                    .iter()
                    .take(preview_limit)
                    .map(|line| (*line).to_string()),
            );
            if lines.len() > preview_limit {
                content.push(format!("... +{} more lines", lines.len() - preview_limit));
            }
            content
        }
        ApprovalPreviewType::FilePath => vec![format!("target_file: {value}")],
        ApprovalPreviewType::Url => vec![format!("target_url: {value}")],
        ApprovalPreviewType::SearchQuery => vec![format!("search_query: {value}")],
        ApprovalPreviewType::Pattern => vec![format!("pattern: {value}")],
        ApprovalPreviewType::Prompt => vec![format!("prompt: {value}")],
        ApprovalPreviewType::Value => vec![format!("value: {value}")],
        ApprovalPreviewType::Action => vec![format!("action: {value}")],
    }
}

fn shell_operator_prefix(leading_operator: Option<&str>) -> String {
    let Some(op) = leading_operator
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
    else {
        return String::new();
    };

    let meaning = match op {
        "||" => "if previous fails",
        "&&" => "if previous succeeds",
        "|" => "pipe output from previous",
        _ => "then",
    };
    format!("({op}, {meaning}) ")
}

fn approval_type_label(approval_type: ApprovalType) -> &'static str {
    match approval_type {
        ApprovalType::Exec => "exec",
        ApprovalType::Patch => "patch",
        ApprovalType::Question => "question",
        ApprovalType::Permissions => "permissions",
    }
}

fn risk_level_label(risk_level: ApprovalRiskLevel) -> &'static str {
    match risk_level {
        ApprovalRiskLevel::Low => "low",
        ApprovalRiskLevel::Normal => "normal",
        ApprovalRiskLevel::High => "high",
    }
}

fn parse_tool_input_object(tool_input: Option<&str>) -> Option<JsonMap<String, JsonValue>> {
    let raw = trim_non_empty(tool_input)?;
    let parsed: JsonValue = serde_json::from_str(&raw).ok()?;
    parsed.as_object().cloned()
}

fn parse_bool_value(value: Option<&JsonValue>) -> bool {
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

fn parse_question_options_from_json(value: Option<&JsonValue>) -> Vec<ApprovalQuestionOption> {
    let Some(options) = value.and_then(JsonValue::as_array) else {
        return vec![];
    };

    options
        .iter()
        .filter_map(|raw_option| {
            let option = raw_option.as_object()?;
            let label = option
                .get("label")
                .or_else(|| option.get("value"))
                .and_then(JsonValue::as_str)
                .and_then(trim_non_empty_str)?;
            let description = option
                .get("description")
                .and_then(JsonValue::as_str)
                .and_then(trim_non_empty_str);
            Some(ApprovalQuestionOption { label, description })
        })
        .collect()
}

fn parse_question_prompt_from_json(
    payload: &JsonMap<String, JsonValue>,
    fallback_id: &str,
) -> Option<ApprovalQuestionPrompt> {
    let id = payload
        .get("id")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)
        .unwrap_or_else(|| fallback_id.to_string());
    let header = payload
        .get("header")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str);
    let question = payload
        .get("question")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)
        .unwrap_or_else(|| "Question".to_string());
    if question.is_empty() {
        return None;
    }

    Some(ApprovalQuestionPrompt {
        id,
        header,
        question,
        options: parse_question_options_from_json(payload.get("options")),
        allows_multiple_selection: parse_bool_value(
            payload
                .get("multiSelect")
                .or_else(|| payload.get("multi_select")),
        ),
        allows_other: parse_bool_value(payload.get("isOther").or_else(|| payload.get("is_other"))),
        is_secret: parse_bool_value(payload.get("isSecret").or_else(|| payload.get("is_secret"))),
    })
}

fn parse_question_prompts_from_tool_input(tool_input: Option<&str>) -> Vec<ApprovalQuestionPrompt> {
    let Some(input) = parse_tool_input_object(tool_input) else {
        return vec![];
    };

    if let Some(raw_questions) = input.get("questions").and_then(JsonValue::as_array) {
        return raw_questions
            .iter()
            .enumerate()
            .filter_map(|(index, raw_question)| {
                let payload = raw_question.as_object()?;
                parse_question_prompt_from_json(payload, index.to_string().as_str())
            })
            .collect();
    }

    if input.contains_key("question") || input.contains_key("options") {
        if let Some(prompt) = parse_question_prompt_from_json(&input, "0") {
            return vec![prompt];
        }
    }

    vec![]
}

fn extract_question_prompts_for_approval(
    tool_input: Option<&str>,
    fallback_question: Option<&str>,
) -> Vec<ApprovalQuestionPrompt> {
    let prompts = parse_question_prompts_from_tool_input(tool_input);
    if !prompts.is_empty() {
        return prompts;
    }

    let Some(question) = trim_non_empty(fallback_question) else {
        return vec![];
    };

    vec![ApprovalQuestionPrompt {
        id: "0".to_string(),
        header: None,
        question,
        options: vec![],
        allows_multiple_selection: false,
        allows_other: true,
        is_secret: false,
    }]
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

const APPROVAL_DIFF_PREVIEW_MAX_CHARS: usize = 12_000;

fn diff_preview_from_patch_input(
    dict: &JsonMap<String, JsonValue>,
    fallback_file_path: Option<&str>,
) -> Option<String> {
    if let Some(explicit_diff) = dict
        .get("diff")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)
    {
        return Some(explicit_diff);
    }

    let file_path = dict
        .get("file_path")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)
        .or_else(|| fallback_file_path.and_then(trim_non_empty_str))
        .unwrap_or_else(|| "file".to_string());

    let old_string = dict.get("old_string").and_then(JsonValue::as_str);
    let new_string = dict.get("new_string").and_then(JsonValue::as_str);

    if old_string.is_some() || new_string.is_some() {
        return Some(render_patch_diff(
            file_path.as_str(),
            file_path.as_str(),
            old_string.unwrap_or_default(),
            new_string.unwrap_or_default(),
        ));
    }

    if let Some(content) = dict
        .get("content")
        .and_then(JsonValue::as_str)
        .and_then(trim_non_empty_str)
    {
        return Some(render_patch_diff(
            "/dev/null",
            file_path.as_str(),
            "",
            content.as_str(),
        ));
    }

    None
}

fn render_patch_diff(old_path: &str, new_path: &str, old_text: &str, new_text: &str) -> String {
    let mut lines = vec![
        format!("--- {old_path}"),
        format!("+++ {new_path}"),
        "@@".to_string(),
    ];

    lines.extend(old_text.lines().map(|line| format!("-{line}")));
    lines.extend(new_text.lines().map(|line| format!("+{line}")));

    if old_text.is_empty() && new_text.is_empty() {
        lines.push("(no textual changes provided)".to_string());
    }

    lines.join("\n")
}

fn normalize_diff_preview(diff: &str) -> String {
    let trimmed = diff.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let char_count = trimmed.chars().count();
    if char_count <= APPROVAL_DIFF_PREVIEW_MAX_CHARS {
        return trimmed.to_string();
    }

    let preview_len = APPROVAL_DIFF_PREVIEW_MAX_CHARS.saturating_sub(64);
    let preview: String = trimmed.chars().take(preview_len).collect();
    format!("{preview}\n... diff preview truncated ({char_count} chars total)")
}

fn diff_target_file(diff: &str) -> Option<String> {
    for line in diff.lines() {
        let Some(candidate) = line.strip_prefix("+++ ") else {
            continue;
        };
        let candidate = candidate.trim();
        if candidate.is_empty() || candidate == "/dev/null" {
            continue;
        }

        let normalized = candidate
            .strip_prefix("b/")
            .or_else(|| candidate.strip_prefix("a/"))
            .unwrap_or(candidate)
            .trim();

        if !normalized.is_empty() {
            return Some(normalized.to_string());
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
        ApprovalPreviewType::Diff => {
            let diff_lines = value.lines().count();
            if let Some(target_file) = diff_target_file(value) {
                let leaf = Path::new(target_file.as_str())
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(target_file.as_str());
                format!("{leaf} ({diff_lines} lines)")
            } else {
                format!("diff ({diff_lines} lines)")
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
    let mut heredoc_delimiter: Option<String> = None;

    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];

        // Inside a heredoc — consume everything until delimiter line.
        if let Some(ref delimiter) = heredoc_delimiter {
            buffer.push(ch);
            if ch == '\n' {
                // Look ahead: does the next line match the delimiter?
                let remaining: String = chars[index + 1..].iter().collect();
                let next_line = remaining.split('\n').next().unwrap_or("");
                if next_line.trim() == delimiter.as_str() {
                    // Consume the delimiter line into the buffer too.
                    for &dc in &chars[index + 1..] {
                        buffer.push(dc);
                        if dc == '\n' {
                            break;
                        }
                    }
                    // Advance index past the delimiter line.
                    let delim_line_len = next_line.len();
                    index += 1 + delim_line_len;
                    // Skip the trailing newline after the delimiter if present.
                    if index < chars.len() && chars[index] == '\n' {
                        index += 1;
                    }
                    heredoc_delimiter = None;
                    // Flush the heredoc as its own segment so the next
                    // command (after the delimiter line) starts fresh.
                    flush_shell_segment(&mut buffer, &mut segments, &mut pending_operator);
                    pending_operator = Some(";".to_string());
                    continue;
                }
            } else if index + 1 == chars.len() {
                // End of input while in heredoc — just close it.
                heredoc_delimiter = None;
            }
            index += 1;
            continue;
        }

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

        // Detect heredoc operator (<<, <<-, <<'DELIM', <<"DELIM")
        if can_split && ch == '<' && index + 1 < chars.len() && chars[index + 1] == '<' {
            buffer.push(ch);
            buffer.push(chars[index + 1]);
            let mut hd_index = index + 2;

            // Skip optional '-' (for <<- which strips leading tabs)
            if hd_index < chars.len() && chars[hd_index] == '-' {
                buffer.push(chars[hd_index]);
                hd_index += 1;
            }

            // Skip optional whitespace before delimiter
            while hd_index < chars.len() && chars[hd_index] == ' ' {
                buffer.push(chars[hd_index]);
                hd_index += 1;
            }

            // Extract delimiter (may be quoted with ' or ")
            let quote_char =
                if hd_index < chars.len() && (chars[hd_index] == '\'' || chars[hd_index] == '"') {
                    let q = Some(chars[hd_index]);
                    buffer.push(chars[hd_index]);
                    hd_index += 1;
                    q
                } else {
                    None
                };

            let delim_start = hd_index;
            while hd_index < chars.len() {
                let c = chars[hd_index];
                if let Some(q) = quote_char {
                    if c == q {
                        break;
                    }
                } else if !c.is_alphanumeric() && c != '_' {
                    break;
                }
                buffer.push(c);
                hd_index += 1;
            }

            let delim: String = chars[delim_start..hd_index].iter().collect();

            // Push closing quote if present
            if let Some(q) = quote_char {
                if hd_index < chars.len() && chars[hd_index] == q {
                    buffer.push(chars[hd_index]);
                    hd_index += 1;
                }
            }

            if !delim.is_empty() {
                heredoc_delimiter = Some(delim);
            }
            index = hd_index;
            continue;
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
    use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
    use orbitdock_protocol::{ApprovalPreviewType, ApprovalRiskLevel, TokenUsage};
    use serde_json::json;

    fn test_state() -> TransitionState {
        TransitionState {
            id: "test-session".to_string(),
            provider: Provider::Claude,
            revision: 0,
            phase: WorkPhase::Idle,
            rows: Vec::new(),
            total_row_count: 0,
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
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
            repository_root: None,
            is_worktree: false,
        }
    }

    fn test_user_row(content: &str) -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: String::new(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::User(MessageRowContent {
                id: format!("msg-{}", content.len()),
                content: content.to_string(),
                turn_id: None,
                timestamp: Some("0Z".to_string()),
                is_streaming: false,
                images: vec![],
                memory_citation: None,
            }),
        }
    }

    fn test_assistant_row(content: &str) -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: String::new(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::Assistant(MessageRowContent {
                id: format!("msg-{}", content.len()),
                content: content.to_string(),
                turn_id: None,
                timestamp: Some("0Z".to_string()),
                is_streaming: false,
                images: vec![],
                memory_citation: None,
            }),
        }
    }

    fn test_tool_row(id: &str, status: ToolStatus) -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: String::new(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::Tool(ToolRow {
                id: id.to_string(),
                provider: Provider::Claude,
                family: ToolFamily::Generic,
                kind: ToolKind::Generic,
                status,
                title: id.to_string(),
                subtitle: None,
                summary: None,
                preview: None,
                started_at: None,
                ended_at: None,
                duration_ms: None,
                grouping_key: None,
                invocation: json!({
                    "tool_name": "test",
                }),
                result: None,
                render_hints: RenderHints::default(),
                tool_display: None,
            }),
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
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
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
                    assert_eq!(
                        preview.decision_scope.as_deref(),
                        Some("approve/deny applies to all command segments in this request.")
                    );
                    assert_eq!(preview.risk_level, Some(ApprovalRiskLevel::High));
                    assert!(preview
                        .risk_findings
                        .iter()
                        .any(|finding| finding == "Deletes files recursively with rm -rf."));
                    assert!(preview
                        .manifest
                        .as_deref()
                        .is_some_and(|manifest| manifest.contains("APPROVAL MANIFEST")));
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
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
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
                    assert_eq!(preview.risk_level, Some(ApprovalRiskLevel::Normal));
                    assert!(preview.risk_findings.is_empty());
                    assert!(preview.manifest.as_deref().is_some_and(
                        |manifest| manifest.contains("[2] (||, if previous fails) echo two")
                    ));
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
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
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
                    assert_eq!(
                        preview.decision_scope.as_deref(),
                        Some("approve/deny applies to this full file action.")
                    );
                    assert!(preview.manifest.as_deref().is_some_and(|manifest| manifest
                        .contains("target_file: /tmp/OrbitDock/docs/approvals.md")));
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn approval_requested_preview_uses_diff_for_patch_requests_with_text_changes() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let (_, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-edit-diff".to_string(),
                approval_type: ApprovalType::Patch,
                tool_name: Some("Edit".to_string()),
                tool_input: Some(
                    r#"{"file_path":"/tmp/OrbitDock/docs/approvals.md","old_string":"line one","new_string":"line two"}"#
                        .to_string(),
                ),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
            },
            NOW,
        );

        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::ApprovalRequested { request, .. } => {
                    let preview = request.preview.as_ref().expect("expected preview");
                    assert_eq!(preview.preview_type, ApprovalPreviewType::Diff);
                    assert!(preview
                        .value
                        .contains("--- /tmp/OrbitDock/docs/approvals.md"));
                    assert!(preview
                        .value
                        .contains("+++ /tmp/OrbitDock/docs/approvals.md"));
                    assert!(preview.value.contains("-line one"));
                    assert!(preview.value.contains("+line two"));
                    assert!(preview
                        .compact
                        .as_deref()
                        .is_some_and(|compact| compact.contains("approvals.md")));
                    assert_eq!(
                        preview.decision_scope.as_deref(),
                        Some("approve/deny applies to this full file action.")
                    );
                    assert!(preview
                        .manifest
                        .as_deref()
                        .is_some_and(|manifest| manifest.contains("diff_preview:")));
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn build_approval_preview_covers_supported_non_shell_preview_types() {
        let cases: [(&str, ApprovalType, ApprovalPreviewType, &str, &str); 7] = [
            (
                r#"{"url":"https://example.com/docs"}"#,
                ApprovalType::Exec,
                ApprovalPreviewType::Url,
                "target_url: https://example.com/docs",
                "approve/deny applies to this full tool action.",
            ),
            (
                r#"{"query":"latest orbitdock release"}"#,
                ApprovalType::Exec,
                ApprovalPreviewType::SearchQuery,
                "search_query: latest orbitdock release",
                "approve/deny applies to this full tool action.",
            ),
            (
                r#"{"pattern":"session.resume.connector_failed"}"#,
                ApprovalType::Exec,
                ApprovalPreviewType::Pattern,
                "pattern: session.resume.connector_failed",
                "approve/deny applies to this full tool action.",
            ),
            (
                r#"{"prompt":"Summarize approval history"}"#,
                ApprovalType::Exec,
                ApprovalPreviewType::Prompt,
                "prompt: Summarize approval history",
                "approve/deny applies to this full tool action.",
            ),
            (
                r#"{"file_path":"/tmp/OrbitDock/README.md"}"#,
                ApprovalType::Patch,
                ApprovalPreviewType::FilePath,
                "target_file: /tmp/OrbitDock/README.md",
                "approve/deny applies to this full file action.",
            ),
            (
                r#"{"file_path":"/tmp/OrbitDock/README.md","old_string":"alpha","new_string":"beta"}"#,
                ApprovalType::Patch,
                ApprovalPreviewType::Diff,
                "diff_preview:",
                "approve/deny applies to this full file action.",
            ),
            (
                r#"{"foo":"bar"}"#,
                ApprovalType::Exec,
                ApprovalPreviewType::Value,
                "value: bar",
                "approve/deny applies to this full tool action.",
            ),
        ];

        for (
            tool_input,
            approval_type,
            expected_preview_type,
            expected_manifest_line,
            expected_scope,
        ) in cases
        {
            let preview = build_approval_preview(ApprovalPreviewInput {
                request_id: "req-matrix",
                approval_type,
                tool_name: Some("Bash"),
                tool_input: Some(tool_input),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                permission_reason: None,
            })
            .expect("expected preview");

            assert_eq!(preview.preview_type, expected_preview_type);
            assert_eq!(preview.decision_scope.as_deref(), Some(expected_scope));
            assert!(preview
                .manifest
                .as_deref()
                .is_some_and(|manifest| manifest.contains(expected_manifest_line)));
        }
    }

    #[test]
    fn build_approval_preview_uses_prompt_preview_with_scope_and_low_risk_for_question() {
        let preview = build_approval_preview(ApprovalPreviewInput {
            request_id: "req-question",
            approval_type: ApprovalType::Question,
            tool_name: Some("AskUserQuestion"),
            tool_input: None,
            command: None,
            file_path: None,
            diff: None,
            question: Some("How should we continue?"),
            permission_reason: None,
        })
        .expect("expected preview");

        assert_eq!(preview.preview_type, ApprovalPreviewType::Prompt);
        assert_eq!(preview.value, "How should we continue?");
        assert_eq!(
            preview.decision_scope.as_deref(),
            Some("approve/deny applies to this full tool action.")
        );
        assert_eq!(preview.risk_level, Some(ApprovalRiskLevel::Low));
        assert!(preview.risk_findings.is_empty());
        assert!(preview
            .manifest
            .as_deref()
            .is_some_and(|manifest| manifest.contains("prompt: How should we continue?")));
    }

    #[test]
    fn approval_requested_extracts_structured_question_prompts_from_tool_input() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;

        let question_input = r#"{
            "questions": [
                {
                    "id": "launch_mode",
                    "header": "Launch",
                    "question": "How do you want to launch?",
                    "options": [
                        { "label": "Open Sheet", "description": "Open the full sheet first" },
                        { "label": "Quick Launch", "description": "Use defaults now" }
                    ],
                    "multiSelect": true,
                    "isOther": true
                }
            ]
        }"#;

        let (_, effects) = transition(
            state,
            Input::ApprovalRequested {
                request_id: "req-question-metadata".to_string(),
                approval_type: ApprovalType::Question,
                tool_name: Some("AskUserQuestion".to_string()),
                tool_input: Some(question_input.to_string()),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                permission_reason: None,
                requested_permissions: None,
                proposed_amendment: None,
                permission_suggestions: None,
                elicitation_mode: None,
                elicitation_schema: None,
                elicitation_url: None,
                elicitation_message: None,
                mcp_server_name: None,
                network_host: None,
                network_protocol: None,
            },
            NOW,
        );

        if let Effect::Emit(message) = &effects[1] {
            match message.as_ref() {
                ServerMessage::ApprovalRequested { request, .. } => {
                    assert_eq!(
                        request.question.as_deref(),
                        Some("How do you want to launch?")
                    );
                    assert_eq!(request.question_prompts.len(), 1);
                    let prompt = &request.question_prompts[0];
                    assert_eq!(prompt.id, "launch_mode");
                    assert_eq!(prompt.header.as_deref(), Some("Launch"));
                    assert_eq!(prompt.options.len(), 2);
                    assert!(prompt.allows_multiple_selection);
                    assert!(prompt.allows_other);
                    assert!(!prompt.is_secret);
                }
                other => panic!("expected approval_requested emit, got {other:?}"),
            }
        }
    }

    #[test]
    fn row_created_appends_to_state() {
        let state = test_state();
        let entry = test_assistant_row("Hello world");

        let (new_state, effects) = transition(state, Input::RowCreated(entry), NOW);

        assert_eq!(new_state.rows.len(), 1);
        if let ConversationRow::Assistant(ref msg) = new_state.rows[0].row {
            assert_eq!(msg.content, "Hello world");
        } else {
            panic!("expected Assistant row");
        }
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn row_updated_mutates_existing_state_row() {
        let mut state = test_state();
        let mut entry = test_assistant_row("I");
        // Give it a known id
        if let ConversationRow::Assistant(ref mut msg) = entry.row {
            msg.id = "msg-stream".to_string();
        }
        entry.sequence = 1;
        state.rows.push(entry.clone());
        state.total_row_count = 1;

        // Build the updated entry
        let mut updated_entry = entry.clone();
        if let ConversationRow::Assistant(ref mut msg) = updated_entry.row {
            msg.content = "I'm now cross-checking the highest-risk claims".to_string();
        }

        let (new_state, effects) = transition(
            state,
            Input::RowUpdated {
                row_id: "msg-stream".to_string(),
                entry: updated_entry,
            },
            NOW,
        );

        assert_eq!(new_state.rows.len(), 1);
        if let ConversationRow::Assistant(ref msg) = new_state.rows[0].row {
            assert_eq!(msg.id, "msg-stream");
            assert_eq!(
                msg.content,
                "I'm now cross-checking the highest-risk claims"
            );
        } else {
            panic!("expected Assistant row");
        }
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn user_row_dedup_skips_echo() {
        let mut state = test_state();
        state.rows.push(test_user_row("do something"));

        let echo = test_user_row("do something");
        let (new_state, effects) = transition(state, Input::RowCreated(echo), NOW);

        // Should NOT add duplicate
        assert_eq!(new_state.rows.len(), 1);
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
        let last_row = new_state.rows.last().expect("expected compaction row");
        if let ConversationRow::System(ref msg) = last_row.row {
            assert_eq!(
                msg.content,
                "Context compacted to keep this session within the model context window."
            );
        } else {
            panic!("expected System row for compaction");
        }
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
        // Verify the error row was added to state
        let last_row = new_state.rows.last().unwrap();
        if let ConversationRow::System(ref msg) = last_row.row {
            assert!(msg.id.starts_with("error-"));
            assert_eq!(msg.content, "something broke");
        } else {
            panic!("expected System row for error");
        }
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

        let (new_state, effects) = transition(
            state,
            Input::TokensUpdated {
                usage: usage.clone(),
                snapshot_kind: TokenUsageSnapshotKind::Unknown,
            },
            NOW,
        );

        assert_eq!(new_state.token_usage.input_tokens, 100);
        assert_eq!(new_state.token_usage.output_tokens, 50);
        assert_eq!(
            new_state.token_usage_snapshot_kind,
            TokenUsageSnapshotKind::Unknown
        );
        assert_eq!(effects.len(), 2); // Persist + Emit
    }

    #[test]
    fn tokens_updated_persists_snapshot_kind() {
        let state = test_state();
        let usage = TokenUsage {
            input_tokens: 42,
            output_tokens: 17,
            cached_tokens: 5,
            context_window: 200_000,
        };

        let (_, effects) = transition(
            state,
            Input::TokensUpdated {
                usage,
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
            NOW,
        );

        assert!(matches!(
            effects.first(),
            Some(Effect::Persist(op))
                if matches!(
                    op.as_ref(),
                    PersistOp::TokensUpdate {
                        snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
                        ..
                    }
                )
        ));
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

        // Diff should be snapshotted into turn_diffs
        assert_eq!(new_state.turn_diffs.len(), 1);
        assert_eq!(new_state.turn_diffs[0].turn_id, "turn-1");
        assert!(new_state.turn_diffs[0].diff.contains("+new"));

        // Turn ID and current_diff should be cleared
        assert!(new_state.current_turn_id.is_none());
        assert!(
            new_state.current_diff.is_none(),
            "current_diff should be cleared after archiving into turn_diffs"
        );

        // Should emit TurnDiffSnapshot
        let has_snapshot = effects.iter().any(|e| matches!(
            e,
            Effect::Emit(ref msg) if matches!(msg.as_ref(), ServerMessage::TurnDiffSnapshot { .. })
        ));
        assert!(has_snapshot, "should emit TurnDiffSnapshot");

        // SessionDelta should clear current_diff
        let clears_diff = effects.iter().any(|e| match e {
            Effect::Emit(msg) => match msg.as_ref() {
                ServerMessage::SessionDelta { changes, .. } => changes.current_diff == Some(None),
                _ => false,
            },
            _ => false,
        });
        assert!(clears_diff, "SessionDelta should clear current_diff");
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

    // -- finalize_in_progress_rows tests --------------------------------------

    #[test]
    fn turn_completed_finalizes_in_progress_tool_rows() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state
            .rows
            .push(test_tool_row("tool-1", ToolStatus::Running));
        state
            .rows
            .push(test_tool_row("tool-2", ToolStatus::Completed));

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        // The running tool should now be Completed
        if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
            assert_eq!(
                t.status,
                ToolStatus::Completed,
                "tool-1 should be finalized"
            );
        } else {
            panic!("expected Tool row");
        }
        // The already-completed one stays Completed
        if let ConversationRow::Tool(ref t) = new_state.rows[1].row {
            assert_eq!(
                t.status,
                ToolStatus::Completed,
                "tool-2 should stay completed"
            );
        } else {
            panic!("expected Tool row");
        }

        // Should have finalize effects: RowUpsert for tool-1 + ConversationRowsChanged
        let finalize_persists: Vec<_> = effects
            .iter()
            .filter(|e| {
                matches!(e, Effect::Persist(op) if matches!(
                    op.as_ref(),
                    PersistOp::RowUpsert { ref entry, .. }
                        if entry.id() == "tool-1"
                ))
            })
            .collect();
        assert_eq!(finalize_persists.len(), 1);

        let finalize_emits: Vec<_> = effects
            .iter()
            .filter(|e| {
                matches!(e, Effect::Emit(msg) if matches!(
                    msg.as_ref(),
                    ServerMessage::ConversationRowsChanged { ref upserted, .. }
                        if upserted.iter().any(|u| u.id() == "tool-1")
                ))
            })
            .collect();
        assert_eq!(finalize_emits.len(), 1);
    }

    #[test]
    fn turn_aborted_finalizes_in_progress_tool_rows() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state
            .rows
            .push(test_tool_row("tool-1", ToolStatus::Running));

        let (new_state, effects) = transition(
            state,
            Input::TurnAborted {
                reason: "interrupted".to_string(),
            },
            NOW,
        );

        if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
            assert_eq!(
                t.status,
                ToolStatus::Completed,
                "tool-1 should be finalized"
            );
        } else {
            panic!("expected Tool row");
        }

        let has_finalize = effects.iter().any(|e| {
            matches!(
                e, Effect::Persist(op) if matches!(
                    op.as_ref(),
                    PersistOp::RowUpsert { ref entry, .. }
                        if entry.id() == "tool-1"
                )
            )
        });
        assert!(
            has_finalize,
            "TurnAborted should finalize in-progress tools"
        );
    }

    #[test]
    fn session_ended_finalizes_in_progress_tool_rows() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state
            .rows
            .push(test_tool_row("tool-1", ToolStatus::Running));

        let (new_state, effects) = transition(
            state,
            Input::SessionEnded {
                reason: "done".to_string(),
            },
            NOW,
        );

        if let ConversationRow::Tool(ref t) = new_state.rows[0].row {
            assert_eq!(
                t.status,
                ToolStatus::Completed,
                "tool-1 should be finalized"
            );
        } else {
            panic!("expected Tool row");
        }

        let has_finalize = effects.iter().any(|e| {
            matches!(
                e, Effect::Persist(op) if matches!(
                    op.as_ref(),
                    PersistOp::RowUpsert { ref entry, .. }
                        if entry.id() == "tool-1"
                )
            )
        });
        assert!(
            has_finalize,
            "SessionEnded should finalize in-progress tools"
        );
    }

    #[test]
    fn no_cleanup_effects_when_no_in_progress_rows() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state
            .rows
            .push(test_tool_row("tool-1", ToolStatus::Completed));
        state
            .rows
            .push(test_tool_row("tool-2", ToolStatus::Completed));

        let (_, effects) = transition(state, Input::TurnCompleted, NOW);

        // Only session status effects (Persist + Emit), no RowUpsert effects for finalization
        let row_upserts: Vec<_> = effects
            .iter()
            .filter(|e| matches!(e, Effect::Persist(op) if matches!(op.as_ref(), PersistOp::RowUpsert { .. })))
            .collect();
        assert!(
            row_upserts.is_empty(),
            "no RowUpsert effects when nothing to finalize"
        );
    }

    #[test]
    fn shell_segments_heredoc_single_quote_kept_as_one_segment() {
        let cmd = "cat <<'EOF' > /tmp/plan.md\n# Plan\n\nStep 1\nStep 2\nEOF";
        let segments = shell_segments_for_preview(cmd);
        assert_eq!(
            segments.len(),
            1,
            "heredoc should be a single segment, got: {segments:?}"
        );
        assert!(segments[0].command.contains("# Plan"));
        assert!(segments[0].command.contains("EOF"));
    }

    #[test]
    fn shell_segments_heredoc_double_quote_kept_as_one_segment() {
        let cmd = "cat <<\"END\" > /tmp/out.txt\nline 1\nline 2\nEND";
        let segments = shell_segments_for_preview(cmd);
        assert_eq!(
            segments.len(),
            1,
            "heredoc should be a single segment, got: {segments:?}"
        );
    }

    #[test]
    fn shell_segments_heredoc_unquoted_kept_as_one_segment() {
        let cmd = "cat <<MARKER\nfoo\nbar\nMARKER";
        let segments = shell_segments_for_preview(cmd);
        assert_eq!(
            segments.len(),
            1,
            "heredoc should be a single segment, got: {segments:?}"
        );
    }

    #[test]
    fn shell_segments_heredoc_with_dash_strip_tabs() {
        let cmd = "cat <<-EOF\n\tfoo\n\tbar\nEOF";
        let segments = shell_segments_for_preview(cmd);
        assert_eq!(
            segments.len(),
            1,
            "<<- heredoc should be a single segment, got: {segments:?}"
        );
    }

    #[test]
    fn shell_segments_heredoc_then_next_command() {
        let cmd = "cat <<'EOF' > /tmp/file.md\ncontent\nEOF\ncd /tmp && gh issue create --body-file file.md";
        let segments = shell_segments_for_preview(cmd);
        assert_eq!(
            segments.len(),
            3,
            "expected heredoc + cd + gh, got: {segments:?}"
        );
        assert!(segments[0].command.starts_with("cat <<"));
        assert_eq!(segments[1].command, "cd /tmp");
        assert_eq!(segments[2].leading_operator.as_deref(), Some("&&"));
    }

    #[test]
    fn multiple_in_progress_rows_all_finalized() {
        let mut state = test_state();
        state.phase = WorkPhase::Working;
        state
            .rows
            .push(test_tool_row("tool-1", ToolStatus::Running));
        state
            .rows
            .push(test_tool_row("tool-2", ToolStatus::Running));
        state
            .rows
            .push(test_tool_row("tool-3", ToolStatus::Running));

        let (new_state, effects) = transition(state, Input::TurnCompleted, NOW);

        // All three should be finalized
        for entry in &new_state.rows {
            if let ConversationRow::Tool(ref t) = entry.row {
                assert_eq!(
                    t.status,
                    ToolStatus::Completed,
                    "tool {} should be finalized",
                    t.id
                );
            } else {
                panic!("expected Tool row");
            }
        }

        // Should have 3 RowUpsert persist effects + 1 ConversationRowsChanged emit
        let row_upserts: Vec<_> = effects
            .iter()
            .filter(|e| matches!(e, Effect::Persist(op) if matches!(op.as_ref(), PersistOp::RowUpsert { .. })))
            .collect();
        assert_eq!(row_upserts.len(), 3);

        // finalize_in_progress_rows emits a single ConversationRowsChanged with all upserted
        let row_changed_emits: Vec<_> = effects
            .iter()
            .filter(|e| matches!(e, Effect::Emit(msg) if matches!(msg.as_ref(), ServerMessage::ConversationRowsChanged { .. })))
            .collect();
        assert_eq!(row_changed_emits.len(), 1);
    }
}
