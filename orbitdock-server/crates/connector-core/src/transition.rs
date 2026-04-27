//! Pure state transition function
//!
//! All business logic for session state changes lives here as a pure,
//! synchronous function: `transition(state, input) -> (state, effects)`.
//! No IO, no async, no locking — fully unit-testable.

use std::collections::HashMap;

use crate::approval_preview::{approval_preview, approval_question_prompts, ApprovalPreviewInput};
use crate::{ConnectorOutput, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent, TurnStatus,
};
#[cfg(test)]
use orbitdock_protocol::domain_events::ToolFamily;
use orbitdock_protocol::domain_events::ToolStatus;
use orbitdock_protocol::{
  ApprovalPreview, ApprovalQuestionPrompt, ApprovalRequest, ApprovalType, McpAuthStatus,
  McpResource, McpResourceTemplate, McpStartupFailure, McpStartupStatus, McpTool, Provider,
  ServerMessage, SessionStatus, SkillErrorInfo, SkillsListEntry, StateChanges, SubagentInfo,
  TokenUsage, TokenUsageSnapshotKind, TurnDiff, WorkStatus,
};

#[path = "transition_rows.rs"]
mod transition_rows;

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
  pub last_progress_at: Option<String>,
  pub current_turn_id: Option<String>,
  pub turn_count: u64,
  pub turn_diffs: Vec<TurnDiff>,
  pub git_branch: Option<String>,
  pub git_sha: Option<String>,
  pub current_cwd: Option<String>,
  pub pending_approval: Option<ApprovalRequest>,
  pub repository_root: Option<String>,
  pub is_worktree: bool,
  pub model: Option<String>,
  pub transcript_path: Option<String>,
  pub last_tool: Option<String>,
  pub pending_tool_name: Option<String>,
  pub pending_tool_input: Option<String>,
  pub pending_question: Option<String>,
  pub subagents: Vec<SubagentInfo>,
  pub summary: Option<String>,
  pub effort: Option<String>,
  pub first_prompt: Option<String>,
  /// Per-turn token accumulators — reset at TurnStarted, used for ledger entries.
  /// Separate from `token_usage` which tracks lifetime accumulated values.
  pub turn_input_tokens: u64,
  pub turn_output_tokens: u64,
  pub turn_cached_tokens: u64,
  /// Provider-normalized turn-final usage snapshot, when the connector can
  /// supply one that is more authoritative than live display snapshots.
  pub turn_usage_snapshot: Option<TokenUsage>,
  pub turn_usage_snapshot_kind: Option<TokenUsageSnapshotKind>,
}

