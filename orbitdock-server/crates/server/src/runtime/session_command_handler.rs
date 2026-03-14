//! Shared session command handler
//!
//! Processes `SessionCommand`s against a `SessionHandle`, handling queries,
//! mutations, persistence effects, and broadcasts. Used by both provider
//! event loops (Claude, Codex) and the passive session actor.

use std::time::Duration;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::{ServerMessage, SessionListItem, SessionStatus, StateChanges, WorkStatus};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

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
        } => PersistCommand::SessionUpdate {
            id,
            status,
            work_status,
            last_activity_at,
        },
        PersistOp::SetCustomName { session_id, name } => PersistCommand::SetCustomName {
            session_id,
            custom_name: name,
        },
        PersistOp::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
            permission_mode,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            model,
            effort,
        } => PersistCommand::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
            permission_mode,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            model,
            effort,
        },
    };
    let _ = persist_tx.send(cmd).await;
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
                    let _ = reply.send(SubscribeResult::Replay { events, rx });
                    return;
                }
            }
            let rx = handle.subscribe();
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
            let session_id = handle.id().to_string();
            let now = chrono_now();
            let merged_subagents = merge_subagent_updates(handle.subagents(), subagents);
            if subagent_lists_match(&merged_subagents, handle.subagents()) {
                return;
            }
            handle.set_subagents(merged_subagents.clone());
            handle.set_last_activity_at(Some(now.clone()));
            handle.broadcast(ServerMessage::SessionDelta {
                session_id,
                changes: StateChanges {
                    subagents: Some(merged_subagents),
                    last_activity_at: Some(now),
                    ..Default::default()
                },
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
            changes,
            persist_op,
        } => {
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
                changes: StateChanges {
                    status: Some(SessionStatus::Ended),
                    work_status: Some(WorkStatus::Ended),
                    last_activity_at: Some(now),
                    ..Default::default()
                },
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
                changes: StateChanges {
                    custom_name: Some(name),
                    last_activity_at: Some(chrono_now()),
                    ..Default::default()
                },
            });
            let _ = reply.send(handle.summary());
        }

        // -- Row operations --
        SessionCommand::AddRow { entry } => {
            let _ = handle.add_row(entry);
        }
        SessionCommand::ReplaceRows { rows } => {
            handle.replace_rows(rows);
        }
        SessionCommand::AddRowAndBroadcast { entry } => {
            let session_id = handle.id().to_string();
            let previous_last_message = handle.to_snapshot().last_message.clone();

            let entry = handle.add_row(entry);
            let observability_changes = row_append_delta(
                previous_last_message.as_deref(),
                &entry,
                handle.unread_count(),
            );
            if let Some(ref changes) = observability_changes {
                if let Some(Some(ref snippet)) = changes.last_message {
                    handle.set_last_message(Some(snippet.clone()));
                }
            }
            let rows_changed = ServerMessage::ConversationRowsChanged {
                session_id: session_id.clone(),
                upserted: vec![entry],
                removed_row_ids: vec![],
                total_row_count: handle.message_count() as u64,
            };
            if let ServerMessage::ConversationRowsChanged { ref upserted, .. } = rows_changed {
                if handle.should_emit_streaming_row_update(upserted) {
                    handle.broadcast(rows_changed);
                }
            }
            if let Some(changes) = observability_changes {
                handle.broadcast(ServerMessage::SessionDelta {
                    session_id: handle.id().to_string(),
                    changes,
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
                    changes: StateChanges {
                        work_status: Some(work_status),
                        pending_approval: Some(next_pending_approval.clone()),
                        approval_version: Some(approval_version),
                        ..Default::default()
                    },
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
            let prev = handle.mark_read();
            if prev > 0 {
                handle.broadcast(ServerMessage::SessionDelta {
                    session_id: handle.id().to_string(),
                    changes: StateChanges {
                        unread_count: Some(0),
                        ..Default::default()
                    },
                });
                handle.broadcast(ServerMessage::SessionListItemUpdated {
                    session: SessionListItem::from_summary(&handle.summary()),
                });
            }
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

    for effect in effects {
        match effect {
            transition::Effect::Persist(op) => {
                let _ = persist_tx
                    .send(transition::persist_op_to_command(*op))
                    .await;
            }
            transition::Effect::Emit(msg) => {
                let mut msg = *msg;
                if let ServerMessage::ConversationRowsChanged { ref upserted, .. } = msg {
                    for entry in upserted {
                        if handle.note_transition_row_append(entry) {
                            unread_count_delta = Some(handle.unread_count());
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
        }
    }

    if let Some(changes) = transition_delta(
        previous_last_message.as_deref(),
        handle.rows(),
        unread_count_delta,
    ) {
        handle.broadcast(ServerMessage::SessionDelta {
            session_id: handle.id().to_string(),
            changes,
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
