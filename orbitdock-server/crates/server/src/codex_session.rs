//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_connectors::{CodexConnector, ConnectorError, ConnectorEvent, SteerOutcome};
use orbitdock_protocol::ServerMessage;
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{error, info};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
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
    ) -> Result<Self, orbitdock_connectors::ConnectorError> {
        let connector = CodexConnector::new(cwd, model, approval_policy, sandbox_mode).await?;

        Ok(Self {
            session_id,
            connector,
        })
    }

    /// Get the codex-core thread ID (used to link with rollout files)
    pub fn thread_id(&self) -> &str {
        self.connector.thread_id()
    }

    /// Start the event forwarding loop
    pub fn start_event_loop(
        mut self,
        session: Arc<Mutex<SessionHandle>>,
        persist_tx: mpsc::Sender<PersistCommand>,
    ) -> mpsc::Sender<CodexAction> {
        let (action_tx, mut action_rx) = mpsc::channel::<CodexAction>(100);

        let mut event_rx = self.connector.take_event_rx().unwrap();
        let session_id = self.session_id.clone();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Handle events from Codex
                    Some(event) = event_rx.recv() => {
                        Self::handle_event(
                            &session_id,
                            event,
                            &session,
                            &persist_tx,
                        ).await;
                    }

                    // Handle actions from WebSocket
                    Some(action) = action_rx.recv() => {
                        match action {
                            CodexAction::SteerTurn { content, message_id } => {
                                let status = match self.connector.steer_turn(&content).await {
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

                                // Persist the delivery status
                                let _ = persist_tx
                                    .send(PersistCommand::MessageUpdate {
                                        session_id: session_id.to_string(),
                                        message_id: message_id.clone(),
                                        content: None,
                                        tool_output: Some(status.to_string()),
                                        duration_ms: None,
                                        is_error: None,
                                    })
                                    .await;

                                // Broadcast so the UI transitions from "sending" to delivered/fallback/failed
                                let mut session = session.lock().await;
                                session
                                    .broadcast(ServerMessage::MessageUpdated {
                                        session_id: session_id.to_string(),
                                        message_id,
                                        changes: orbitdock_protocol::MessageChanges {
                                            content: None,
                                            tool_output: Some(status.to_string()),
                                            is_error: None,
                                            duration_ms: None,
                                        },
                                    });
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

                    else => break,
                }
            }

            info!(
                component = "codex_connector",
                event = "codex.event_loop.ended",
                session_id = %session_id,
                "Codex session event loop ended"
            );
        });

        action_tx
    }

    /// Handle an event from the connector.
    ///
    /// Converts the event to an Input, runs the pure transition function,
    /// applies state changes, and executes effects (persist + broadcast).
    async fn handle_event(
        _session_id: &str,
        event: ConnectorEvent,
        session: &Arc<Mutex<SessionHandle>>,
        persist_tx: &mpsc::Sender<PersistCommand>,
    ) {
        let input = Input::from(event);
        let now = chrono_now();

        let mut session = session.lock().await;
        let state = session.extract_state();
        let (new_state, effects) = transition::transition(state, input, &now);
        session.apply_state(new_state);

        // Execute effects: persist writes + broadcast emissions
        for effect in effects {
            match effect {
                Effect::Persist(op) => {
                    let _ = persist_tx.send((*op).into_persist_command()).await;
                }
                Effect::Emit(msg) => {
                    session.broadcast(*msg);
                }
            }
        }
    }

    /// Handle an action from the WebSocket
    async fn handle_action(
        connector: &mut CodexConnector,
        action: CodexAction,
    ) -> Result<(), orbitdock_connectors::ConnectorError> {
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
                // Handled in main select loop (needs access to session + persist_tx)
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
        answers: HashMap<String, String>,
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
            } => f
                .debug_struct("SteerTurn")
                .field("content_len", &content.len())
                .field("message_id", message_id)
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

    // Simple format
    format!("{}Z", secs)
}
