//! Shared session command handler
//!
//! Processes `SessionCommand`s against a `SessionHandle`, handling queries,
//! mutations, persistence effects, and broadcasts. Used by both provider
//! event loops (Claude, Codex) and the passive session actor.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use orbitdock_connector_core::{
  ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent, ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::rows::MessageDeliveryStatus;
use orbitdock_protocol::conversation_contracts::{
  compute_tool_display, ConversationRow, ToolDisplayInput,
};
use orbitdock_protocol::domain_events::{ToolKind, ToolStatus};
use orbitdock_protocol::{
  CodexIntegrationMode, Provider, ServerMessage, SessionState, SessionStatus, SessionSurface,
  StateChanges, WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, warn};

use crate::domain::sessions::session::{SessionHandle, SessionSnapshot};
use crate::domain::sessions::transition;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_broadcasts::{
  inject_approval_version, latest_completed_conversation_row, row_append_delta, transition_delta,
};
use crate::runtime::session_commands::{
  PendingApprovalResolution, PersistOp, SessionCommand, SubscribeResult,
};
use crate::support::session_time::chrono_now;

async fn execute_persist_op(op: PersistOp, persist_tx: &mpsc::Sender<PersistCommand>) {
  let cmd = match op {
    PersistOp::SessionUpdate {
      id,
      status,
      work_status,
      lifecycle_state,
      last_activity_at,
      last_progress_at,
    } => PersistCommand::SessionUpdate {
      id,
      status,
      work_status,
      control_mode: None,
      lifecycle_state,
      last_activity_at,
      last_progress_at,
    },
    PersistOp::SetCustomName { session_id, name } => PersistCommand::SetCustomName {
      session_id,
      custom_name: name,
    },
    PersistOp::SetSessionConfig(cfg) => PersistCommand::SetSessionConfig {
      session_id: cfg.session_id,
      approval_policy: cfg.approval_policy,
      sandbox_mode: cfg.sandbox_mode,
      permission_mode: cfg.permission_mode,
      collaboration_mode: cfg.collaboration_mode,
      multi_agent: cfg.multi_agent,
      personality: cfg.personality,
      service_tier: cfg.service_tier,
      developer_instructions: cfg.developer_instructions,
      model: cfg.model,
      effort: cfg.effort,
      codex_config_mode: cfg.codex_config_mode,
      codex_config_profile: cfg.codex_config_profile,
      codex_model_provider: cfg.codex_model_provider,
      codex_config_source: cfg.codex_config_source,
      codex_config_overrides_json: cfg.codex_config_overrides_json,
    },
  };
  let _ = persist_tx.send(cmd).await;
}

async fn apply_delta_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  changes: StateChanges,
  persist_op: Option<PersistOp>,
) {
  let session_id = handle.id().to_string();
  handle.apply_changes(&changes);
  if let Some(op) = persist_op {
    execute_persist_op(op, persist_tx).await;
  }
  let mut changes = changes;
  include_derived_affordances_for_state_delta(&mut changes, handle);
  handle.broadcast(ServerMessage::SessionDelta {
    session_id,
    changes: Box::new(changes),
  });
}

fn include_derived_affordances_for_state_delta(changes: &mut StateChanges, handle: &SessionHandle) {
  if changes.status.is_none()
    && changes.work_status.is_none()
    && changes.control_mode.is_none()
    && changes.lifecycle_state.is_none()
  {
    return;
  }

  let snapshot = handle.to_snapshot();
  let retained = handle.retained_state();
  changes.steerable = Some(snapshot.steerable);
  changes.accepts_user_input = Some(retained.accepts_user_input);
}

fn include_snapshot_delta_changes(
  changes: &mut StateChanges,
  previous_transport: &SessionSnapshot,
  previous_state: &SessionState,
  current_transport: &SessionSnapshot,
  current_state: &SessionState,
) -> bool {
  let mut changed = false;

  if current_transport.status != previous_transport.status {
    changes.status = Some(current_transport.status);
    changed = true;
  }
  if current_transport.work_status != previous_transport.work_status {
    changes.work_status = Some(current_transport.work_status);
    changes.steerable = Some(current_transport.steerable);
    changed = true;
  }
  if current_transport.control_mode != previous_transport.control_mode {
    changes.control_mode = Some(current_transport.control_mode);
    changed = true;
  }
  if current_transport.lifecycle_state != previous_transport.lifecycle_state {
    changes.lifecycle_state = Some(current_transport.lifecycle_state);
    changed = true;
  }
  if current_state.accepts_user_input != previous_state.accepts_user_input {
    changes.accepts_user_input = Some(current_state.accepts_user_input);
    changed = true;
  }
  if current_transport.steerable != previous_transport.steerable {
    changes.steerable = Some(current_transport.steerable);
    changed = true;
  }
  if current_state.current_turn_id != previous_state.current_turn_id {
    changes.current_turn_id = Some(current_state.current_turn_id.clone());
    changed = true;
  }

  changed
}