// ---------------------------------------------------------------------------
// Input — one variant per reducer-safe ConnectorStateEvent
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
  TurnUsageUpdated {
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
  TranscriptPathUpdated(Option<String>),
  AttentionUpdated {
    attention_reason: Option<Option<String>>,
    last_tool: Option<String>,
    pending_tool_name: Option<Option<String>>,
    pending_tool_input: Option<Option<String>>,
    pending_question: Option<Option<String>>,
  },
  SubagentsUpdated {
    subagents: Vec<SubagentInfo>,
  },
  SummaryUpdated(String),
  EffortUpdated(Option<String>),
  FirstPromptCaptured(String),
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

impl From<ConnectorStateEvent> for Input {
  fn from(event: ConnectorStateEvent) -> Self {
    match event {
      ConnectorStateEvent::TurnStarted => Input::TurnStarted,
      ConnectorStateEvent::TurnCompleted => Input::TurnCompleted,
      ConnectorStateEvent::TurnAborted { reason } => Input::TurnAborted { reason },
      ConnectorStateEvent::ConversationRowCreated(entry) => Input::RowCreated(entry),
      ConnectorStateEvent::ConversationRowUpdated { row_id, entry } => {
        Input::RowUpdated { row_id, entry }
      }
      ConnectorStateEvent::ApprovalRequested {
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
      ConnectorStateEvent::TokensUpdated {
        usage,
        snapshot_kind,
      } => Input::TokensUpdated {
        usage,
        snapshot_kind,
      },
      ConnectorStateEvent::TurnUsageUpdated {
        usage,
        snapshot_kind,
      } => Input::TurnUsageUpdated {
        usage,
        snapshot_kind,
      },
      ConnectorStateEvent::DiffUpdated(diff) => Input::DiffUpdated(diff),
      ConnectorStateEvent::PlanUpdated(plan) => Input::PlanUpdated(plan),
      ConnectorStateEvent::ThreadNameUpdated(name) => Input::ThreadNameUpdated(name),
      ConnectorStateEvent::SessionEnded { reason } => Input::SessionEnded { reason },
      ConnectorStateEvent::SkillsList { skills, errors } => Input::SkillsList { skills, errors },
      ConnectorStateEvent::SkillsUpdateAvailable => Input::SkillsUpdateAvailable,
      ConnectorStateEvent::McpToolsList {
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
      ConnectorStateEvent::McpStartupUpdate { server, status } => {
        Input::McpStartupUpdate { server, status }
      }
      ConnectorStateEvent::McpStartupComplete {
        ready,
        failed,
        cancelled,
      } => Input::McpStartupComplete {
        ready,
        failed,
        cancelled,
      },
      ConnectorStateEvent::ClaudeInitialized {
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
      ConnectorStateEvent::ModelUpdated(model) => Input::ModelUpdated(model),
      ConnectorStateEvent::ContextCompacted => Input::ContextCompacted,
      ConnectorStateEvent::UndoStarted { message } => Input::UndoStarted { message },
      ConnectorStateEvent::UndoCompleted { success, message } => {
        Input::UndoCompleted { success, message }
      }
      ConnectorStateEvent::ThreadRolledBack { num_turns } => Input::ThreadRolledBack { num_turns },
      ConnectorStateEvent::EnvironmentChanged {
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
      ConnectorStateEvent::ApprovalCancelled { request_id } => {
        Input::ApprovalCancelled { request_id }
      }
      ConnectorStateEvent::PermissionModeChanged { mode } => Input::PermissionModeChanged { mode },
      ConnectorStateEvent::RateLimitEvent { info } => Input::RateLimitEvent { info },
      ConnectorStateEvent::PromptSuggestion { suggestion } => {
        Input::PromptSuggestion { suggestion }
      }
      ConnectorStateEvent::FilesPersisted { files } => Input::FilesPersisted { files },
      ConnectorStateEvent::Error(msg) => Input::Error(msg),
      ConnectorStateEvent::SubagentsUpdated { subagents } => Input::SubagentsUpdated { subagents },
    }
  }
}

impl TryFrom<ConnectorOutput> for Input {
  type Error = ConnectorOutput;

  fn try_from(output: ConnectorOutput) -> Result<Self, ConnectorOutput> {
    output.into_state_event().map(Input::from)
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
    last_progress_at: Option<String>,
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
    diff: Option<String>,
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
  SetTranscriptPath {
    session_id: String,
    transcript_path: Option<String>,
  },
  AttentionUpdate {
    session_id: String,
    attention_reason: Option<Option<String>>,
    last_tool: Option<Option<String>>,
    last_tool_at: Option<Option<String>>,
    pending_tool_name: Option<Option<String>>,
    pending_tool_input: Option<Option<String>>,
    pending_question: Option<Option<String>>,
  },
  UpsertSubagents {
    session_id: String,
    subagents: Vec<SubagentInfo>,
  },
  SetSummary {
    session_id: String,
    summary: String,
  },
  EffortUpdate {
    session_id: String,
    effort: Option<String>,
  },
  FirstPromptCaptured {
    session_id: String,
    first_prompt: String,
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
      ConversationRow::Tool(ref mut tool) if tool.status == ToolStatus::Running => {
        tool.status = ToolStatus::Completed;
        finalized_entries.push(entry.clone());
        effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
          session_id: sid.to_string(),
          entry: entry.clone(),
        })));
      }
      ConversationRow::Assistant(ref mut msg)
      | ConversationRow::Thinking(ref mut msg)
      | ConversationRow::System(ref mut msg)
        if msg.is_streaming =>
      {
        msg.is_streaming = false;
        finalized_entries.push(entry.clone());
        effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
          session_id: sid.to_string(),
          entry: entry.clone(),
        })));
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
// Subagent merge helpers (pure)
// ---------------------------------------------------------------------------

/// Merge incoming subagent updates into the existing list by ID (upsert).
pub fn merge_subagent_updates(
  existing: &[SubagentInfo],
  incoming: Vec<SubagentInfo>,
) -> Vec<SubagentInfo> {
  let mut merged = existing.to_vec();
  for updated in incoming {
    if let Some(index) = merged.iter().position(|s| s.id == updated.id) {
      merged[index] = updated;
    } else {
      merged.push(updated);
    }
  }
  merged.sort_by(|lhs, rhs| lhs.started_at.cmp(&rhs.started_at));
  merged
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
      state.last_progress_at = Some(now.to_string());
      state.turn_count += 1;
      let turn_id = format!("turn-{}", state.turn_count);
      state.current_turn_id = Some(turn_id.clone());
      state.turn_input_tokens = 0;
      state.turn_output_tokens = 0;
      state.turn_cached_tokens = 0;
      state.turn_usage_snapshot = None;
      state.turn_usage_snapshot_kind = None;

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(WorkStatus::Working),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid,
        changes: Box::new(StateChanges {
          work_status: Some(WorkStatus::Working),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
          current_turn_id: Some(Some(turn_id)),
          turn_count: Some(state.turn_count),
          ..Default::default()
        }),
      })));
    }

    Input::TurnCompleted => {
      // Always persist usage for this turn. Archive diff snapshot if one exists.
      if let Some(turn_id) = state.current_turn_id.as_ref() {
        let diff = state.current_diff.clone();

        // Use provider-finalized turn usage when available. Otherwise fall back
        // to accumulated per-call usage for providers that only expose mixed
        // live snapshots.
        let turn_usage = state.turn_usage_snapshot.clone().unwrap_or(TokenUsage {
          input_tokens: state.turn_input_tokens,
          output_tokens: state.turn_output_tokens,
          cached_tokens: state.turn_cached_tokens,
          context_window: state.token_usage.context_window,
        });
        let turn_snapshot_kind = state
          .turn_usage_snapshot_kind
          .unwrap_or(state.token_usage_snapshot_kind);

        if let Some(ref d) = diff {
          let snapshot = TurnDiff {
            turn_id: turn_id.clone(),
            diff: d.clone(),
            token_usage: Some(turn_usage.clone()),
            snapshot_kind: Some(turn_snapshot_kind),
          };
          state.turn_diffs.push(snapshot);
        }

        effects.push(Effect::Persist(Box::new(PersistOp::TurnDiffInsert {
          session_id: sid.clone(),
          turn_id: turn_id.clone(),
          turn_seq: state.turn_count,
          diff: diff.clone(),
          input_tokens: turn_usage.input_tokens,
          output_tokens: turn_usage.output_tokens,
          cached_tokens: turn_usage.cached_tokens,
          context_window: turn_usage.context_window,
          snapshot_kind: turn_snapshot_kind,
        })));

        if let Some(ref d) = diff {
          effects.push(Effect::Emit(Box::new(ServerMessage::TurnDiffSnapshot {
            session_id: sid.clone(),
            turn_id: turn_id.clone(),
            diff: d.clone(),
            input_tokens: Some(turn_usage.input_tokens),
            output_tokens: Some(turn_usage.output_tokens),
            cached_tokens: Some(turn_usage.cached_tokens),
            context_window: Some(turn_usage.context_window),
            snapshot_kind: turn_snapshot_kind,
          })));
        }
      }

      // Reset per-turn accumulators
      state.turn_input_tokens = 0;
      state.turn_output_tokens = 0;
      state.turn_cached_tokens = 0;
      state.turn_usage_snapshot = None;
      state.turn_usage_snapshot_kind = None;

      // Clear current_diff now that it has been archived into turn_diffs
      state.current_diff = None;

      // Recompute cumulative diff (completed turns only, no current_diff)
      let cumulative =
        orbitdock_protocol::diff_merge::compute_cumulative_diff(&state.turn_diffs, None);

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
      state.last_progress_at = Some(now.to_string());
      state.current_turn_id = None;

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid,
        changes: Box::new(StateChanges {
          work_status: Some(WorkStatus::Waiting),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
          current_turn_id: Some(None),
          current_diff: Some(None),
          cumulative_diff: Some(cumulative),
          ..Default::default()
        }),
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
        state.last_progress_at = Some(now.to_string());
        state.current_turn_id = None;
        state.turn_input_tokens = 0;
        state.turn_output_tokens = 0;
        state.turn_cached_tokens = 0;
        state.turn_usage_snapshot = None;
        state.turn_usage_snapshot_kind = None;

        effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
          id: sid.clone(),
          status: None,
          work_status: Some(WorkStatus::Waiting),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
        })));
        effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
          session_id: sid,
          changes: Box::new(StateChanges {
            work_status: Some(WorkStatus::Waiting),
            last_activity_at: Some(now.to_string()),
            last_progress_at: Some(now.to_string()),
            current_turn_id: Some(None),
            ..Default::default()
          }),
        })));
      }
    }

    Input::Error(msg) => {
      state.last_activity_at = Some(now.to_string());
      state.last_progress_at = Some(now.to_string());

      // Create an error row so the user sees what happened
      let seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
      let entry = ConversationRowEntry {
        session_id: sid.clone(),
        sequence: seq,
        turn_id: state.current_turn_id.clone(),
        turn_status: TurnStatus::Active,
        row: ConversationRow::System(MessageRowContent {
          id: format!("error-{}", uuid::Uuid::new_v4()),
          content: msg,
          turn_id: state.current_turn_id.clone(),
          timestamp: Some(now.to_string()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
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
    }

    // -- Conversation rows ------------------------------------------------
    Input::RowCreated(mut entry) => {
      transition_rows::handle_row_created(&mut state, &sid, &mut entry, now, &mut effects);
    }

    Input::RowUpdated { row_id, mut entry } => {
      transition_rows::handle_row_updated(&mut state, &sid, row_id, &mut entry, now, &mut effects);
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
      state.last_progress_at = Some(now.to_string());

      // Use real tool_name from connector when available, fall back to type-based name
      let resolved_tool_name = tool_name.unwrap_or_else(|| match approval_type {
        ApprovalType::Exec => "Bash".to_string(),
        ApprovalType::Patch => "Edit".to_string(),
        ApprovalType::Question => "Question".to_string(),
        ApprovalType::Permissions => "Permissions".to_string(),
      });
      let question_prompts = approval_question_prompts(tool_input.as_deref(), question.as_deref());
      let resolved_question = question.or_else(|| {
        question_prompts
          .first()
          .map(|prompt| prompt.question.clone())
          .filter(|text| !text.is_empty())
      });
      let preview = approval_preview(ApprovalPreviewInput {
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

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(state.phase.to_work_status()),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
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
        request: Box::new(request),
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
        state.last_progress_at = Some(now.to_string());

        effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
          id: sid.clone(),
          status: None,
          work_status: Some(WorkStatus::Working),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
        })));
        effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
          session_id: sid,
          changes: Box::new(StateChanges {
            work_status: Some(WorkStatus::Working),
            pending_approval: Some(None),
            last_activity_at: Some(now.to_string()),
            last_progress_at: Some(now.to_string()),
            ..Default::default()
          }),
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
        changes: Box::new(StateChanges {
          permission_mode: Some(Some(mode)),
          ..Default::default()
        }),
      })));
    }

    // -- Metadata ---------------------------------------------------------
    Input::TokensUpdated {
      usage,
      snapshot_kind,
    } => {
      match snapshot_kind {
        TokenUsageSnapshotKind::Mixed => {
          // input/cached are per-call context values — keep as-is for context
          // fill display (input+cached / context_window). Only output accumulates
          // because the connector sends per-call output tokens.
          state.token_usage.input_tokens = usage.input_tokens;
          state.token_usage.output_tokens += usage.output_tokens;
          state.token_usage.cached_tokens = usage.cached_tokens;
          state.token_usage.context_window = usage.context_window;

          // Per-turn tracking for ledger entries (reset at TurnStarted).
          // These DO accumulate all three dimensions for accurate billing.
          state.turn_input_tokens += usage.input_tokens;
          state.turn_output_tokens += usage.output_tokens;
          state.turn_cached_tokens += usage.cached_tokens;
        }
        _ => {
          state.token_usage = usage;
        }
      }
      state.token_usage_snapshot_kind = snapshot_kind;

      // Emit/persist the accumulated lifetime values (not raw per-call)
      effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
        session_id: sid.clone(),
        usage: state.token_usage.clone(),
        snapshot_kind,
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
        session_id: sid,
        usage: state.token_usage.clone(),
        snapshot_kind,
      })));
    }

    Input::TurnUsageUpdated {
      usage,
      snapshot_kind,
    } => {
      state.turn_usage_snapshot = Some(usage);
      state.turn_usage_snapshot_kind = Some(snapshot_kind);
    }

    Input::DiffUpdated(diff) => {
      state.current_diff = Some(diff.clone());
      let cumulative =
        orbitdock_protocol::diff_merge::compute_cumulative_diff(&state.turn_diffs, Some(&diff));

      effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
        session_id: sid.clone(),
        diff: Some(diff.clone()),
        plan: None,
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid,
        changes: Box::new(StateChanges {
          current_diff: Some(Some(diff)),
          cumulative_diff: Some(cumulative),
          ..Default::default()
        }),
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
        changes: Box::new(StateChanges {
          current_plan: Some(Some(plan)),
          ..Default::default()
        }),
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
        changes: Box::new(StateChanges {
          custom_name: Some(Some(name)),
          ..Default::default()
        }),
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
      state.last_progress_at = Some(now.to_string());

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
      state.last_progress_at = Some(now.to_string());

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(WorkStatus::Working),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid.clone(),
        changes: Box::new(StateChanges {
          work_status: Some(WorkStatus::Working),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
          ..Default::default()
        }),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::UndoStarted {
        session_id: sid,
        message,
      })));
    }

    Input::UndoCompleted { success, message } => {
      state.phase = WorkPhase::Idle;
      state.last_activity_at = Some(now.to_string());
      state.last_progress_at = Some(now.to_string());

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid.clone(),
        changes: Box::new(StateChanges {
          work_status: Some(WorkStatus::Waiting),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
          ..Default::default()
        }),
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
      state.last_progress_at = Some(now.to_string());

      effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
        id: sid.clone(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        last_activity_at: Some(now.to_string()),
        last_progress_at: Some(now.to_string()),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid.clone(),
        changes: Box::new(StateChanges {
          work_status: Some(WorkStatus::Waiting),
          last_activity_at: Some(now.to_string()),
          last_progress_at: Some(now.to_string()),
          ..Default::default()
        }),
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
        state.last_progress_at = Some(now.to_string());

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
          changes: Box::new(StateChanges {
            current_cwd: Some(state.current_cwd.clone()),
            git_branch: Some(state.git_branch.clone()),
            git_sha: Some(state.git_sha.clone()),
            last_activity_at: Some(now.to_string()),
            last_progress_at: Some(now.to_string()),
            repository_root: Some(state.repository_root.clone()),
            is_worktree: Some(state.is_worktree),
            ..Default::default()
          }),
        })));
      }
    }

    // -- Model ---------------------------------------------------------------
    Input::ModelUpdated(model) => {
      state.model = Some(model.clone());
      effects.push(Effect::Persist(Box::new(PersistOp::ModelUpdate {
        session_id: sid.clone(),
        model: model.clone(),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid,
        changes: Box::new(StateChanges {
          model: Some(Some(model)),
          ..Default::default()
        }),
      })));
    }

    // -- Transcript path ---------------------------------------------------
    Input::TranscriptPathUpdated(path) => {
      state.transcript_path = path.clone();
      effects.push(Effect::Persist(Box::new(PersistOp::SetTranscriptPath {
        session_id: sid,
        transcript_path: path,
      })));
    }

    // -- Attention (last_tool, pending tool/input/question) ----------------
    Input::AttentionUpdated {
      attention_reason,
      last_tool,
      pending_tool_name,
      pending_tool_input,
      pending_question,
    } => {
      let has_last_tool = last_tool.is_some();
      if let Some(ref tool) = last_tool {
        state.last_tool = Some(tool.clone());
      }
      if let Some(ref name) = pending_tool_name {
        state.pending_tool_name = name.clone();
      }
      if let Some(ref input) = pending_tool_input {
        state.pending_tool_input = input.clone();
      }
      if let Some(ref question) = pending_question {
        state.pending_question = question.clone();
      }

      effects.push(Effect::Persist(Box::new(PersistOp::AttentionUpdate {
        session_id: sid,
        attention_reason,
        last_tool: last_tool.map(Some),
        last_tool_at: if has_last_tool {
          Some(Some(now.to_string()))
        } else {
          None
        },
        pending_tool_name,
        pending_tool_input,
        pending_question,
      })));
    }

    // -- Subagents ---------------------------------------------------------
    Input::SubagentsUpdated { subagents } => {
      let merged = merge_subagent_updates(&state.subagents, subagents);
      if merged != state.subagents {
        state.subagents = merged.clone();
        effects.push(Effect::Persist(Box::new(PersistOp::UpsertSubagents {
          session_id: sid.clone(),
          subagents: merged.clone(),
        })));
        effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
          session_id: sid,
          changes: Box::new(StateChanges {
            subagents: Some(merged),
            ..Default::default()
          }),
        })));
      }
    }

    // -- Summary -----------------------------------------------------------
    Input::SummaryUpdated(summary) => {
      if state.summary.as_ref() != Some(&summary) {
        state.summary = Some(summary.clone());
        effects.push(Effect::Persist(Box::new(PersistOp::SetSummary {
          session_id: sid.clone(),
          summary: summary.clone(),
        })));
        effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
          session_id: sid,
          changes: Box::new(StateChanges {
            summary: Some(Some(summary)),
            ..Default::default()
          }),
        })));
      }
    }

    // -- Effort -------------------------------------------------------------
    Input::EffortUpdated(effort) => {
      if state.effort != effort {
        state.effort = effort.clone();
        effects.push(Effect::Persist(Box::new(PersistOp::EffortUpdate {
          session_id: sid.clone(),
          effort: effort.clone(),
        })));
        effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
          session_id: sid,
          changes: Box::new(StateChanges {
            effort: Some(effort),
            ..Default::default()
          }),
        })));
      }
    }

    // -- First prompt -------------------------------------------------------
    Input::FirstPromptCaptured(prompt) => {
      state.first_prompt = Some(prompt.clone());
      effects.push(Effect::Persist(Box::new(PersistOp::FirstPromptCaptured {
        session_id: sid.clone(),
        first_prompt: prompt.clone(),
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
        session_id: sid,
        changes: Box::new(StateChanges {
          first_prompt: Some(Some(prompt)),
          ..Default::default()
        }),
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
      state.last_progress_at = Some(now.to_string());
      // Preserve accumulated lifetime totals — compaction resets context, not history.
      // The CompactionReset snapshot kind tells the DB handler to zero context_* columns
      // while keeping lifetime_* and snapshot_* at their accumulated values.
      state.token_usage_snapshot_kind = TokenUsageSnapshotKind::CompactionReset;

      effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
        session_id: sid.clone(),
        usage: state.token_usage.clone(),
        snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
      })));
      effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
        session_id: sid.clone(),
        usage: state.token_usage.clone(),
        snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
      })));

      // Record compaction as a first-class transcript event so it is visible
      // in chat history and persisted in SQLite for reloads.
      let compact_seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
      let compact_entry = ConversationRowEntry {
        session_id: sid.clone(),
        sequence: compact_seq,
        turn_id: state.current_turn_id.clone(),
        turn_status: TurnStatus::Active,
        row: ConversationRow::System(MessageRowContent {
          id: format!("context-compacted-{}", uuid::Uuid::new_v4()),
          content: "Context compacted to keep this session within the model context window."
            .to_string(),
          turn_id: state.current_turn_id.clone(),
          timestamp: Some(now.to_string()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "transition_tests.rs"]
mod tests;
