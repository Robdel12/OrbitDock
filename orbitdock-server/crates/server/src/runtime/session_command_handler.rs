//! Shared session command handler
//!
//! Processes `SessionCommand`s against a `SessionHandle`, handling queries,
//! mutations, persistence effects, and broadcasts. Used by both provider
//! event loops (Claude, Codex) and the passive session actor.

use std::time::Duration;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{
    compute_tool_display, ConversationRow, ToolDisplayInput,
};
use orbitdock_protocol::domain_events::ToolKind;
use orbitdock_protocol::{
    CodexIntegrationMode, Provider, ServerMessage, SessionListItem, SessionStatus, StateChanges,
    WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, warn};

use crate::domain::sessions::session::{SessionConfigPatch, SessionHandle};
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
            last_activity_at,
            last_progress_at,
        } => PersistCommand::SessionUpdate {
            id,
            status,
            work_status,
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

    handle.broadcast(ServerMessage::SessionDelta {
        session_id: session_id.clone(),
        changes: Box::new(StateChanges {
            unread_count: Some(0),
            ..Default::default()
        }),
    });
    handle.broadcast(ServerMessage::SessionListItemUpdated {
        session: SessionListItem::from_summary(&handle.summary()),
    });
}

fn merge_subagent_updates(
    existing: &[orbitdock_protocol::SubagentInfo],
    incoming: Vec<orbitdock_protocol::SubagentInfo>,
) -> Vec<orbitdock_protocol::SubagentInfo> {
    let mut merged = existing.to_vec();

    for updated in incoming {
        if let Some(index) = merged.iter().position(|subagent| subagent.id == updated.id) {
            merged[index] = updated;
        } else {
            merged.push(updated);
        }
    }

    merged.sort_by(|lhs, rhs| lhs.started_at.cmp(&rhs.started_at));
    merged
}

fn subagent_lists_match(
    lhs: &[orbitdock_protocol::SubagentInfo],
    rhs: &[orbitdock_protocol::SubagentInfo],
) -> bool {
    lhs.len() == rhs.len()
        && lhs.iter().zip(rhs.iter()).all(|(left, right)| {
            left.id == right.id
                && left.agent_type == right.agent_type
                && left.started_at == right.started_at
                && left.ended_at == right.ended_at
                && left.provider == right.provider
                && left.label == right.label
                && left.status == right.status
                && left.task_summary == right.task_summary
                && left.result_summary == right.result_summary
                && left.error_summary == right.error_summary
                && left.parent_subagent_id == right.parent_subagent_id
                && left.model == right.model
                && left.last_activity_at == right.last_activity_at
        })
}