async fn persist_and_broadcast_mark_read(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  let prev = handle.mark_read();
  if prev == 0 {
    return;
  }

  let session_id = handle.id().to_string();
  let _ = persist_tx
    .send(PersistCommand::MarkSessionRead {
      session_id: session_id.clone(),
      up_to_sequence: handle.latest_row_sequence() as i64,
    })
    .await;

  // When the user reads a session in Reply state, transition to Waiting.
  // Reply means "has unread response"; once read, it becomes "idle/waiting."
  let mut changes = StateChanges {
    unread_count: Some(0),
    ..Default::default()
  };
  if handle.work_status() == WorkStatus::Reply {
    changes.work_status = Some(WorkStatus::Waiting);
    handle.set_work_status(WorkStatus::Waiting);
    let _ = persist_tx
      .send(PersistCommand::SessionUpdate {
        id: session_id.clone(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        control_mode: None,
        lifecycle_state: None,
        last_activity_at: None,
        last_progress_at: None,
      })
      .await;
  }

  handle.broadcast(ServerMessage::SessionDelta {
    session_id: session_id.clone(),
    changes: Box::new(changes),
  });
}

async fn persist_upserted_row_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) {
  let session_id = handle.id().to_string();
  let row_id = entry.id().to_string();
  let entry = handle.upsert_row(entry);

  let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx
    .send(PersistCommand::RowUpsert {
      session_id: session_id.clone(),
      entry: entry.clone(),
      viewer_present: handle.has_active_viewers(),
      assigned_sequence: None,
      sequence_tx: Some(seq_tx),
    })
    .await;

  if let Ok(db_seq) = seq_rx.await {
    handle.set_row_sequence(&row_id, db_seq);
  }

  let summary = handle
    .row_by_id(&row_id)
    .map(|row| row.to_transport_summary())
    .unwrap_or_else(|| entry.to_transport_summary());
  handle.broadcast(ServerMessage::ConversationRowsChanged {
    session_id,
    upserted: vec![summary],
    removed_row_ids: vec![],
    total_row_count: handle.message_count() as u64,
  });
}

async fn append_row_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) -> orbitdock_protocol::conversation_contracts::ConversationRowEntry {
  let session_id = handle.id().to_string();
  let previous_last_message = handle.to_snapshot().last_message.clone();

  let entry = handle.add_row(entry);
  let row_id = entry.id().to_string();
  let viewer_present = handle.has_active_viewers();
  let unread_count_delta = handle.unread_count_after_row_append(&entry);

  let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx
    .send(PersistCommand::RowAppend {
      session_id: session_id.clone(),
      entry: entry.clone(),
      viewer_present,
      assigned_sequence: None,
      sequence_tx: Some(seq_tx),
    })
    .await;

  if let Ok(db_seq) = seq_rx.await {
    handle.set_row_sequence(&row_id, db_seq);
  }

  let final_entry = handle.row_by_id(&row_id).cloned().unwrap_or(entry);
  let observability_changes = row_append_delta(
    previous_last_message.as_deref(),
    &final_entry,
    unread_count_delta,
  );
  let summary = final_entry.to_transport_summary();
  let upserted = vec![summary];
  if handle.should_emit_streaming_row_update(&upserted) {
    handle.broadcast(ServerMessage::ConversationRowsChanged {
      session_id: session_id.clone(),
      upserted,
      removed_row_ids: vec![],
      total_row_count: handle.message_count() as u64,
    });
  }
  if let Some(changes) = observability_changes {
    handle.broadcast(ServerMessage::SessionDelta {
      session_id: handle.id().to_string(),
      changes: Box::new(changes),
    });
  }

  final_entry
}

