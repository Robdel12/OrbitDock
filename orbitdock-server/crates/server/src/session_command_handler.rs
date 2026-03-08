//! Shared session command handler
//!
//! Processes `SessionCommand`s against a `SessionHandle`, handling queries,
//! mutations, persistence effects, and broadcasts. Used by both provider
//! event loops (Claude, Codex) and the passive session actor.

use std::time::Duration;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::{
    Message, MessageType, ServerMessage, SessionStatus, StateChanges, WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_command::{
    PendingApprovalResolution, PersistOp, SessionCommand, SubscribeResult,
};
use crate::transition;

/// Inject approval_version into ApprovalRequested and SessionDelta messages.
pub(crate) fn inject_approval_version(msg: &mut ServerMessage, version: u64) {
    match msg {
        ServerMessage::ApprovalRequested {
            approval_version, ..
        } => {
            *approval_version = Some(version);
        }
        ServerMessage::SessionDelta { changes, .. } => {
            if changes.pending_approval.is_some() && changes.approval_version.is_none() {
                changes.approval_version = Some(version);
            }
        }
        _ => {}
    }
}

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
        } => PersistCommand::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
            permission_mode,
        },
    };
    let _ = persist_tx.send(cmd).await;
}

fn completed_conversation_message_snippet(message: &Message) -> Option<String> {
    if !matches!(
        message.message_type,
        MessageType::User | MessageType::Assistant
    ) {
        return None;
    }
    if message.is_in_progress {
        return None;
    }
    Some(message.content.chars().take(200).collect())
}

fn latest_completed_conversation_message(messages: &[Message]) -> Option<String> {
    messages
        .iter()
        .rev()
        .find_map(completed_conversation_message_snippet)
}

