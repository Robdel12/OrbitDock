//! Claude session management
//!
//! Wraps the ClaudeConnector (bridge subprocess) and handles event forwarding.
//! Mirrors the CodexSession pattern: connector + event loop + action channel.

use std::sync::Arc;

use orbitdock_connectors::{ClaudeConnector, ConnectorEvent};
use orbitdock_protocol::ServerMessage;
use tokio::sync::{broadcast, mpsc};
use tracing::{error, info, warn};

use crate::codex_session::handle_session_command;
use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::state::SessionRegistry;
use crate::transition::{self, Effect, Input};

/// Actions that can be sent to a Claude session
#[allow(dead_code)]
pub enum ClaudeAction {
    SendMessage {
        content: String,
        model: Option<String>,
        effort: Option<String>,
    },
    Interrupt,
    ApproveTool {
        request_id: String,
        decision: String,
        message: Option<String>,
        interrupt: Option<bool>,
        updated_input: Option<serde_json::Value>,
    },
    AnswerQuestion {
        request_id: String,
        answer: String,
    },
    Compact,
    Undo,
    Resume {
        session_id: String,
    },
    Fork {
        session_id: Option<String>,
    },
    SetModel {
        model: String,
    },
    SetMaxThinking {
        tokens: u64,
    },
    SetPermissionMode {
        mode: String,
    },
    EndSession,
}

impl std::fmt::Debug for ClaudeAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SendMessage {
                content,
                model,
                effort,
            } => f
                .debug_struct("SendMessage")
                .field("content_len", &content.len())
                .field("model", model)
                .field("effort", effort)
                .finish(),
            Self::Interrupt => write!(f, "Interrupt"),
            Self::ApproveTool {
                request_id,
                decision,
                ..
            } => f
                .debug_struct("ApproveTool")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::AnswerQuestion { request_id, answer } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .field("answer_len", &answer.len())
                .finish(),
            Self::Compact => write!(f, "Compact"),
            Self::Undo => write!(f, "Undo"),
            Self::Resume { session_id } => f
                .debug_struct("Resume")
                .field("session_id", session_id)
                .finish(),
            Self::Fork { session_id } => f
                .debug_struct("Fork")
                .field("session_id", session_id)
                .finish(),
            Self::SetModel { model } => f.debug_struct("SetModel").field("model", model).finish(),
            Self::SetMaxThinking { tokens } => f
                .debug_struct("SetMaxThinking")
                .field("tokens", tokens)
                .finish(),
            Self::SetPermissionMode { mode } => f
                .debug_struct("SetPermissionMode")
                .field("mode", mode)
                .finish(),
            Self::EndSession => write!(f, "EndSession"),
        }
    }
}

/// Manages a Claude session with its connector
pub struct ClaudeSession {
    pub session_id: String,
    pub connector: ClaudeConnector,
}

impl ClaudeSession {
    /// Create a new Claude session by spawning a CLI subprocess.
    /// If `resume_id` is provided, the CLI will resume that session.
    pub async fn new(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        resume_id: Option<&str>,
        permission_mode: Option<&str>,
        allowed_tools: &[String],
        disallowed_tools: &[String],
    ) -> Result<Self, orbitdock_connectors::ConnectorError> {
        let connector = ClaudeConnector::new(
            cwd,
            model,
            resume_id,
            permission_mode,
            allowed_tools,
            disallowed_tools,
        )
        .await?;
        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Start the event forwarding loop.
    ///
    /// The actor owns the `SessionHandle` directly — no `Arc<Mutex>`.
    /// Returns `(SessionActorHandle, mpsc::Sender<ClaudeAction>)`.
    pub fn start_event_loop(
        mut self,
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

        let mut event_rx = self.connector.take_event_rx().unwrap();
        let session_id = self.session_id.clone();

        let mut session_handle = handle;
        let persist = persist_tx.clone();
        let mut claude_sdk_session_persisted = false;
        let mut first_prompt_captured = false;
        let actor_for_naming = actor_handle.clone();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Handle events from Claude connector
                    Some(event) = event_rx.recv() => {
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
                            if let Some(sdk_sid) = self.connector.claude_session_id().await {
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
                                // Guard against deleting the owning direct session when
                                // the SDK session id is identical to the OrbitDock session id.
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
                            Self::handle_event_direct(
                                &session_id,
                                event,
                                &mut session_handle,
                                &persist,
                            ).await;
                        }
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

                        if let Err(e) = Self::handle_action(&self.connector, action).await {
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
                    let _ = persist_tx.send((*op).into_persist_command()).await;
                }
                Effect::Emit(msg) => {
                    handle.broadcast(*msg);
                }
            }
        }
    }