fn should_suppress_connector_user_echo(
  handle: &SessionHandle,
  event: &ConnectorStateEvent,
) -> bool {
  if handle.provider() != Provider::Codex
    || handle.to_snapshot().codex_integration_mode != Some(CodexIntegrationMode::Direct)
  {
    return false;
  }

  let ConnectorStateEvent::ConversationRowCreated(entry) = event else {
    return false;
  };

  let ConversationRow::User(message) = &entry.row else {
    return false;
  };

  handle.has_user_row_with_content(&message.content)
}

fn upgrade_connector_row_event(
  provider: Provider,
  event: ConnectorStateEvent,
) -> ConnectorStateEvent {
  match event {
    ConnectorStateEvent::ConversationRowCreated(mut entry) => {
      entry.row = crate::domain::conversation_semantics::upgrade_row(provider, entry.row);
      ConnectorStateEvent::ConversationRowCreated(entry)
    }
    ConnectorStateEvent::ConversationRowUpdated { row_id, mut entry } => {
      entry.row = crate::domain::conversation_semantics::upgrade_row(provider, entry.row);
      ConnectorStateEvent::ConversationRowUpdated { row_id, entry }
    }
    other => other,
  }
}

#[derive(Debug, Clone)]
pub(crate) enum ConnectorDispatch {
  State(Box<ConnectorStateEvent>),
  RuntimeDirective(ConnectorRuntimeDirective),
  TransportEffect(ConnectorTransportEffect),
}

pub(crate) fn classify_connector_output(output: ConnectorOutput) -> ConnectorDispatch {
  match output {
    ConnectorOutput::State(event) => ConnectorDispatch::State(event),
    ConnectorOutput::Runtime(directive) => ConnectorDispatch::RuntimeDirective(directive),
    ConnectorOutput::Transport(effect) => ConnectorDispatch::TransportEffect(effect),
  }
}

pub(crate) async fn handle_connector_transport_effect(
  effect: ConnectorTransportEffect,
  state: &Arc<crate::runtime::session_registry::SessionRegistry>,
  session_id: &str,
) {
  let tool_pty = state.tool_pty_service();
  match effect {
    ConnectorTransportEffect::ToolPtyCreated { tool_id } => {
      tool_pty.create_for_tool(tool_id, session_id.to_string());
    }
    ConnectorTransportEffect::ToolPtyOutput { tool_id, bytes } => {
      tool_pty.feed_output(&tool_id, &bytes);
    }
    ConnectorTransportEffect::ToolPtyExited { tool_id, exit_code } => {
      tool_pty.finish(&tool_id, exit_code);
    }
  }
}

