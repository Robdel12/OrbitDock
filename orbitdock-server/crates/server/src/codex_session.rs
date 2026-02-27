//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_connector_codex::{CodexConnector, SteerOutcome};
use orbitdock_connector_core::{ConnectorError, ConnectorEvent};
use orbitdock_protocol::{MessageType, ServerMessage};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_command_handler::{handle_session_command, inject_approval_version};
use crate::state::SessionRegistry;
use crate::transition::{self, Effect, Input};

/// Manages a Codex session with its connector
pub struct CodexSession {
    pub session_id: String,
    pub connector: CodexConnector,
}

impl CodexSession {
    /// Create a new Codex session
    pub async fn new(
        session_id: String,
        cwd: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, orbitdock_connector_core::ConnectorError> {
        let connector = CodexConnector::new(cwd, model, approval_policy, sandbox_mode).await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Resume an existing Codex session from its rollout file (preserves conversation history)
    pub async fn resume(
        session_id: String,
        cwd: &str,
        thread_id: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, orbitdock_connector_core::ConnectorError> {
        let connector =
            CodexConnector::resume(cwd, thread_id, model, approval_policy, sandbox_mode).await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Get the codex-core thread ID (used to link with rollout files)
    pub fn thread_id(&self) -> &str {
        self.connector.thread_id()
    }

    /// Start the event forwarding loop.
    ///
    /// The actor owns the `SessionHandle` directly — no `Arc<Mutex>`.
    /// Returns `(SessionActorHandle, mpsc::Sender<CodexAction>)`.
    pub fn start_event_loop(
        mut self,
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

        let mut event_rx = self.connector.take_event_rx().unwrap();
        let session_id = self.session_id.clone();

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

                        Self::handle_event_direct(
                            &session_id,
                            event,
                            &mut session_handle,
                            &persist,
                        ).await;
                    }

                    // Handle synthetic events from watchdog
                    Some(event) = watchdog_rx.recv() => {
                        Self::handle_event_direct(
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
                                let status = match self
                                    .connector
                                    .steer_turn(&content, &images, &mentions)
                                    .await
                                {
                                    Ok(SteerOutcome::Accepted) => "delivered",
                                    Ok(SteerOutcome::FellBackToNewTurn) => "fallback",
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
                                match self.connector.interrupt().await {
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
                                        Self::handle_event_direct(
                                            &session_id,
                                            ConnectorEvent::Error(format!("Interrupt failed: {}", e)),
                                            &mut session_handle,
                                            &persist,
                                        ).await;
                                    }
                                }
                            }
                            other => {
                                if let Err(e) = Self::handle_action(&mut self.connector, other).await {
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

    /// Handle an action from the WebSocket
    async fn handle_action(
        connector: &mut CodexConnector,
        action: CodexAction,
    ) -> Result<(), orbitdock_connector_core::ConnectorError> {
        match action {
            CodexAction::SendMessage {
                content,
                model,
                effort,
                skills,
                images,
                mentions,
            } => {
                connector
                    .send_message(
                        &content,
                        model.as_deref(),
                        effort.as_deref(),
                        &skills,
                        &images,
                        &mentions,
                    )
                    .await?;
            }
            CodexAction::SteerTurn { .. } => {
                unreachable!("SteerTurn should be handled in the main event loop");
            }
            CodexAction::Interrupt => {
                connector.interrupt().await?;
            }
            CodexAction::ListSkills { cwds, force_reload } => {
                connector.list_skills(cwds, force_reload).await?;
            }
            CodexAction::ListRemoteSkills => {
                connector.list_remote_skills().await?;
            }
            CodexAction::DownloadRemoteSkill { hazelnut_id } => {
                connector.download_remote_skill(&hazelnut_id).await?;
            }
            CodexAction::ApproveExec {
                request_id,
                decision,
                proposed_amendment,
            } => {
                connector
                    .approve_exec(&request_id, &decision, proposed_amendment)
                    .await?;
            }
            CodexAction::ApprovePatch {
                request_id,
                decision,
            } => {
                connector.approve_patch(&request_id, &decision).await?;
            }
            CodexAction::AnswerQuestion {
                request_id,
                answers,
            } => {
                connector.answer_question(&request_id, answers).await?;
            }
            CodexAction::UpdateConfig {
                approval_policy,
                sandbox_mode,
            } => {
                connector
                    .update_config(approval_policy.as_deref(), sandbox_mode.as_deref())
                    .await?;
            }
            CodexAction::SetThreadName { name } => {
                connector.set_thread_name(&name).await?;
            }
            CodexAction::ListMcpTools => {
                connector.list_mcp_tools().await?;
            }
            CodexAction::RefreshMcpServers => {
                connector.refresh_mcp_servers().await?;
            }
            CodexAction::Compact => {
                connector.compact().await?;
            }
            CodexAction::Undo => {
                connector.undo().await?;
            }
            CodexAction::ThreadRollback { num_turns } => {
                connector.thread_rollback(num_turns).await?;
            }
            CodexAction::EndSession => {
                connector.shutdown().await?;
            }
            CodexAction::ForkSession {
                nth_user_message,
                model,
                approval_policy,
                sandbox_mode,
                cwd,
                reply_tx,
                ..
            } => {
                let result = connector
                    .fork_thread(
                        nth_user_message,
                        model.as_deref(),
                        approval_policy.as_deref(),
                        sandbox_mode.as_deref(),
                        cwd.as_deref(),
                    )
                    .await;
                let _ = reply_tx.send(result);
            }
        }
        Ok(())
    }
}

/// Actions that can be sent to a Codex session
pub enum CodexAction {
    SendMessage {
        content: String,
        model: Option<String>,
        effort: Option<String>,
        skills: Vec<orbitdock_protocol::SkillInput>,
        images: Vec<orbitdock_protocol::ImageInput>,
        mentions: Vec<orbitdock_protocol::MentionInput>,
    },
    SteerTurn {
        content: String,
        message_id: String,
        images: Vec<orbitdock_protocol::ImageInput>,
        mentions: Vec<orbitdock_protocol::MentionInput>,
    },
    Interrupt,
    ListSkills {
        cwds: Vec<String>,
        force_reload: bool,
    },
    ListRemoteSkills,
    DownloadRemoteSkill {
        hazelnut_id: String,
    },
    ApproveExec {
        request_id: String,
        decision: String,
        proposed_amendment: Option<Vec<String>>,
    },
    ApprovePatch {
        request_id: String,
        decision: String,
    },
    AnswerQuestion {
        request_id: String,
        answers: HashMap<String, Vec<String>>,
    },
    UpdateConfig {
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },
    SetThreadName {
        name: String,
    },
    ListMcpTools,
    RefreshMcpServers,
    Compact,
    Undo,
    ThreadRollback {
        num_turns: u32,
    },
    EndSession,
    ForkSession {
        source_session_id: String,
        nth_user_message: Option<u32>,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        cwd: Option<String>,
        reply_tx: oneshot::Sender<Result<(CodexConnector, String), ConnectorError>>,
    },
}

impl std::fmt::Debug for CodexAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SendMessage {
                content,
                model,
                effort,
                skills,
                images,
                mentions,
            } => f
                .debug_struct("SendMessage")
                .field("content_len", &content.len())
                .field("model", model)
                .field("effort", effort)
                .field("skills_count", &skills.len())
                .field("images_count", &images.len())
                .field("mentions_count", &mentions.len())
                .finish(),
            Self::SteerTurn {
                content,
                message_id,
                images,
                mentions,
            } => f
                .debug_struct("SteerTurn")
                .field("content_len", &content.len())
                .field("message_id", message_id)
                .field("images_count", &images.len())
                .field("mentions_count", &mentions.len())
                .finish(),
            Self::Interrupt => write!(f, "Interrupt"),
            Self::ListSkills { cwds, force_reload } => f
                .debug_struct("ListSkills")
                .field("cwds", cwds)
                .field("force_reload", force_reload)
                .finish(),
            Self::ListRemoteSkills => write!(f, "ListRemoteSkills"),
            Self::DownloadRemoteSkill { hazelnut_id } => f
                .debug_struct("DownloadRemoteSkill")
                .field("hazelnut_id", hazelnut_id)
                .finish(),
            Self::ApproveExec {
                request_id,
                decision,
                ..
            } => f
                .debug_struct("ApproveExec")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::ApprovePatch {
                request_id,
                decision,
            } => f
                .debug_struct("ApprovePatch")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::AnswerQuestion { request_id, .. } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .finish(),
            Self::UpdateConfig {
                approval_policy,
                sandbox_mode,
            } => f
                .debug_struct("UpdateConfig")
                .field("approval_policy", approval_policy)
                .field("sandbox_mode", sandbox_mode)
                .finish(),
            Self::SetThreadName { name } => {
                f.debug_struct("SetThreadName").field("name", name).finish()
            }
            Self::ListMcpTools => write!(f, "ListMcpTools"),
            Self::RefreshMcpServers => write!(f, "RefreshMcpServers"),
            Self::Compact => write!(f, "Compact"),
            Self::Undo => write!(f, "Undo"),
            Self::ThreadRollback { num_turns } => f
                .debug_struct("ThreadRollback")
                .field("num_turns", num_turns)
                .finish(),
            Self::EndSession => write!(f, "EndSession"),
            Self::ForkSession {
                source_session_id,
                nth_user_message,
                model,
                ..
            } => f
                .debug_struct("ForkSession")
                .field("source_session_id", source_session_id)
                .field("nth_user_message", nth_user_message)
                .field("model", model)
                .finish(),
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