fn should_suppress_connector_user_echo(handle: &SessionHandle, event: &ConnectorEvent) -> bool {
    if handle.provider() != Provider::Codex
        || handle.to_snapshot().codex_integration_mode != Some(CodexIntegrationMode::Direct)
    {
        return false;
    }

    let ConnectorEvent::ConversationRowCreated(entry) = event else {
        return false;
    };

    let ConversationRow::User(message) = &entry.row else {
        return false;
    };

    handle.has_user_row_with_content(&message.content)
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
            if let Some(since_rev) = since_revision {
                if let Some(events) = handle.replay_since(since_rev) {
                    let rx = handle.subscribe();
                    persist_and_broadcast_mark_read(handle, persist_tx).await;
                    let _ = reply.send(SubscribeResult::Replay { events, rx });
                    return;
                }
            }
            let rx = handle.subscribe();
            persist_and_broadcast_mark_read(handle, persist_tx).await;
            let state = handle.retained_state();
            let _ = reply.send(SubscribeResult::Snapshot {
                state: Box::new(state),
                rx,
            });
        }
        SessionCommand::GetWorkStatus { reply } => {
            let _ = reply.send(handle.work_status());
        }
        SessionCommand::GetLastTool { reply } => {
            let _ = reply.send(handle.last_tool().map(String::from));
        }
        SessionCommand::GetCustomName { reply } => {
            let _ = reply.send(handle.custom_name().map(String::from));
        }
        SessionCommand::GetProvider { reply } => {
            let _ = reply.send(handle.provider());
        }
        SessionCommand::GetProjectPath { reply } => {
            let _ = reply.send(handle.project_path().to_string());
        }
        SessionCommand::GetMessageCount { reply } => {
            let _ = reply.send(handle.message_count());
        }
        SessionCommand::GetConversationBootstrap { limit, reply } => {
            let _ = reply.send(handle.conversation_bootstrap(limit));
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
                .filter(|entry| matches!(entry.row, ConversationRow::User(_)))
                .nth(num_turns_from_end.saturating_sub(1) as usize)
                .map(|entry| entry.id().to_string());
            let _ = reply.send(result);
        }
        SessionCommand::ProcessEvent { event } => {
            let session_id = handle.id().to_string();
            dispatch_transition_input(&session_id, event, handle, persist_tx).await;
        }
        SessionCommand::SetCustomName { name } => {
            handle.set_custom_name(name);
        }
        SessionCommand::SetWorkStatus { status } => {
            handle.set_work_status(status);
        }
        SessionCommand::SetModel { model } => {
            handle.set_model(model);
        }
        SessionCommand::SetConfig {
            approval_policy,
            sandbox_mode,
        } => {
            handle.set_config(SessionConfigPatch {
                approval_policy,
                sandbox_mode,
                ..Default::default()
            });
        }
        SessionCommand::SetTranscriptPath { path } => {
            handle.set_transcript_path(path);
        }
        SessionCommand::SetProjectName { name } => {
            handle.set_project_name(name);
        }
        SessionCommand::SetStatus { status } => {
            handle.set_status(status);
        }
        SessionCommand::SetStartedAt { ts } => {
            handle.set_started_at(ts);
        }
        SessionCommand::SetLastActivityAt { ts } => {
            handle.set_last_activity_at(ts);
        }
        SessionCommand::SetCodexIntegrationMode { mode } => {
            handle.set_codex_integration_mode(mode);
        }
        SessionCommand::SetClaudeIntegrationMode { mode } => {
            handle.set_claude_integration_mode(mode);
        }
        SessionCommand::SetForkedFrom { source_id } => {
            handle.set_forked_from(source_id);
        }
        SessionCommand::SetLastTool { tool } => {
            handle.set_last_tool(tool);
        }
        SessionCommand::SetSubagents { subagents } => {
            let merged_subagents = merge_subagent_updates(handle.subagents(), subagents);
            if subagent_lists_match(&merged_subagents, handle.subagents()) {
                return;
            }
            handle.set_subagents(merged_subagents.clone());
            handle.broadcast(ServerMessage::SessionDelta {
                session_id: handle.id().to_string(),
                changes: Box::new(StateChanges {
                    subagents: Some(merged_subagents),
                    ..Default::default()
                }),
            });
        }
        SessionCommand::SetPendingAttention {
            pending_tool_name,
            pending_tool_input,
            pending_question,
        } => {
            handle.set_pending_attention(pending_tool_name, pending_tool_input, pending_question);
        }

        // -- Compound operations --
        SessionCommand::ApplyDelta {
            mut changes,
            persist_op,
        } => {
            // Derive steerable from work_status so clients never compute it locally.
            if let Some(ws) = changes.work_status {
                changes.steerable = Some(ws == WorkStatus::Working);
            }
            let session_id = handle.id().to_string();
            handle.apply_changes(&changes);
            if let Some(op) = persist_op {
                execute_persist_op(op, persist_tx).await;
            }
            handle.broadcast(ServerMessage::SessionDelta {
                session_id,
                changes,
            });
        }
        SessionCommand::EndLocally => {
            let session_id = handle.id().to_string();
            let now = chrono_now();
            handle.set_status(SessionStatus::Ended);
            handle.set_work_status(WorkStatus::Ended);
            handle.set_last_activity_at(Some(now.clone()));
            handle.broadcast(ServerMessage::SessionDelta {
                session_id,
                changes: Box::new(StateChanges {
                    status: Some(SessionStatus::Ended),
                    work_status: Some(WorkStatus::Ended),
                    last_activity_at: Some(now),
                    ..Default::default()
                }),
            });
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
        SessionCommand::AddRow { entry } => {
            let _ = handle.add_row(entry);
        }
        SessionCommand::ReplaceRows { rows } => {
            handle.replace_rows(rows);
            // Force resync is rare — broadcast all rows so clients recover.
            let all_rows: Vec<_> = handle.rows().iter().map(|e| e.to_summary()).collect();
            handle.broadcast(ServerMessage::ConversationRowsChanged {
                session_id: handle.id().to_string(),
                upserted: all_rows,
                removed_row_ids: vec![],
                total_row_count: handle.message_count() as u64,
            });
        }
        SessionCommand::AddRowAndBroadcast { entry } => {
            let session_id = handle.id().to_string();
            let previous_last_message = handle.to_snapshot().last_message.clone();

            let entry = handle.add_row(entry);
            let row_id = entry.id().to_string();
            let viewer_present = handle.has_active_viewers();
            let unread_count_delta = handle.unread_count_after_row_append(&entry);

            // Persist-first: send to DB with response channel, await DB-assigned sequence.
            let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
            let _ = persist_tx
                .send(PersistCommand::RowAppend {
                    session_id: session_id.clone(),
                    entry: entry.clone(),
                    viewer_present,
                    sequence_tx: Some(seq_tx),
                })
                .await;

            // Update in-memory row with DB-authoritative sequence before broadcasting.
            if let Ok(db_seq) = seq_rx.await {
                handle.set_row_sequence(&row_id, db_seq);
            }

            let observability_changes =
                row_append_delta(previous_last_message.as_deref(), &entry, unread_count_delta);
            if let Some(ref changes) = observability_changes {
                if let Some(Some(ref snippet)) = changes.last_message {
                    handle.set_last_message(Some(snippet.clone()));
                }
            }
            // Re-derive summary from the now-updated in-memory row.
            let summary = handle
                .row_by_id(&row_id)
                .map(|r| r.to_summary())
                .unwrap_or_else(|| entry.to_summary());
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
        }
        SessionCommand::UpsertRowAndBroadcast { entry } => {
            let session_id = handle.id().to_string();
            let entry = handle.upsert_row(entry);
            let row_id = entry.id().to_string();

            // Persist-first: send to DB with response channel, await DB-assigned sequence.
            let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
            let _ = persist_tx
                .send(PersistCommand::RowUpsert {
                    session_id: session_id.clone(),
                    entry: entry.clone(),
                    viewer_present: handle.has_active_viewers(),
                    sequence_tx: Some(seq_tx),
                })
                .await;

            // Update in-memory row with DB-authoritative sequence before broadcasting.
            if let Ok(db_seq) = seq_rx.await {
                handle.set_row_sequence(&row_id, db_seq);
            }

            // Re-derive summary from the now-updated in-memory row.
            let summary = handle
                .row_by_id(&row_id)
                .map(|r| r.to_summary())
                .unwrap_or_else(|| entry.to_summary());
            let rows_changed = ServerMessage::ConversationRowsChanged {
                session_id,
                upserted: vec![summary],
                removed_row_ids: vec![],
                total_row_count: handle.message_count() as u64,
            };
            handle.broadcast(rows_changed);
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

                let session_id = handle.id().to_string();
                let row_id = entry.id().to_string();
                let entry = handle.upsert_row(entry);

                let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
                let _ = persist_tx
                    .send(PersistCommand::RowUpsert {
                        session_id: session_id.clone(),
                        entry: entry.clone(),
                        viewer_present: handle.has_active_viewers(),
                        sequence_tx: Some(seq_tx),
                    })
                    .await;
                if let Ok(db_seq) = seq_rx.await {
                    handle.set_row_sequence(&row_id, db_seq);
                }

                let summary = handle
                    .row_by_id(&row_id)
                    .map(|r| r.to_summary())
                    .unwrap_or_else(|| entry.to_summary());
                handle.broadcast(ServerMessage::ConversationRowsChanged {
                    session_id,
                    upserted: vec![summary],
                    removed_row_ids: vec![],
                    total_row_count: handle.message_count() as u64,
                });
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
                handle.broadcast(ServerMessage::SessionDelta {
                    session_id,
                    changes: Box::new(StateChanges {
                        work_status: Some(work_status),
                        pending_approval: Some(next_pending_approval.clone()),
                        approval_version: Some(approval_version),
                        ..Default::default()
                    }),
                });
            }

            let _ = reply.send(PendingApprovalResolution {
                approval_type,
                proposed_amendment,
                next_pending_approval,
                work_status,
                approval_version,
            });
        }
        SessionCommand::SetPendingApproval {
            request_id,
            approval_type,
            proposed_amendment,
            tool_name,
            tool_input,
            question,
        } => {
            handle.set_pending_approval(
                request_id,
                approval_type,
                proposed_amendment,
                tool_name,
                tool_input,
                question,
            );
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
        SessionCommand::LoadTranscriptAndSync {
            path,
            session_id,
            reply,
        } => {
            let state = handle.retained_state();
            if state.rows.is_empty() {
                match crate::infrastructure::persistence::load_messages_from_transcript_path(
                    &path,
                    &session_id,
                )
                .await
                {
                    Ok(rows) if !rows.is_empty() => {
                        handle.replace_rows(rows);
                        let _ = reply.send(Some(handle.retained_state()));
                    }
                    _ => {
                        let _ = reply.send(Some(state));
                    }
                }
            } else {
                let _ = reply.send(Some(state));
            }
        }
    }

    // Unconditional snapshot refresh — ensures the ArcSwap is always current
    // regardless of which command ran above.
    handle.refresh_snapshot();
}