/// Handle a SessionCommand on the owned SessionHandle.
/// This is used by both the CodexSession event loop and the passive SessionActor.
pub async fn handle_session_command(
  cmd: SessionCommand,
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  match cmd {
    SessionCommand::GetRetainedState { reply } => {
      let _ = reply.send(handle.retained_state());
    }
    SessionCommand::GetSummary { reply } => {
      let _ = reply.send(handle.summary());
    }
    SessionCommand::Subscribe {
      since_revision,
      reply,
    } => {
      let replay_events = match since_revision {
        None => Some(vec![]),
        Some(since_rev) => handle.replay_since(since_rev),
      };

      if let Some(events) = replay_events {
        let rx = handle.subscribe();
        persist_and_broadcast_mark_read(handle, persist_tx).await;
        let _ = reply.send(SubscribeResult::Replay { events, rx });
        return;
      }

      let rx = handle.subscribe();
      persist_and_broadcast_mark_read(handle, persist_tx).await;
      let _ = reply.send(SubscribeResult::ResyncRequired { rx });
    }
    SessionCommand::GetLastTool { reply } => {
      let _ = reply.send(handle.last_tool().map(String::from));
    }
    SessionCommand::GetConversationPage {
      before_sequence,
      limit,
      reply,
    } => {
      let _ = reply.send(handle.conversation_page(before_sequence, limit));
    }
    SessionCommand::ResolveUserMessageId {
      num_turns_from_end,
      reply,
    } => {
      // Walk rows in reverse, count user rows, return the Nth one's ID
      let result = handle
        .rows()
        .iter()
        .rev()
        .filter(|entry| entry.row.starts_turn())
        .nth(num_turns_from_end.saturating_sub(1) as usize)
        .map(|entry| entry.id().to_string());
      let _ = reply.send(result);
    }
    SessionCommand::ProcessEvent { event } => {
      let session_id = handle.id().to_string();
      dispatch_transition_input(&session_id, event, handle, persist_tx).await;
    }
    SessionCommand::SetWorkStatus { status } => {
      handle.set_work_status(status);
    }

    // -- Compound operations --
    SessionCommand::ApplyDelta {
      changes,
      persist_op,
    } => {
      apply_delta_and_broadcast(handle, persist_tx, *changes, persist_op).await;
    }
    SessionCommand::ApplyDeltaAndWait {
      changes,
      persist_op,
      reply,
    } => {
      apply_delta_and_broadcast(handle, persist_tx, *changes, persist_op).await;
      let _ = reply.send(());
    }
    SessionCommand::EndLocally => {
      let now = chrono_now();
      apply_delta_and_broadcast(
        handle,
        persist_tx,
        StateChanges {
          status: Some(SessionStatus::Ended),
          work_status: Some(WorkStatus::Ended),
          last_activity_at: Some(now.clone()),
          ..Default::default()
        },
        Some(PersistOp::SessionUpdate {
          id: handle.id().to_string(),
          status: Some(SessionStatus::Ended),
          work_status: Some(WorkStatus::Ended),
          lifecycle_state: None,
          last_activity_at: Some(now),
          last_progress_at: None,
        }),
      )
      .await;
    }
    SessionCommand::SetCustomNameAndNotify {
      name,
      persist_op,
      reply,
    } => {
      let session_id = handle.id().to_string();
      handle.set_custom_name(name.clone());
      if let Some(op) = persist_op {
        execute_persist_op(op, persist_tx).await;
      }
      handle.broadcast(ServerMessage::SessionDelta {
        session_id,
        changes: Box::new(StateChanges {
          custom_name: Some(name),
          ..Default::default()
        }),
      });
      let _ = reply.send(handle.summary());
    }

    // -- Row operations --
    SessionCommand::ReplaceRows { rows } => {
      handle.replace_rows(rows);
      let revision = handle.to_snapshot().revision.saturating_add(1);
      handle.broadcast(ServerMessage::SessionSurfaceInvalidated {
        session_id: handle.id().to_string(),
        surface: SessionSurface::Conversation,
        revision,
      });
    }
    SessionCommand::AddRowAndBroadcast { entry } => {
      let _ = append_row_and_broadcast(handle, persist_tx, entry).await;
    }
    SessionCommand::AddRowAndBroadcastAndReply { entry, reply } => {
      let final_entry = append_row_and_broadcast(handle, persist_tx, entry).await;
      let _ = reply.send(final_entry);
    }
    SessionCommand::UpdateSteerOutcome {
      message_id,
      outcome,
    } => {
      let Some(mut entry) = handle.row_by_id(&message_id).cloned() else {
        return;
      };

      let next_status = match outcome {
        orbitdock_protocol::SteerOutcome::Accepted => MessageDeliveryStatus::Accepted,
      };

      let mut should_upsert = false;
      if let ConversationRow::Steer(ref mut row) = entry.row {
        row.delivery_status = Some(next_status);
        should_upsert = true;
      }

      if !should_upsert {
        return;
      }

      persist_upserted_row_and_broadcast(handle, persist_tx, entry).await;
      handle.broadcast(ServerMessage::SteerOutcome {
        session_id: handle.id().to_string(),
        message_id,
        outcome,
      });
      handle.broadcast_surface_invalidations(&[SessionSurface::Detail]);
    }
    SessionCommand::RecordQuestionAnswer { answer_text } => {
      // Find the newest AskUserQuestion tool row that has no result yet.
      let question_row = handle
        .rows()
        .iter()
        .rev()
        .find_map(|entry| match &entry.row {
          ConversationRow::Tool(tool)
            if tool.kind == ToolKind::AskUserQuestion && tool.result.is_none() =>
          {
            Some(entry.clone())
          }
          _ => None,
        });

      if let Some(mut entry) = question_row {
        if let ConversationRow::Tool(ref mut tool) = entry.row {
          tool.result = Some(serde_json::json!({
              "output": answer_text,
          }));
          // Mark as completed now that the answer is recorded
          tool.status = ToolStatus::Completed;
          // Recompute display with the answer
          let raw_input = if tool.invocation.is_object() {
            Some(&tool.invocation)
          } else {
            None
          };
          tool.tool_display = Some(compute_tool_display(ToolDisplayInput {
            kind: tool.kind,
            family: tool.family,
            status: tool.status,
            title: &tool.title,
            subtitle: tool.subtitle.as_deref(),
            summary: tool.summary.as_deref(),
            duration_ms: tool.duration_ms,
            invocation_input: raw_input,
            result_output: Some(&answer_text),
          }));
        }

        persist_upserted_row_and_broadcast(handle, persist_tx, entry).await;
      }
    }
    SessionCommand::ResolvePendingApproval {
      request_id,
      fallback_work_status,
      reply,
    } => {
      let (approval_type, proposed_amendment, next_pending_approval, work_status) =
        handle.resolve_pending_approval(&request_id, fallback_work_status);

      let approval_version = handle.approval_version();
      if approval_type.is_some() {
        let session_id = handle.id().to_string();

        // Persist the resolved work_status so callers don't need to separately persist.
        let _ = persist_tx
          .send(PersistCommand::SessionUpdate {
            id: session_id.clone(),
            status: None,
            work_status: Some(work_status),
            control_mode: None,
            lifecycle_state: None,
            last_activity_at: None,
            last_progress_at: None,
          })
          .await;

        let changes = StateChanges {
          work_status: Some(work_status),
          pending_approval: Some(next_pending_approval.clone()),
          approval_version: Some(approval_version),
          ..Default::default()
        };
        handle.broadcast(ServerMessage::SessionDelta {
          session_id,
          changes: Box::new(changes),
        });
      }

      let _ = reply.send(PendingApprovalResolution {
        approval_type,
        proposed_amendment,
        next_pending_approval,
        approval_version,
      });
    }
    SessionCommand::Broadcast { msg } => {
      handle.broadcast(msg);
    }
    SessionCommand::TakeHandle { reply: _ } => {
      // TakeHandle is only meaningful in passive_actor_loop — if it arrives
      // here (active event loop), drop it. The oneshot will fail on the caller side.
      warn!(
          component = "session",
          session_id = %handle.id(),
          "TakeHandle received on active session actor — ignoring"
      );
    }
    SessionCommand::MarkRead { reply } => {
      persist_and_broadcast_mark_read(handle, persist_tx).await;
      let _ = reply.send(handle.unread_count());
    }

    SessionCommand::IncrementToolCount => {
      handle.increment_tool_count();
    }
  }

  // Unconditional snapshot refresh — ensures the ArcSwap is always current
  // regardless of which command ran above.
  handle.refresh_snapshot();
}