    /// Handle an action from the WebSocket.
    async fn handle_action(
        connector: &ClaudeConnector,
        action: ClaudeAction,
    ) -> Result<(), orbitdock_connectors::ConnectorError> {
        match action {
            ClaudeAction::SendMessage {
                content,
                model,
                effort,
            } => {
                connector
                    .send_message(&content, model.as_deref(), effort.as_deref())
                    .await?;
            }
            ClaudeAction::Interrupt => {
                connector.interrupt().await?;
            }
            ClaudeAction::ApproveTool {
                request_id,
                decision,
                message,
                interrupt,
                updated_input,
            } => {
                connector
                    .approve_tool(
                        &request_id,
                        &decision,
                        message.as_deref(),
                        interrupt,
                        updated_input.as_ref(),
                    )
                    .await?;
            }
            ClaudeAction::AnswerQuestion { request_id, answer } => {
                connector.answer_question(&request_id, &answer).await?;
            }
            ClaudeAction::Compact => {
                // Send /compact as a user message — the CLI handles it as a slash command.
                // See: https://platform.claude.com/docs/en/agent-sdk/slash-commands
                connector.send_message("/compact", None, None).await?;
            }
            ClaudeAction::Undo => {
                // Send /undo as a slash command — only shown in UI if the CLI
                // reported "undo" in the init message's slash_commands array.
                connector.send_message("/undo", None, None).await?;
            }
            ClaudeAction::Resume { .. } => {
                // Resume is handled at spawn time via --resume flag.
                // This action is kept for API compatibility but is a no-op at runtime.
                warn!(
                    component = "claude_connector",
                    event = "claude.action.resume_noop",
                    "Resume action received but resume is handled at spawn time"
                );
            }
            ClaudeAction::Fork { .. } => {
                // Fork is handled at spawn time via --resume --fork-session flags.
                warn!(
                    component = "claude_connector",
                    event = "claude.action.fork_noop",
                    "Fork action received but fork is handled at spawn time"
                );
            }
            ClaudeAction::SetModel { model } => {
                connector.set_model(&model).await?;
            }
            ClaudeAction::SetMaxThinking { tokens } => {
                connector.set_max_thinking(tokens).await?;
            }
            ClaudeAction::SetPermissionMode { mode } => {
                connector.set_permission_mode(&mode).await?;
            }
            ClaudeAction::EndSession => {
                connector.shutdown().await?;
            }
        }
        Ok(())
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

fn should_remove_shadow_runtime_session(
    owning_session_id: &str,
    observed_sdk_session_id: &str,
) -> bool {
    owning_session_id != observed_sdk_session_id
}

#[cfg(test)]
mod tests {
    use super::should_remove_shadow_runtime_session;

    #[test]
    fn shadow_cleanup_skips_owning_session_id() {
        assert!(!should_remove_shadow_runtime_session(
            "owning-session",
            "owning-session"
        ));
    }

    #[test]
    fn shadow_cleanup_allows_distinct_shadow_session_id() {
        assert!(should_remove_shadow_runtime_session(
            "owning-session",
            "hook-shadow-session"
        ));
    }
}
