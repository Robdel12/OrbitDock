use crate::transition::{merge_subagent_updates, Effect, PersistOp, TransitionState};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent, TurnStatus,
};
use orbitdock_protocol::{
  McpAuthStatus, McpResource, McpResourceTemplate, McpStartupFailure, McpStartupStatus, McpTool,
  RateLimitInfo, ServerMessage, SkillErrorInfo, SkillsListEntry, StateChanges, SubagentInfo,
  TokenUsage, TokenUsageSnapshotKind,
};
use std::collections::HashMap;

pub(super) fn handle_error(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  msg: String,
) {
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  let seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
  let entry = ConversationRowEntry {
    session_id: sid.to_string(),
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
    session_id: sid.to_string(),
    entry: entry.clone(),
  })));
  effects.push(Effect::Emit(Box::new(
    ServerMessage::ConversationRowsChanged {
      session_id: sid.to_string(),
      upserted: vec![entry.to_summary()],
      removed_row_ids: vec![],
      total_row_count: state.total_row_count,
    },
  )));
}

pub(super) fn handle_permission_mode_changed(sid: &str, effects: &mut Vec<Effect>, mode: String) {
  effects.push(Effect::Persist(Box::new(PersistOp::PermissionModeUpdate {
    session_id: sid.to_string(),
    permission_mode: mode.clone(),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      permission_mode: Some(Some(mode)),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_tokens_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  usage: TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) {
  match snapshot_kind {
    TokenUsageSnapshotKind::Mixed => {
      state.token_usage.input_tokens = usage.input_tokens;
      state.token_usage.output_tokens += usage.output_tokens;
      state.token_usage.cached_tokens = usage.cached_tokens;
      state.token_usage.context_window = usage.context_window;
      state.turn_input_tokens += usage.input_tokens;
      state.turn_output_tokens += usage.output_tokens;
      state.turn_cached_tokens += usage.cached_tokens;
    }
    _ => {
      state.token_usage = usage;
    }
  }
  state.token_usage_snapshot_kind = snapshot_kind;

  effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
    session_id: sid.to_string(),
    usage: state.token_usage.clone(),
    snapshot_kind,
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
    session_id: sid.to_string(),
    usage: state.token_usage.clone(),
    snapshot_kind,
  })));
}

pub(super) fn handle_turn_usage_updated(
  state: &mut TransitionState,
  usage: TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) {
  state.turn_usage_snapshot = Some(usage);
  state.turn_usage_snapshot_kind = Some(snapshot_kind);
}