/// Dispatch a reducer-safe connector state event through the transition state machine.
///
/// Shared by both provider event loops (Claude, Codex). Converts the event
/// to a transition `Input`, runs the state machine, applies effects (persist
/// + broadcast with approval version injection), and refreshes the snapshot.
pub(crate) async fn dispatch_connector_event(
  session_id: &str,
  event: ConnectorStateEvent,
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  if should_suppress_connector_user_echo(handle, &event) {
    if let ConnectorStateEvent::ConversationRowCreated(entry) = &event {
      debug!(
          component = "session",
          event = "session.message.connector_user_echo_suppressed",
          session_id = %session_id,
          row_id = %entry.id(),
          "Suppressed duplicate Codex user-message echo"
      );
    }
    return;
  }

  let event = upgrade_connector_row_event(handle.provider(), event);
  let input = transition::Input::from(event);
  dispatch_transition_input(session_id, input, handle, persist_tx).await;
}

/// Run a transition `Input` through the state machine and apply effects.
///
/// Used by `dispatch_connector_event` (from provider event loops) and
/// `ProcessEvent` (from session commands).
pub(crate) async fn dispatch_transition_input(
  _session_id: &str,
  input: transition::Input,
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  // Capture undo/rollback intent before the transition consumes the input.
  let mark_turns_intent = match &input {
    transition::Input::UndoCompleted { success: true, .. } => Some((
      1u32,
      orbitdock_protocol::conversation_contracts::TurnStatus::Undone,
    )),
    transition::Input::ThreadRolledBack { num_turns } => Some((
      *num_turns,
      orbitdock_protocol::conversation_contracts::TurnStatus::RolledBack,
    )),
    _ => None,
  };

  let now = chrono_now();
  let previous_transport_snapshot = handle.to_snapshot();
  let previous_snapshot = handle.retained_state();
  let state = handle.extract_state();
  let (new_state, effects) = transition::transition(state, input, &now);
  tracing::debug!(
    session_id = _session_id,
    work_phase = ?new_state.phase,
    pending_approval = new_state.pending_approval.is_some(),
    effect_count = effects.len(),
    "dispatch_transition_input: transition completed"
  );
  handle.apply_state(new_state);

  // Update last_message from the latest completed user/assistant row.
  // In-progress assistant streaming deltas are intentionally ignored.
  let mut unread_count_delta: Option<u64> = None;
  let previous_last_message = previous_transport_snapshot.last_message.clone();
  if let Some(snippet) = latest_completed_conversation_row(handle.rows())
    .filter(|snippet| previous_last_message.as_deref() != Some(snippet.as_str()))
  {
    handle.set_last_message(Some(snippet));
  }

  // Pass 1: Send all persist ops, collecting sequence receivers for row ops.
  let mut sequence_futures: Vec<(String, tokio::sync::oneshot::Receiver<u64>)> = Vec::new();
  let mut appended_row_ids = HashSet::new();
  let mut deferred_emits: Vec<ServerMessage> = Vec::new();
  let mut did_broadcast = false;
  let mut saw_conversation_emit = false;
  let mut suppressed_conversation_update = false;

  for effect in effects {
    match effect {
      transition::Effect::Persist(op) => {
        if matches!(
          op.as_ref(),
          transition::PersistOp::ToolCountIncrement { .. }
        ) {
          handle.increment_tool_count();
        }
        if let transition::PersistOp::RowAppend { entry, .. } = op.as_ref() {
          appended_row_ids.insert(entry.id().to_string());
        }
        let mut cmd = transition::persist_op_to_command(*op);
        // Attach a response channel to row persist ops so we get DB-assigned sequences.
        match &mut cmd {
          PersistCommand::RowAppend {
            ref entry,
            ref mut viewer_present,
            ref mut sequence_tx,
            ..
          }
          | PersistCommand::RowUpsert {
            ref entry,
            ref mut viewer_present,
            ref mut sequence_tx,
            ..
          } => {
            *viewer_present = handle.has_active_viewers();
            let row_id = entry.id().to_string();
            let (tx, rx) = tokio::sync::oneshot::channel();
            *sequence_tx = Some(tx);
            sequence_futures.push((row_id, rx));
          }
          _ => {}
        }
        let _ = persist_tx.send(cmd).await;
      }
      transition::Effect::Emit(msg) => {
        deferred_emits.push(*msg);
      }
    }
  }

  // Pass 2: Await DB-assigned sequences and update in-memory rows.
  for (row_id, rx) in sequence_futures {
    if let Ok(db_seq) = rx.await {
      handle.set_row_sequence(&row_id, db_seq);
    }
  }

  // Pass 3: Broadcast with DB-assigned sequences.
  for msg in deferred_emits {
    let mut msg = msg;
    if let ServerMessage::ConversationRowsChanged {
      ref mut upserted, ..
    } = msg
    {
      saw_conversation_emit = true;
      // Re-derive summaries from now-updated in-memory rows.
      for summary in upserted.iter_mut() {
        if let Some(row) = handle.row_by_id(summary.id()) {
          *summary = row.to_transport_summary();
        }
      }
      for entry in upserted.iter() {
        if appended_row_ids.contains(entry.id()) {
          if let Some(unread_count) = handle.note_transition_row_append(entry) {
            unread_count_delta = Some(unread_count);
          }
        }
      }
    }
    inject_approval_version(&mut msg, handle.approval_version());
    if let ServerMessage::SessionDelta { changes, .. } = &mut msg {
      include_derived_affordances_for_state_delta(changes, handle);
    }
    let should_emit = match &msg {
      ServerMessage::ConversationRowsChanged { upserted, .. } => {
        handle.should_emit_streaming_row_update(upserted)
      }
      _ => true,
    };
    if should_emit {
      handle.broadcast(msg);
      did_broadcast = true;
    } else if let ServerMessage::ConversationRowsChanged { upserted, .. } = &msg {
      if upserted
        .iter()
        .any(|entry| appended_row_ids.contains(entry.id()))
      {
        suppressed_conversation_update = true;
      }
    }
  }

  // Mark rows affected by undo/rollback and persist + broadcast the change.
  if let Some((num_turns, status)) = mark_turns_intent {
    let session_id = handle.id().to_string();
    let affected_ids = handle.mark_last_turns_status(num_turns, status);
    if !affected_ids.is_empty() {
      let _ = persist_tx
        .send(PersistCommand::RowsTurnStatusUpdate {
          session_id: session_id.clone(),
          row_ids: affected_ids.clone(),
          status,
        })
        .await;

      let upserted: Vec<_> = affected_ids
        .iter()
        .filter_map(|id| handle.row_by_id(id).map(|row| row.to_transport_summary()))
        .collect();
      if !upserted.is_empty() {
        let total = handle.total_row_count();
        handle.broadcast(ServerMessage::ConversationRowsChanged {
          session_id,
          upserted,
          removed_row_ids: vec![],
          total_row_count: total,
        });
        did_broadcast = true;
      }
    }
  }

  let mut transition_changes = transition_delta(
    previous_last_message.as_deref(),
    handle.rows(),
    unread_count_delta,
  )
  .unwrap_or_default();
  let mut has_transition_changes =
    transition_changes.last_message.is_some() || transition_changes.unread_count.is_some();
  let current_transport_snapshot = handle.to_snapshot();
  let current_snapshot = handle.retained_state();
  has_transition_changes |= include_snapshot_delta_changes(
    &mut transition_changes,
    &previous_transport_snapshot,
    &previous_snapshot,
    &current_transport_snapshot,
    &current_snapshot,
  );
  if has_transition_changes {
    handle.broadcast(ServerMessage::SessionDelta {
      session_id: handle.id().to_string(),
      changes: Box::new(transition_changes),
    });
    did_broadcast = true;
  }

  let mut fallback_surfaces: Vec<SessionSurface> = Vec::new();
  if suppressed_conversation_update {
    fallback_surfaces.push(SessionSurface::Conversation);
  }
  if !did_broadcast && !saw_conversation_emit {
    fallback_surfaces.push(SessionSurface::Detail);
  }

  if !fallback_surfaces.is_empty() {
    handle.broadcast_surface_invalidations(&fallback_surfaces);
  }
}

