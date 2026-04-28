use crate::approval_preview::{approval_preview, approval_question_prompts, ApprovalPreviewInput};
use crate::transition::{finalize_in_progress_rows, Effect, PersistOp, TransitionState, WorkPhase};
use orbitdock_protocol::{
  ApprovalRequest, ApprovalType, ServerMessage, StateChanges, TokenUsage, TurnDiff, WorkStatus,
};

pub(super) struct ApprovalRequestedInput {
  pub request_id: String,
  pub approval_type: ApprovalType,
  pub tool_name: Option<String>,
  pub tool_input: Option<String>,
  pub command: Option<String>,
  pub file_path: Option<String>,
  pub diff: Option<String>,
  pub question: Option<String>,
  pub permission_reason: Option<String>,
  pub requested_permissions: Option<serde_json::Value>,
  pub proposed_amendment: Option<Vec<String>>,
  pub permission_suggestions: Option<serde_json::Value>,
  pub elicitation_mode: Option<String>,
  pub elicitation_schema: Option<serde_json::Value>,
  pub elicitation_url: Option<String>,
  pub elicitation_message: Option<String>,
  pub mcp_server_name: Option<String>,
  pub network_host: Option<String>,
  pub network_protocol: Option<String>,
}

pub(super) fn handle_turn_started(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
) {
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
    id: sid.to_string(),
    status: None,
    work_status: Some(WorkStatus::Working),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
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

pub(super) fn handle_turn_completed(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
) {
  if let Some(turn_id) = state.current_turn_id.as_ref() {
    let diff = state.current_diff.clone();
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
      session_id: sid.to_string(),
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
        session_id: sid.to_string(),
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

  state.turn_input_tokens = 0;
  state.turn_output_tokens = 0;
  state.turn_cached_tokens = 0;
  state.turn_usage_snapshot = None;
  state.turn_usage_snapshot_kind = None;
  state.current_diff = None;

  let cumulative = orbitdock_protocol::diff_merge::compute_cumulative_diff(&state.turn_diffs, None);

  effects.extend(finalize_in_progress_rows(
    sid,
    &mut state.rows,
    state.total_row_count,
  ));

  if matches!(state.phase, WorkPhase::Working) {
    state.phase = WorkPhase::Idle;
  }
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());
  state.current_turn_id = None;

  effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
    id: sid.to_string(),
    status: None,
    work_status: Some(WorkStatus::Waiting),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
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

pub(super) fn handle_turn_aborted(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
) {
  if !matches!(state.phase, WorkPhase::Idle | WorkPhase::Ended { .. }) {
    effects.extend(finalize_in_progress_rows(
      sid,
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
      id: sid.to_string(),
      status: None,
      work_status: Some(WorkStatus::Waiting),
      last_activity_at: Some(now.to_string()),
      last_progress_at: Some(now.to_string()),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
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

pub(super) fn handle_approval_requested(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  input: ApprovalRequestedInput,
) {
  state.phase = WorkPhase::AwaitingApproval {
    request_id: input.request_id.clone(),
    approval_type: input.approval_type,
    proposed_amendment: input.proposed_amendment.clone(),
  };
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  let resolved_tool_name = input
    .tool_name
    .unwrap_or_else(|| match input.approval_type {
      ApprovalType::Exec => "Bash".to_string(),
      ApprovalType::Patch => "Edit".to_string(),
      ApprovalType::Question => "Question".to_string(),
      ApprovalType::Permissions => "Permissions".to_string(),
    });
  let question_prompts =
    approval_question_prompts(input.tool_input.as_deref(), input.question.as_deref());
  let resolved_question = input.question.or_else(|| {
    question_prompts
      .first()
      .map(|prompt| prompt.question.clone())
      .filter(|text| !text.is_empty())
  });
  let preview = approval_preview(ApprovalPreviewInput {
    request_id: input.request_id.as_str(),
    approval_type: input.approval_type,
    tool_name: Some(resolved_tool_name.as_str()),
    tool_input: input.tool_input.as_deref(),
    command: input.command.as_deref(),
    file_path: input.file_path.as_deref(),
    diff: input.diff.as_deref(),
    question: resolved_question.as_deref(),
    permission_reason: input.permission_reason.as_deref(),
  });

  let request = ApprovalRequest {
    id: input.request_id.clone(),
    session_id: sid.to_string(),
    approval_type: input.approval_type,
    tool_name: Some(resolved_tool_name.clone()),
    tool_input: input.tool_input.clone(),
    command: input.command.clone(),
    file_path: input.file_path.clone(),
    diff: input.diff,
    question: resolved_question,
    question_prompts,
    preview,
    permission_reason: input.permission_reason.clone(),
    requested_permissions: input.requested_permissions.clone(),
    granted_permissions: None,
    proposed_amendment: input.proposed_amendment.clone(),
    permission_suggestions: input.permission_suggestions.clone(),
    elicitation_mode: input.elicitation_mode.clone(),
    elicitation_schema: input.elicitation_schema.clone(),
    elicitation_url: input.elicitation_url.clone(),
    elicitation_message: input.elicitation_message.clone(),
    mcp_server_name: input.mcp_server_name.clone(),
    network_host: input.network_host.clone(),
    network_protocol: input.network_protocol.clone(),
  };

  state.pending_approval = Some(request.clone());

  effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
    id: sid.to_string(),
    status: None,
    work_status: Some(state.phase.to_work_status()),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Persist(Box::new(PersistOp::ApprovalRequested {
    session_id: sid.to_string(),
    request_id: input.request_id,
    approval_type: input.approval_type,
    tool_name: Some(resolved_tool_name),
    tool_input: input.tool_input,
    command: input.command,
    file_path: input.file_path,
    diff: request.diff.clone(),
    question: request.question.clone(),
    question_prompts: request.question_prompts.clone(),
    preview: Box::new(request.preview.clone()),
    permission_reason: request.permission_reason.clone(),
    requested_permissions: request.requested_permissions.clone(),
    granted_permissions: request.granted_permissions.clone(),
    cwd: Some(state.project_path.clone()),
    proposed_amendment: input.proposed_amendment,
    permission_suggestions: request.permission_suggestions.clone(),
    elicitation_mode: input.elicitation_mode,
    elicitation_schema: input.elicitation_schema,
    elicitation_url: input.elicitation_url,
    elicitation_message: input.elicitation_message,
    mcp_server_name: input.mcp_server_name,
    network_host: input.network_host,
    network_protocol: input.network_protocol,
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::ApprovalRequested {
    session_id: sid.to_string(),
    request: Box::new(request),
    approval_version: None,
  })));
}

pub(super) fn handle_approval_cancelled(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  request_id: String,
) {
  let is_current = matches!(
    &state.phase,
    WorkPhase::AwaitingApproval { request_id: pending_id, .. } if *pending_id == request_id
  );
  if is_current {
    state.phase = WorkPhase::Working;
    state.pending_approval = None;
    state.last_activity_at = Some(now.to_string());
    state.last_progress_at = Some(now.to_string());

    effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
      id: sid.to_string(),
      status: None,
      work_status: Some(WorkStatus::Working),
      last_activity_at: Some(now.to_string()),
      last_progress_at: Some(now.to_string()),
    })));
    effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
      session_id: sid.to_string(),
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

pub(super) fn handle_session_ended(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  reason: String,
) {
  effects.extend(finalize_in_progress_rows(
    sid,
    &mut state.rows,
    state.total_row_count,
  ));

  state.phase = WorkPhase::Ended {
    reason: reason.clone(),
  };
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::SessionEnd {
    id: sid.to_string(),
    reason: reason.clone(),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionEnded {
    session_id: sid.to_string(),
    reason,
  })));
}

pub(super) fn handle_undo_started(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  message: Option<String>,
) {
  state.phase = WorkPhase::Working;
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
    id: sid.to_string(),
    status: None,
    work_status: Some(WorkStatus::Working),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      work_status: Some(WorkStatus::Working),
      last_activity_at: Some(now.to_string()),
      last_progress_at: Some(now.to_string()),
      ..Default::default()
    }),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::UndoStarted {
    session_id: sid.to_string(),
    message,
  })));
}