pub(super) fn handle_diff_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  diff: String,
) {
  state.current_diff = Some(diff.clone());
  let cumulative =
    orbitdock_protocol::diff_merge::compute_cumulative_diff(&state.turn_diffs, Some(&diff));

  effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
    session_id: sid.to_string(),
    diff: Some(diff.clone()),
    plan: None,
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      current_diff: Some(Some(diff)),
      cumulative_diff: Some(cumulative),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_plan_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  plan: String,
) {
  state.current_plan = Some(plan.clone());

  effects.push(Effect::Persist(Box::new(PersistOp::TurnStateUpdate {
    session_id: sid.to_string(),
    diff: None,
    plan: Some(plan.clone()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      current_plan: Some(Some(plan)),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_thread_name_updated(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  name: String,
) {
  state.custom_name = Some(name.clone());
  state.last_activity_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::SetCustomName {
    session_id: sid.to_string(),
    custom_name: Some(name.clone()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      custom_name: Some(Some(name)),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_environment_changed(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  cwd: Option<String>,
  git_branch: Option<String>,
  git_sha: Option<String>,
  repository_root: Option<String>,
  is_worktree: Option<bool>,
) {
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
      session_id: sid.to_string(),
      cwd: state.current_cwd.clone(),
      git_branch: state.git_branch.clone(),
      git_sha: state.git_sha.clone(),
      repository_root: state.repository_root.clone(),
      is_worktree: Some(state.is_worktree),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
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

pub(super) fn handle_model_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  model: String,
) {
  state.model = Some(model.clone());
  effects.push(Effect::Persist(Box::new(PersistOp::ModelUpdate {
    session_id: sid.to_string(),
    model: model.clone(),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      model: Some(Some(model)),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_transcript_path_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  path: Option<String>,
) {
  state.transcript_path = path.clone();
  effects.push(Effect::Persist(Box::new(PersistOp::SetTranscriptPath {
    session_id: sid.to_string(),
    transcript_path: path,
  })));
}

pub(super) fn handle_attention_updated(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  attention_reason: Option<Option<String>>,
  last_tool: Option<String>,
  pending_tool_name: Option<Option<String>>,
  pending_tool_input: Option<Option<String>>,
  pending_question: Option<Option<String>>,
) {
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
    session_id: sid.to_string(),
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

pub(super) fn handle_subagents_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  subagents: Vec<SubagentInfo>,
) {
  let merged = merge_subagent_updates(&state.subagents, subagents);
  if merged != state.subagents {
    state.subagents = merged.clone();
    effects.push(Effect::Persist(Box::new(PersistOp::UpsertSubagents {
      session_id: sid.to_string(),
      subagents: merged.clone(),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
      changes: Box::new(StateChanges {
        subagents: Some(merged),
        ..Default::default()
      }),
    })));
  }
}

pub(super) fn handle_summary_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  summary: String,
) {
  if state.summary.as_ref() != Some(&summary) {
    state.summary = Some(summary.clone());
    effects.push(Effect::Persist(Box::new(PersistOp::SetSummary {
      session_id: sid.to_string(),
      summary: summary.clone(),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
      changes: Box::new(StateChanges {
        summary: Some(Some(summary)),
        ..Default::default()
      }),
    })));
  }
}

pub(super) fn handle_effort_updated(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  effort: Option<String>,
) {
  if state.effort != effort {
    state.effort = effort.clone();
    effects.push(Effect::Persist(Box::new(PersistOp::EffortUpdate {
      session_id: sid.to_string(),
      effort: effort.clone(),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
      changes: Box::new(StateChanges {
        effort: Some(effort),
        ..Default::default()
      }),
    })));
  }
}

pub(super) fn handle_first_prompt_captured(
  state: &mut TransitionState,
  sid: &str,
  effects: &mut Vec<Effect>,
  prompt: String,
) {
  state.first_prompt = Some(prompt.clone());
  effects.push(Effect::Persist(Box::new(PersistOp::FirstPromptCaptured {
    session_id: sid.to_string(),
    first_prompt: prompt.clone(),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      first_prompt: Some(Some(prompt)),
      ..Default::default()
    }),
  })));
}

pub(super) fn handle_claude_initialized(
  sid: &str,
  effects: &mut Vec<Effect>,
  slash_commands: Vec<String>,
  skills: Vec<String>,
  tools: Vec<String>,
  models: Vec<orbitdock_protocol::ClaudeModelOption>,
) {
  effects.push(Effect::Emit(Box::new(ServerMessage::ClaudeCapabilities {
    session_id: sid.to_string(),
    slash_commands,
    skills,
    tools,
    models,
  })));
}

pub(super) fn handle_context_compacted(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
) {
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());
  state.token_usage_snapshot_kind = TokenUsageSnapshotKind::CompactionReset;

  effects.push(Effect::Persist(Box::new(PersistOp::TokensUpdate {
    session_id: sid.to_string(),
    usage: state.token_usage.clone(),
    snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::TokensUpdated {
    session_id: sid.to_string(),
    usage: state.token_usage.clone(),
    snapshot_kind: TokenUsageSnapshotKind::CompactionReset,
  })));

  let compact_seq = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
  let compact_entry = ConversationRowEntry {
    session_id: sid.to_string(),
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
    session_id: sid.to_string(),
    entry: compact_entry.clone(),
  })));
  effects.push(Effect::Emit(Box::new(
    ServerMessage::ConversationRowsChanged {
      session_id: sid.to_string(),
      upserted: vec![compact_entry.to_summary()],
      removed_row_ids: vec![],
      total_row_count: state.total_row_count,
    },
  )));
  effects.push(Effect::Emit(Box::new(ServerMessage::ContextCompacted {
    session_id: sid.to_string(),
  })));
}

pub(super) fn handle_skills_list(
  sid: &str,
  effects: &mut Vec<Effect>,
  skills: Vec<SkillsListEntry>,
  errors: Vec<SkillErrorInfo>,
) {
  effects.push(Effect::Emit(Box::new(ServerMessage::SkillsList {
    session_id: sid.to_string(),
    skills,
    errors,
  })));
}

pub(super) fn handle_skills_update_available(sid: &str, effects: &mut Vec<Effect>) {
  effects.push(Effect::Emit(Box::new(
    ServerMessage::SkillsUpdateAvailable {
      session_id: sid.to_string(),
    },
  )));
}

pub(super) fn handle_mcp_tools_list(
  sid: &str,
  effects: &mut Vec<Effect>,
  tools: HashMap<String, McpTool>,
  resources: HashMap<String, Vec<McpResource>>,
  resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
  auth_statuses: HashMap<String, McpAuthStatus>,
) {
  effects.push(Effect::Emit(Box::new(ServerMessage::McpToolsList {
    session_id: sid.to_string(),
    tools,
    resources,
    resource_templates,
    auth_statuses,
  })));
}

pub(super) fn handle_mcp_startup_update(
  sid: &str,
  effects: &mut Vec<Effect>,
  server: String,
  status: McpStartupStatus,
) {
  effects.push(Effect::Emit(Box::new(ServerMessage::McpStartupUpdate {
    session_id: sid.to_string(),
    server,
    status,
  })));
}

pub(super) fn handle_mcp_startup_complete(
  sid: &str,
  effects: &mut Vec<Effect>,
  ready: Vec<String>,
  failed: Vec<McpStartupFailure>,
  cancelled: Vec<String>,
) {
  effects.push(Effect::Emit(Box::new(ServerMessage::McpStartupComplete {
    session_id: sid.to_string(),
    ready,
    failed,
    cancelled,
  })));
}

pub(super) fn handle_rate_limit_event(sid: &str, effects: &mut Vec<Effect>, info: RateLimitInfo) {
  effects.push(Effect::Emit(Box::new(ServerMessage::RateLimitEvent {
    session_id: sid.to_string(),
    info,
  })));
}

pub(super) fn handle_prompt_suggestion(sid: &str, effects: &mut Vec<Effect>, suggestion: String) {
  effects.push(Effect::Emit(Box::new(ServerMessage::PromptSuggestion {
    session_id: sid.to_string(),
    suggestion,
  })));
}

pub(super) fn handle_files_persisted(sid: &str, effects: &mut Vec<Effect>, files: Vec<String>) {
  effects.push(Effect::Emit(Box::new(ServerMessage::FilesPersisted {
    session_id: sid.to_string(),
    files,
  })));
}
