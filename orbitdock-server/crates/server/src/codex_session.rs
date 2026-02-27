//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::sync::Arc;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::{MessageType, ServerMessage};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_command_handler::{handle_session_command, inject_approval_version};
use crate::state::SessionRegistry;
use crate::transition::{self, Effect, Input};

// Re-export so existing server code doesn't break
pub use orbitdock_connector_codex::session::{CodexAction, CodexSession};

/// Start the Codex session event forwarding loop.
///
/// The actor owns the `SessionHandle` directly — no `Arc<Mutex>`.
/// Returns `(SessionActorHandle, mpsc::Sender<CodexAction>)`.
pub fn start_event_loop(
    mut session: CodexSession,
    handle: SessionHandle,
    persist_tx: mpsc::Sender<PersistCommand>,
    state: Arc<SessionRegistry>,
) -> (SessionActorHandle, mpsc::Sender<CodexAction>) {
    let (action_tx, mut action_rx) = mpsc::channel::<CodexAction>(100);
    let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

    let snapshot = handle.snapshot_arc();
    let id = handle.id().to_string();
    handle.refresh_snapshot();

    let actor_handle = SessionActorHandle::new(id.clone(), command_tx, snapshot);

    let mut event_rx = session.connector.take_event_rx().unwrap();
    let session_id = session.session_id.clone();

    let mut session_handle = handle;
    let persist = persist_tx.clone();

    tokio::spawn(async move {
        // Watchdog channel for synthetic events (interrupt timeout)
        let (watchdog_tx, mut watchdog_rx) = mpsc::channel::<ConnectorEvent>(4);
        let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

        loop {
            tokio::select! {
                // Handle events from Codex connector
                Some(event) = event_rx.recv() => {
                    // Cancel watchdog on turn-ending events
                    if matches!(
                        event,
                        ConnectorEvent::TurnAborted { .. }
                        | ConnectorEvent::TurnCompleted
                        | ConnectorEvent::SessionEnded { .. }
                    ) {
                        if let Some(handle) = interrupt_watchdog.take() {
                            handle.abort();
                        }
                    }

                    handle_event_direct(
                        &session_id,
                        event,
                        &mut session_handle,
                        &persist,
                    ).await;
                }

                // Handle synthetic events from watchdog
                Some(event) = watchdog_rx.recv() => {
                    handle_event_direct(
                        &session_id,
                        event,
                        &mut session_handle,
                        &persist,
                    ).await;
                }

                // Handle actions from WebSocket
                Some(action) = action_rx.recv() => {
                    match action {
                        CodexAction::SteerTurn {
                            content,
                            message_id,
                            images,
                            mentions,
                        } => {
                            let status = match session
                                .connector
                                .steer_turn(&content, &images, &mentions)
                                .await
                            {
                                Ok(orbitdock_connector_codex::SteerOutcome::Accepted) => "delivered",
                                Ok(orbitdock_connector_codex::SteerOutcome::FellBackToNewTurn) => "fallback",
                                Err(e) => {
                                    error!(
                                        component = "codex_connector",
                                        event = "codex.steer.failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Steer turn failed"
                                    );
                                    "failed"
                                }
                            };

                            let _ = persist
                                .send(PersistCommand::MessageUpdate {
                                    session_id: session_id.to_string(),
                                    message_id: message_id.clone(),
                                    content: None,
                                    tool_output: Some(status.to_string()),
                                    duration_ms: None,
                                    is_error: None,
                                    is_in_progress: None,
                                })
                                .await;

                            session_handle
                                .broadcast(ServerMessage::MessageUpdated {
                                    session_id: session_id.to_string(),
                                    message_id,
                                    changes: orbitdock_protocol::MessageChanges {
                                        content: None,
                                        tool_output: Some(status.to_string()),
                                        is_error: None,
                                        is_in_progress: None,
                                        duration_ms: None,
                                    },
                                });
                        }
                        CodexAction::Interrupt => {
                            match session.connector.interrupt().await {
                                Ok(()) => {
                                    // Cancel any previous watchdog
                                    if let Some(handle) = interrupt_watchdog.take() {
                                        handle.abort();
                                    }
                                    // Spawn watchdog: if no turn-ending event within 10s,
                                    // inject synthetic TurnAborted
                                    let wd_tx = watchdog_tx.clone();
                                    let wd_sid = session_id.clone();
                                    interrupt_watchdog = Some(tokio::spawn(async move {
                                        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                                        warn!(
                                            component = "codex_connector",
                                            event = "codex.interrupt.watchdog_fired",
                                            session_id = %wd_sid,
                                            "Interrupt watchdog fired — forcing TurnAborted"
                                        );
                                        let _ = wd_tx.send(ConnectorEvent::TurnAborted {
                                            reason: "interrupt_timeout".to_string(),
                                        }).await;
                                    }));
                                }
                                Err(e) => {
                                    error!(
                                        component = "codex_connector",
                                        event = "codex.interrupt.failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Interrupt failed, injecting error event"
                                    );
                                    handle_event_direct(
                                        &session_id,
                                        ConnectorEvent::Error(format!("Interrupt failed: {}", e)),
                                        &mut session_handle,
                                        &persist,
                                    ).await;
                                }
                            }
                        }
                        other => {
                            if let Err(e) = CodexSession::handle_action(&mut session.connector, other).await {
                                error!(
                                    component = "codex_connector",
                                    event = "codex.action.failed",
                                    session_id = %session_id,
                                    error = %e,
                                    "Failed to handle codex action"
                                );
                            }
                        }
                    }
                }

                // Handle session commands from external callers
                Some(cmd) = command_rx.recv() => {
                    handle_session_command(cmd, &mut session_handle, &persist).await;
                }

                else => break,
            }
        }

        // Clean up on exit
        if let Some(handle) = interrupt_watchdog.take() {
            handle.abort();
        }
        state.remove_codex_action_tx(&session_id);

        info!(
            component = "codex_connector",
            event = "codex.event_loop.ended",
            session_id = %session_id,
            "Codex session event loop ended"
        );
    });

    (actor_handle, action_tx)
}

/// Handle an event from the connector using the transition function.
/// Directly mutates the owned SessionHandle (no lock needed).
async fn handle_event_direct(
    _session_id: &str,
    event: ConnectorEvent,
    handle: &mut SessionHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    let input = Input::from(event);
    let now = chrono_now();

    let state = handle.extract_state();
    let (new_state, effects) = transition::transition(state, input, &now);
    handle.apply_state(new_state);

    // Update last_message from the latest user/assistant message
    if let Some(last) = handle
        .messages()
        .iter()
        .rev()
        .find(|m| matches!(m.message_type, MessageType::User | MessageType::Assistant))
    {
        let truncated: String = last.content.chars().take(200).collect();
        handle.set_last_message(Some(truncated));
    }

    for effect in effects {
        match effect {
            Effect::Persist(op) => {
                let _ = persist_tx
                    .send(transition::persist_op_to_command(*op))
                    .await;
            }
            Effect::Emit(msg) => {
                let mut msg = *msg;
                inject_approval_version(&mut msg, handle.approval_version());
                handle.broadcast(msg);
            }
        }
    }
}

/// Get current time as ISO 8601 string
fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    format!("{}Z", secs)
}
