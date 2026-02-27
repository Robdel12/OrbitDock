//! Claude session management
//!
//! Wraps the ClaudeConnector (bridge subprocess) and handles event forwarding.
//! Mirrors the CodexSession pattern: connector + event loop + action channel.

use std::sync::Arc;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::ServerMessage;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_command_handler::handle_session_command;
use crate::state::SessionRegistry;
use crate::transition::{self, Effect, Input};

// Re-export so existing server code doesn't break
pub use orbitdock_connector_claude::session::{
    should_remove_shadow_runtime_session, ClaudeAction, ClaudeSession,
};

/// Start the Claude session event forwarding loop.
///
/// The actor owns the `SessionHandle` directly — no `Arc<Mutex>`.
/// Returns `(SessionActorHandle, mpsc::Sender<ClaudeAction>)`.
pub fn start_event_loop(
    mut session: ClaudeSession,
    handle: SessionHandle,
    persist_tx: mpsc::Sender<PersistCommand>,
    list_tx: broadcast::Sender<ServerMessage>,
    state: Arc<SessionRegistry>,
) -> (SessionActorHandle, mpsc::Sender<ClaudeAction>) {
    let (action_tx, mut action_rx) = mpsc::channel::<ClaudeAction>(100);
    let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

    let snapshot = handle.snapshot_arc();
    let id = handle.id().to_string();
    handle.refresh_snapshot();

    let actor_handle = SessionActorHandle::new(id.clone(), command_tx, snapshot);

    let mut event_rx = session.connector.take_event_rx().unwrap();
    let session_id = session.session_id.clone();

    let mut session_handle = handle;
    let persist = persist_tx.clone();
    let mut claude_sdk_session_persisted = false;
    let mut first_prompt_captured = false;
    let actor_for_naming = actor_handle.clone();

    tokio::spawn(async move {
        // Watchdog channel for synthetic events (interrupt timeout)
        let (watchdog_tx, mut watchdog_rx) = mpsc::channel::<ConnectorEvent>(4);
        let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

        loop {
            tokio::select! {
                // Handle events from Claude connector
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

                    // Register hook session IDs as managed threads so the hook
                    // handler doesn't create duplicate passive sessions. On --resume
                    // the CLI creates a new session_id for hooks.
                    if let ConnectorEvent::HookSessionId(ref hook_sid) = event {
                        if hook_sid != &session_id {
                            info!(
                                component = "claude_connector",
                                event = "claude.hook_session_id.registered",
                                session_id = %session_id,
                                hook_session_id = %hook_sid,
                                "Registering hook session ID as managed thread"
                            );
                            state.register_claude_thread(&session_id, hook_sid);
                            // Clean up any shadow row the hook handler already created
                            let _ = persist
                                .send(PersistCommand::CleanupClaudeShadowSession {
                                    claude_sdk_session_id: hook_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                })
                                .await;
                            if state.remove_session(hook_sid).is_some() {
                                state.broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: hook_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                });
                            }
                        }
                    }

                    // Persist the Claude SDK session ID on first opportunity
                    if !claude_sdk_session_persisted {
                        if let Some(sdk_sid) = session.connector.claude_session_id().await {
                            claude_sdk_session_persisted = true;
                            info!(
                                component = "claude_connector",
                                event = "claude.session_id.persisted",
                                session_id = %session_id,
                                claude_sdk_session_id = %sdk_sid,
                                "Persisting Claude SDK session ID"
                            );
                            let _ = persist
                                .send(PersistCommand::SetClaudeSdkSessionId {
                                    session_id: session_id.clone(),
                                    claude_sdk_session_id: sdk_sid.clone(),
                                })
                                .await;
                            // Register so hook handlers can recognize this thread
                            state.register_claude_thread(&session_id, &sdk_sid);
                            // End the shadow row created by hooks using the SDK session ID
                            let _ = persist
                                .send(PersistCommand::CleanupClaudeShadowSession {
                                    claude_sdk_session_id: sdk_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                })
                                .await;
                            // Remove the shadow session from runtime if it exists.
                            if should_remove_shadow_runtime_session(&session_id, &sdk_sid)
                                && state.remove_session(&sdk_sid).is_some()
                            {
                                state.broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: sdk_sid,
                                    reason: "managed_direct_session".to_string(),
                                });
                            }
                        }
                    }

                    // HookSessionId is fully handled above; skip transition
                    if !matches!(event, ConnectorEvent::HookSessionId(_)) {
                        handle_event_direct(
                            &session_id,
                            event,
                            &mut session_handle,
                            &persist,
                        ).await;
                    }
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
                    // Capture first user message as first_prompt
                    if !first_prompt_captured {
                        if let ClaudeAction::SendMessage { ref content, .. } = action {
                            first_prompt_captured = true;
                            let prompt = content.clone();
                            let _ = persist
                                .send(PersistCommand::ClaudePromptIncrement {
                                    id: session_id.clone(),
                                    first_prompt: Some(prompt.clone()),
                                })
                                .await;

                            // Broadcast first_prompt delta to UI
                            let changes = orbitdock_protocol::StateChanges {
                                first_prompt: Some(Some(prompt.clone())),
                                ..Default::default()
                            };
                            let _ = actor_for_naming
                                .send(crate::session_command::SessionCommand::ApplyDelta {
                                    changes,
                                    persist_op: None,
                                })
                                .await;

                            // Trigger AI naming (fire-and-forget)
                            crate::ai_naming::spawn_naming_task(
                                session_id.clone(),
                                prompt,
                                actor_for_naming.clone(),
                                persist.clone(),
                                list_tx.clone(),
                            );
                        }
                    }

                    if matches!(action, ClaudeAction::Interrupt) {
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
                                        component = "claude_connector",
                                        event = "claude.interrupt.watchdog_fired",
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
                                    component = "claude_connector",
                                    event = "claude.interrupt.failed",
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
                    } else if let Err(e) = ClaudeSession::handle_action(&session.connector, action).await {
                        error!(
                            component = "claude_connector",
                            event = "claude.action.failed",
                            session_id = %session_id,
                            error = %e,
                            "Failed to handle Claude action"
                        );
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
        state.remove_claude_action_tx(&session_id);

        info!(
            component = "claude_connector",
            event = "claude.event_loop.ended",
            session_id = %session_id,
            "Claude session event loop ended"
        );
    });

    (actor_handle, action_tx)
}

/// Handle an event from the connector using the transition function.
async fn handle_event_direct(
    session_id: &str,
    event: ConnectorEvent,
    handle: &mut SessionHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    let event_desc = format!("{:?}", &event);
    let input = Input::from(event);
    let now = chrono_now();

    let state = handle.extract_state();
    let (new_state, effects) = transition::transition(state, input, &now);
    handle.apply_state(new_state);

    // Truncate at a safe UTF-8 char boundary
    let safe_end = (0..=120.min(event_desc.len()))
        .rev()
        .find(|&i| event_desc.is_char_boundary(i))
        .unwrap_or(0);
    tracing::debug!(
        component = "claude_session",
        event = "claude.transition.processed",
        session_id = %session_id,
        connector_event = %&event_desc[..safe_end],
        effect_count = effects.len(),
        "Transition processed"
    );

    for effect in effects {
        match effect {
            Effect::Persist(op) => {
                let _ = persist_tx
                    .send(transition::persist_op_to_command(*op))
                    .await;
            }
            Effect::Emit(msg) => {
                handle.broadcast(*msg);
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