/// Dispatch a `ConnectorEvent` through the transition state machine.
///
/// Shared by both provider event loops (Claude, Codex). Converts the event
/// to a transition `Input`, runs the state machine, applies effects (persist
/// + broadcast with approval version injection), and refreshes the snapshot.
pub(crate) async fn dispatch_connector_event(
    session_id: &str,
    event: ConnectorEvent,
    handle: &mut SessionHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    if should_suppress_connector_user_echo(handle, &event) {
        if let ConnectorEvent::ConversationRowCreated(entry) = &event {
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

    let event = match event {
        ConnectorEvent::ConversationRowCreated(mut entry) => {
            entry.row =
                crate::domain::conversation_semantics::upgrade_row(handle.provider(), entry.row);
            ConnectorEvent::ConversationRowCreated(entry)
        }
        ConnectorEvent::ConversationRowUpdated { row_id, mut entry } => {
            entry.row =
                crate::domain::conversation_semantics::upgrade_row(handle.provider(), entry.row);
            ConnectorEvent::ConversationRowUpdated { row_id, entry }
        }
        other => other,
    };
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
    let now = chrono_now();
    let previous_list_item = SessionListItem::from_summary(&handle.summary());
    let state = handle.extract_state();
    let (new_state, effects) = transition::transition(state, input, &now);
    handle.apply_state(new_state);

    // Update last_message from the latest completed user/assistant row.
    // In-progress assistant streaming deltas are intentionally ignored.
    let mut unread_count_delta: Option<u64> = None;
    let previous_last_message = handle.to_snapshot().last_message.clone();
    if let Some(snippet) = latest_completed_conversation_row(handle.rows())
        .filter(|snippet| previous_last_message.as_deref() != Some(snippet.as_str()))
    {
        handle.set_last_message(Some(snippet));
    }

    // Pass 1: Send all persist ops, collecting sequence receivers for row ops.
    let mut sequence_futures: Vec<(String, tokio::sync::oneshot::Receiver<u64>)> = Vec::new();
    let mut deferred_emits: Vec<ServerMessage> = Vec::new();

    for effect in effects {
        match effect {
            transition::Effect::Persist(op) => {
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
            // Re-derive summaries from now-updated in-memory rows.
            for summary in upserted.iter_mut() {
                if let Some(row) = handle.row_by_id(summary.id()) {
                    *summary = row.to_summary();
                }
            }
            for entry in upserted.iter() {
                if let Some(unread_count) = handle.note_transition_row_append(entry) {
                    unread_count_delta = Some(unread_count);
                }
            }
        }
        inject_approval_version(&mut msg, handle.approval_version());
        let should_emit = match &msg {
            ServerMessage::ConversationRowsChanged { upserted, .. } => {
                handle.should_emit_streaming_row_update(upserted)
            }
            _ => true,
        };
        if should_emit {
            handle.broadcast(msg);
        }
    }

    if let Some(changes) = transition_delta(
        previous_last_message.as_deref(),
        handle.rows(),
        unread_count_delta,
    ) {
        handle.broadcast(ServerMessage::SessionDelta {
            session_id: handle.id().to_string(),
            changes: Box::new(changes),
        });
    }

    let next_list_item = SessionListItem::from_summary(&handle.summary());
    if next_list_item != previous_list_item {
        handle.broadcast(ServerMessage::SessionListItemUpdated {
            session: next_list_item,
        });
    }

    handle.refresh_snapshot();
}

/// Returns `true` if the event signals the end of a turn (used to cancel
/// interrupt watchdogs).
pub(crate) fn is_turn_ending(event: &ConnectorEvent) -> bool {
    matches!(
        event,
        ConnectorEvent::TurnAborted { .. }
            | ConnectorEvent::TurnCompleted
            | ConnectorEvent::SessionEnded { .. }
    )
}

/// Spawn an interrupt watchdog that sends a synthetic `TurnAborted` after
/// 10 seconds if no turn-ending event arrives.
pub(crate) fn spawn_interrupt_watchdog(
    tx: mpsc::Sender<ConnectorEvent>,
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
            .send(ConnectorEvent::TurnAborted {
                reason: "interrupt_timeout".to_string(),
            })
            .await;
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use orbitdock_protocol::conversation_contracts::{ConversationRowEntry, MessageRowContent};

    fn user_entry(session_id: &str, row_id: &str, content: &str) -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: session_id.to_string(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::User(MessageRowContent {
                id: row_id.to_string(),
                content: content.to_string(),
                turn_id: None,
                timestamp: None,
                is_streaming: false,
                images: vec![],
                memory_citation: None,
            }),
        }
    }

    #[test]
    fn suppresses_duplicate_codex_user_echo_for_direct_sessions() {
        let mut handle = SessionHandle::new(
            "session-1".to_string(),
            Provider::Codex,
            "/repo".to_string(),
        );
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        handle.add_row(user_entry("session-1", "user-http-1", "hello world"));

        let event = ConnectorEvent::ConversationRowCreated(user_entry(
            "session-1",
            "user-codex-1",
            "hello world",
        ));

        assert!(should_suppress_connector_user_echo(&handle, &event));
    }

    #[test]
    fn does_not_suppress_distinct_user_message_content() {
        let mut handle = SessionHandle::new(
            "session-1".to_string(),
            Provider::Codex,
            "/repo".to_string(),
        );
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        handle.add_row(user_entry("session-1", "user-http-1", "hello world"));

        let event = ConnectorEvent::ConversationRowCreated(user_entry(
            "session-1",
            "user-codex-1",
            "different",
        ));

        assert!(!should_suppress_connector_user_echo(&handle, &event));
    }
}
