//! Pure state transition function
//!
//! All business logic for session state changes lives here as a pure,
//! synchronous function: `transition(state, input) -> (state, effects)`.
//! No IO, no async, no locking — fully unit-testable.

use std::collections::HashMap;

use crate::{ConnectorOutput, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
#[cfg(test)]
use orbitdock_protocol::conversation_contracts::{MessageRowContent, TurnStatus};
#[cfg(test)]
use orbitdock_protocol::domain_events::ToolFamily;
use orbitdock_protocol::domain_events::ToolStatus;
use orbitdock_protocol::{
  ApprovalPreview, ApprovalQuestionPrompt, ApprovalRequest, ApprovalType, McpAuthStatus,
  McpResource, McpResourceTemplate, McpStartupFailure, McpStartupStatus, McpTool, Provider,
  ServerMessage, SessionStatus, SkillErrorInfo, SkillsListEntry, SubagentInfo, TokenUsage,
  TokenUsageSnapshotKind, TurnDiff, WorkStatus,
};

#[path = "transition_lifecycle.rs"]
mod transition_lifecycle;
#[path = "transition_metadata.rs"]
mod transition_metadata;
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
      transition_lifecycle::handle_turn_started(&mut state, &sid, now, &mut effects);
    }

    Input::TurnCompleted => {
      transition_lifecycle::handle_turn_completed(&mut state, &sid, now, &mut effects);
    }

    Input::TurnAborted { .. } => {
      transition_lifecycle::handle_turn_aborted(&mut state, &sid, now, &mut effects);
    }

    Input::Error(msg) => {
      transition_metadata::handle_error(&mut state, &sid, now, &mut effects, msg);
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
      transition_lifecycle::handle_approval_requested(
        &mut state,
        &sid,
        now,
        &mut effects,
        transition_lifecycle::ApprovalRequestedInput {
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
      );
    }

    // -- Approval cancelled (SDK cancelled pending can_use_tool) ----------
    Input::ApprovalCancelled { request_id } => {
      transition_lifecycle::handle_approval_cancelled(
        &mut state,
        &sid,
        now,
        &mut effects,
        request_id,
      );
    }

    // -- Permission mode (e.g. /plan entered from terminal) ---------------
    Input::PermissionModeChanged { mode } => {
      transition_metadata::handle_permission_mode_changed(&sid, &mut effects, mode);
    }

    // -- Metadata ---------------------------------------------------------
    Input::TokensUpdated {
      usage,
      snapshot_kind,
    } => {
      transition_metadata::handle_tokens_updated(
        &mut state,
        &sid,
        &mut effects,
        usage,
        snapshot_kind,
      );
    }

    Input::TurnUsageUpdated {
      usage,
      snapshot_kind,
    } => {
      transition_metadata::handle_turn_usage_updated(&mut state, usage, snapshot_kind);
    }

    Input::DiffUpdated(diff) => {
      transition_metadata::handle_diff_updated(&mut state, &sid, &mut effects, diff);
    }

    Input::PlanUpdated(plan) => {
      transition_metadata::handle_plan_updated(&mut state, &sid, &mut effects, plan);
    }

    Input::ThreadNameUpdated(name) => {
      transition_metadata::handle_thread_name_updated(&mut state, &sid, now, &mut effects, name);
    }

    // -- Lifecycle --------------------------------------------------------
    Input::SessionEnded { reason } => {
      transition_lifecycle::handle_session_ended(&mut state, &sid, now, &mut effects, reason);
    }

    // -- Undo/Rollback ----------------------------------------------------
    Input::UndoStarted { message } => {
      transition_lifecycle::handle_undo_started(&mut state, &sid, now, &mut effects, message);
    }

    Input::UndoCompleted { success, message } => {
      transition_lifecycle::handle_undo_completed(
        &mut state,
        &sid,
        now,
        &mut effects,
        success,
        message,
      );
    }

    Input::ThreadRolledBack { num_turns } => {
      transition_lifecycle::handle_thread_rolled_back(
        &mut state,
        &sid,
        now,
        &mut effects,
        num_turns,
      );
    }

    // -- Environment --------------------------------------------------------
    Input::EnvironmentChanged {
      cwd,
      git_branch,
      git_sha,
      repository_root,
      is_worktree,
    } => {
      transition_metadata::handle_environment_changed(
        &mut state,
        &sid,
        now,
        &mut effects,
        cwd,
        git_branch,
        git_sha,
        repository_root,
        is_worktree,
      );
    }

    // -- Model ---------------------------------------------------------------
    Input::ModelUpdated(model) => {
      transition_metadata::handle_model_updated(&mut state, &sid, &mut effects, model);
    }

    // -- Transcript path ---------------------------------------------------
    Input::TranscriptPathUpdated(path) => {
      transition_metadata::handle_transcript_path_updated(&mut state, &sid, &mut effects, path);
    }

    // -- Attention (last_tool, pending tool/input/question) ----------------
    Input::AttentionUpdated {
      attention_reason,
      last_tool,
      pending_tool_name,
      pending_tool_input,
      pending_question,
    } => {
      transition_metadata::handle_attention_updated(
        &mut state,
        &sid,
        now,
        &mut effects,
        attention_reason,
        last_tool,
        pending_tool_name,
        pending_tool_input,
        pending_question,
      );
    }

    // -- Subagents ---------------------------------------------------------
    Input::SubagentsUpdated { subagents } => {
      transition_metadata::handle_subagents_updated(&mut state, &sid, &mut effects, subagents);
    }

    // -- Summary -----------------------------------------------------------
    Input::SummaryUpdated(summary) => {
      transition_metadata::handle_summary_updated(&mut state, &sid, &mut effects, summary);
    }

    // -- Effort -------------------------------------------------------------
    Input::EffortUpdated(effort) => {
      transition_metadata::handle_effort_updated(&mut state, &sid, &mut effects, effort);
    }

    // -- First prompt -------------------------------------------------------
    Input::FirstPromptCaptured(prompt) => {
      transition_metadata::handle_first_prompt_captured(&mut state, &sid, &mut effects, prompt);
    }

    // -- Claude capabilities (from init message) ---------------------------
    Input::ClaudeInitialized {
      slash_commands,
      skills,
      tools,
      models,
    } => {
      transition_metadata::handle_claude_initialized(
        &sid,
        &mut effects,
        slash_commands,
        skills,
        tools,
        models,
      );
    }

    // -- Context management -----------------------------------------------
    Input::ContextCompacted => {
      transition_metadata::handle_context_compacted(&mut state, &sid, now, &mut effects);
    }

    Input::SkillsList { skills, errors } => {
      transition_metadata::handle_skills_list(&sid, &mut effects, skills, errors);
    }

    Input::SkillsUpdateAvailable => {
      transition_metadata::handle_skills_update_available(&sid, &mut effects);
    }

    Input::McpToolsList {
      tools,
      resources,
      resource_templates,
      auth_statuses,
    } => {
      transition_metadata::handle_mcp_tools_list(
        &sid,
        &mut effects,
        tools,
        resources,
        resource_templates,
        auth_statuses,
      );
    }

    Input::McpStartupUpdate { server, status } => {
      transition_metadata::handle_mcp_startup_update(&sid, &mut effects, server, status);
    }

    Input::McpStartupComplete {
      ready,
      failed,
      cancelled,
    } => {
      transition_metadata::handle_mcp_startup_complete(
        &sid,
        &mut effects,
        ready,
        failed,
        cancelled,
      );
    }

    Input::RateLimitEvent { info } => {
      transition_metadata::handle_rate_limit_event(&sid, &mut effects, info);
    }

    Input::PromptSuggestion { suggestion } => {
      transition_metadata::handle_prompt_suggestion(&sid, &mut effects, suggestion);
    }
    Input::FilesPersisted { files } => {
      transition_metadata::handle_files_persisted(&sid, &mut effects, files);
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