/// Returns `true` if the event signals the end of a turn (used to cancel
/// interrupt watchdogs).
pub(crate) fn is_turn_ending(event: &ConnectorStateEvent) -> bool {
  matches!(
    event,
    ConnectorStateEvent::TurnAborted { .. }
      | ConnectorStateEvent::TurnCompleted
      | ConnectorStateEvent::SessionEnded { .. }
  )
}

/// Spawn an interrupt watchdog that sends a synthetic `TurnAborted` after
/// 10 seconds if no turn-ending event arrives.
pub(crate) fn spawn_interrupt_watchdog(
  tx: mpsc::Sender<ConnectorStateEvent>,
  session_id: String,
  component: &'static str,
) -> JoinHandle<()> {
  tokio::spawn(async move {
    tokio::time::sleep(Duration::from_secs(10)).await;
    warn!(
        component = component,
        event = format_args!("{component}.interrupt.watchdog_fired"),
        session_id = %session_id,
        "Interrupt watchdog fired — forcing TurnAborted"
    );
    let _ = tx
      .send(ConnectorStateEvent::TurnAborted {
        reason: "interrupt_timeout".to_string(),
      })
      .await;
  })
}

pub(crate) fn abort_interrupt_watchdog(watchdog: &mut Option<JoinHandle<()>>) {
  if let Some(handle) = watchdog.take() {
    handle.abort();
  }
}

pub(crate) fn restart_interrupt_watchdog(
  watchdog: &mut Option<JoinHandle<()>>,
  tx: mpsc::Sender<ConnectorStateEvent>,
  session_id: &str,
  component: &'static str,
) {
  abort_interrupt_watchdog(watchdog);
  *watchdog = Some(spawn_interrupt_watchdog(
    tx,
    session_id.to_string(),
    component,
  ));
}

pub(crate) async fn emit_connector_error(
  session_id: &str,
  message: impl Into<String>,
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  dispatch_connector_event(
    session_id,
    ConnectorStateEvent::Error(message.into()),
    handle,
    persist_tx,
  )
  .await;
}

#[cfg(test)]
#[path = "session_command_handler_tests.rs"]
mod session_command_handler_tests;
