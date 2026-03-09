//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::sync::Arc;

use orbitdock_protocol::ServerMessage;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{error, info};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_command_handler::{
    dispatch_connector_event, dispatch_transition_input, handle_session_command, is_turn_ending,
    spawn_interrupt_watchdog,
};
use crate::state::SessionRegistry;

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
        let (watchdog_tx, mut watchdog_rx) = mpsc::channel(4);
        let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

        loop {
            tokio::select! {
                Some(event) = event_rx.recv() => {
                    if is_turn_ending(&event) {
                        if let Some(h) = interrupt_watchdog.take() { h.abort(); }
                    }

                    // Enrich EnvironmentChanged events with worktree info
                    let enriched_event = match &event {
                        orbitdock_connector_core::ConnectorEvent::EnvironmentChanged {
                            cwd: Some(cwd), ..
                        } => {
                            let git_info = crate::git::resolve_git_info(cwd).await;
                            if let Some(ref info) = git_info {
                                let mut input = crate::transition::Input::from(event);
                                if let crate::transition::Input::EnvironmentChanged {
                                    ref mut repository_root,
                                    ref mut is_worktree,
                                    ..
                                } = input
                                {
                                    *repository_root = Some(info.common_dir_root.clone());
                                    *is_worktree = Some(info.is_worktree);
                                }
                                // Dispatch enriched input directly
                                dispatch_transition_input(
                                    &session_id, input, &mut session_handle, &persist,
                                ).await;
                                continue;
                            }
                            event
                        }
                        _ => event,
                    };

                    dispatch_connector_event(
                        &session_id, enriched_event, &mut session_handle, &persist,
                    ).await;
                }

                Some(event) = watchdog_rx.recv() => {
                    dispatch_connector_event(
                        &session_id, event, &mut session_handle, &persist,
                    ).await;
                }

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
                                    if let Some(h) = interrupt_watchdog.take() { h.abort(); }
                                    interrupt_watchdog = Some(spawn_interrupt_watchdog(
                                        watchdog_tx.clone(),
                                        session_id.clone(),
                                        "codex_connector",
                                    ));
                                }
                                Err(e) => {
                                    error!(
                                        component = "codex_connector",
                                        event = "codex.interrupt.failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Interrupt failed, injecting error event"
                                    );
                                    dispatch_connector_event(
                                        &session_id,
                                        orbitdock_connector_core::ConnectorEvent::Error(
                                            format!("Interrupt failed: {e}"),
                                        ),
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

                Some(cmd) = command_rx.recv() => {
                    handle_session_command(cmd, &mut session_handle, &persist).await;
                }

                else => break,
            }
        }

        if let Some(h) = interrupt_watchdog.take() {
            h.abort();
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