/// Handle a SessionCommand on the owned SessionHandle.
/// This is used by both the CodexSession event loop and the passive SessionActor.
pub async fn handle_session_command(
    cmd: SessionCommand,
    handle: &mut SessionHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    match cmd {
        SessionCommand::GetState { reply } => {
            let _ = reply.send(handle.state());
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
            let state = handle.state();
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
            // Walk messages in reverse, count user messages, return the Nth one's ID
            let result = handle
                .messages()
                .iter()
                .rev()
                .filter(|m| m.message_type == orbitdock_protocol::MessageType::User)
                .nth(num_turns_from_end.saturating_sub(1) as usize)
                .map(|m| m.id.clone());
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
            handle.set_config(approval_policy, sandbox_mode);
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

        // -- Message operations --
        SessionCommand::AddMessage { message } => {
            let _ = handle.add_message(message);
        }
        SessionCommand::ReplaceMessages { messages } => {
            handle.replace_messages(messages);
        }
        SessionCommand::AddMessageAndBroadcast { message } => {
            let session_id = handle.id().to_string();
            let mut last_message_delta: Option<String> = None;
            let should_broadcast_unread = !matches!(message.message_type, MessageType::User | MessageType::Steer);

            if let Some(snippet) = completed_conversation_message_snippet(&message) {
                let previous = handle.to_snapshot().last_message.clone();
                if previous.as_deref() != Some(snippet.as_str()) {
                    handle.set_last_message(Some(snippet.clone()));
                    last_message_delta = Some(snippet);
                }
            }

            let message = handle.add_message(message);
            handle.broadcast(ServerMessage::MessageAppended {
                session_id,
                message,
            });

            if last_message_delta.is_some() || should_broadcast_unread {
                handle.broadcast(ServerMessage::SessionDelta {
                    session_id: handle.id().to_string(),
                    changes: StateChanges {
                        last_message: last_message_delta.map(Some),
                        unread_count: should_broadcast_unread.then(|| handle.unread_count()),
                        ..Default::default()
                    },
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
            }
            let _ = reply.send(handle.unread_count());
        }
        SessionCommand::LoadTranscriptAndSync {
            path,
            session_id,
            reply,
        } => {
            let state = handle.state();
            if state.messages.is_empty() {
                match crate::persistence::load_messages_from_transcript_path(&path, &session_id)
                    .await
                {
                    Ok(messages) if !messages.is_empty() => {
                        handle.replace_messages(messages);
                        let _ = reply.send(Some(handle.state()));
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

/// Get current time as ISO 8601 string.
pub(crate) fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    format!("{}Z", secs)
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
    let state = handle.extract_state();
    let (new_state, effects) = transition::transition(state, input, &now);
    handle.apply_state(new_state);

    // Update last_message from the latest completed user/assistant message.
    // In-progress assistant streaming deltas are intentionally ignored.
    let mut last_message_delta: Option<String> = None;
    let mut unread_count_delta: Option<u64> = None;
    let previous_last_message = handle.to_snapshot().last_message.clone();
    if let Some(snippet) = latest_completed_conversation_message(handle.messages()) {
        if previous_last_message.as_deref() != Some(snippet.as_str()) {
            handle.set_last_message(Some(snippet.clone()));
            last_message_delta = Some(snippet);
        }
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
                if let ServerMessage::MessageAppended { ref message, .. } = msg {
                    if handle.note_transition_message_append(message) {
                        unread_count_delta = Some(handle.unread_count());
                    }
                }
                if let ServerMessage::MessageUpdated {
                    ref session_id,
                    ref message_id,
                    ref changes,
                } = msg
                {
                    tracing::info!(
                        component = "session_handler",
                        event = "broadcast.message_updated",
                        session_id = %session_id,
                        message_id = %message_id,
                        has_tool_output = changes.tool_output.is_some(),
                        tool_output_chars = changes.tool_output.as_ref().map(|s| s.len()).unwrap_or(0),
                        is_in_progress = ?changes.is_in_progress,
                        "Broadcasting MessageUpdated to clients"
                    );
                }
                inject_approval_version(&mut msg, handle.approval_version());
                handle.broadcast(msg);
            }
        }
    }

    if last_message_delta.is_some() || unread_count_delta.is_some() {
        handle.broadcast(ServerMessage::SessionDelta {
            session_id: handle.id().to_string(),
            changes: StateChanges {
                last_message: last_message_delta.map(Some),
                unread_count: unread_count_delta,
                ..Default::default()
            },
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
    use orbitdock_protocol::{Provider, SessionStatus, StateChanges};
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn transition_message_create_updates_unread_and_broadcasts_delta() {
        let (persist_tx, mut persist_rx) = mpsc::channel(8);
        let mut handle = SessionHandle::new(
            "session-unread".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        let session_id = handle.id().to_string();
        let mut rx = handle.subscribe();

        dispatch_transition_input(
            &session_id,
            transition::Input::MessageCreated(Message {
                id: "assistant-1".to_string(),
                session_id: String::new(),
                sequence: None,
                message_type: MessageType::Assistant,
                content: "stream started".to_string(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: "2026-03-08T01:15:00Z".to_string(),
                duration_ms: None,
                images: vec![],
            }),
            &mut handle,
            &persist_tx,
        )
        .await;

        let state = handle.state();
        assert_eq!(state.status, SessionStatus::Active);
        assert_eq!(state.unread_count, 1);

        let first = rx.recv().await.expect("expected message append");
        assert!(
            matches!(first, ServerMessage::MessageAppended { .. }),
            "expected first broadcast to be MessageAppended, got {first:?}"
        );

        let second = rx.recv().await.expect("expected unread session delta");
        match second {
            ServerMessage::SessionDelta { changes, .. } => {
                assert_eq!(changes.unread_count, Some(1));
            }
            other => panic!("expected SessionDelta, got {other:?}"),
        }

        let persist = persist_rx.recv().await.expect("expected persist op");
        assert!(
            matches!(persist, PersistCommand::MessageAppend { .. }),
            "expected message append persistence, got {persist:?}"
        );
    }

    #[tokio::test]
    async fn subscribe_with_current_revision_returns_empty_replay_not_snapshot() {
        let (persist_tx, _persist_rx) = mpsc::channel(8);
        let mut handle = SessionHandle::new(
            "session-replay-empty".to_string(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        handle.broadcast(ServerMessage::SessionDelta {
            session_id: handle.id().to_string(),
            changes: StateChanges::default(),
        });

        let (reply_tx, reply_rx) = oneshot::channel();
        handle_session_command(
            SessionCommand::Subscribe {
                since_revision: Some(1),
                reply: reply_tx,
            },
            &mut handle,
            &persist_tx,
        )
        .await;

        match reply_rx.await.expect("subscribe reply") {
            SubscribeResult::Replay { events, .. } => {
                assert!(
                    events.is_empty(),
                    "expected empty replay when subscribing at current revision"
                );
            }
            SubscribeResult::Snapshot { .. } => {
                panic!("expected empty replay, not snapshot");
            }
        }
    }
}