pub(super) fn handle_undo_completed(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  success: bool,
  message: Option<String>,
) {
  state.phase = WorkPhase::Idle;
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
    id: sid.to_string(),
    status: None,
    work_status: Some(WorkStatus::Waiting),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      work_status: Some(WorkStatus::Waiting),
      last_activity_at: Some(now.to_string()),
      last_progress_at: Some(now.to_string()),
      ..Default::default()
    }),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::UndoCompleted {
    session_id: sid.to_string(),
    success,
    message,
  })));
}

pub(super) fn handle_thread_rolled_back(
  state: &mut TransitionState,
  sid: &str,
  now: &str,
  effects: &mut Vec<Effect>,
  num_turns: u32,
) {
  state.phase = WorkPhase::Idle;
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::SessionUpdate {
    id: sid.to_string(),
    status: None,
    work_status: Some(WorkStatus::Waiting),
    last_activity_at: Some(now.to_string()),
    last_progress_at: Some(now.to_string()),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::SessionDelta {
    session_id: sid.to_string(),
    changes: Box::new(StateChanges {
      work_status: Some(WorkStatus::Waiting),
      last_activity_at: Some(now.to_string()),
      last_progress_at: Some(now.to_string()),
      ..Default::default()
    }),
  })));
  effects.push(Effect::Emit(Box::new(ServerMessage::ThreadRolledBack {
    session_id: sid.to_string(),
    num_turns,
  })));
}
