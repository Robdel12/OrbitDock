//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_connectors::{ApprovalType, CodexConnector, ConnectorEvent};
use orbitdock_protocol::{ServerMessage, WorkStatus};
use tokio::sync::{mpsc, Mutex};
use tracing::{error, info, warn};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;

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
                        if let Err(e) = Self::handle_action(&mut self.connector, action).await {
                            error!("Failed to handle action: {}", e);
                        }
                    }

                    else => break,
                }
            }

            info!("Codex session {} event loop ended", session_id);
        });

        action_tx
    }

    /// Handle an event from the connector
    async fn handle_event(
        session_id: &str,
        event: ConnectorEvent,
        session: &Arc<Mutex<SessionHandle>>,
        persist_tx: &mpsc::Sender<PersistCommand>,
    ) {
        let mut session = session.lock().await;

        match event {
            ConnectorEvent::TurnStarted => {
                session.set_work_status(WorkStatus::Working);

                let _ = persist_tx
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.to_string(),
                        status: None,
                        work_status: Some(WorkStatus::Working),
                        last_activity_at: Some(chrono_now()),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.to_string(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(WorkStatus::Working),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                    })
                    .await;
            }

            ConnectorEvent::TurnCompleted => {
                session.set_work_status(WorkStatus::Waiting);

                let _ = persist_tx
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.to_string(),
                        status: None,
                        work_status: Some(WorkStatus::Waiting),
                        last_activity_at: Some(chrono_now()),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.to_string(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(WorkStatus::Waiting),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                    })
                    .await;
            }

            ConnectorEvent::TurnAborted { reason } => {
                info!("Turn aborted: {}", reason);
                session.set_work_status(WorkStatus::Waiting);

                let _ = persist_tx
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.to_string(),
                        status: None,
                        work_status: Some(WorkStatus::Waiting),
                        last_activity_at: Some(chrono_now()),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.to_string(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(WorkStatus::Waiting),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                    })
                    .await;
            }

            ConnectorEvent::MessageCreated(mut message) => {
                message.session_id = session_id.to_string();
                session.add_message(message.clone());

                let _ = persist_tx
                    .send(PersistCommand::MessageAppend {
                        session_id: session_id.to_string(),
                        message: message.clone(),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::MessageAppended {
                        session_id: session_id.to_string(),
                        message,
                    })
                    .await;
            }

            ConnectorEvent::MessageUpdated {
                message_id,
                content,
                tool_output,
                is_error,
                duration_ms,
            } => {
                let _ = persist_tx
                    .send(PersistCommand::MessageUpdate {
                        session_id: session_id.to_string(),
                        message_id: message_id.clone(),
                        content: content.clone(),
                        tool_output: tool_output.clone(),
                        duration_ms,
                        is_error,
                    })
                    .await;

                session
                    .broadcast(ServerMessage::MessageUpdated {
                        session_id: session_id.to_string(),
                        message_id,
                        changes: orbitdock_protocol::MessageChanges {
                            content,
                            tool_output,
                            is_error,
                            duration_ms,
                        },
                    })
                    .await;
            }

            ConnectorEvent::ApprovalRequested {
                request_id,
                approval_type,
                command,
                file_path,
                diff,
                question,
                proposed_amendment,
            } => {
                let approval_type_proto = match approval_type {
                    ApprovalType::Exec => orbitdock_protocol::ApprovalType::Exec,
                    ApprovalType::Patch => orbitdock_protocol::ApprovalType::Patch,
                    ApprovalType::Question => orbitdock_protocol::ApprovalType::Question,
                };

                let work_status = match approval_type {
                    ApprovalType::Question => WorkStatus::Question,
                    _ => WorkStatus::Permission,
                };

                session.set_work_status(work_status);

                // Track the approval type and proposed amendment so websocket handler can dispatch correctly
                session.set_pending_approval(
                    request_id.clone(),
                    approval_type_proto,
                    proposed_amendment.clone(),
                );

                let request = orbitdock_protocol::ApprovalRequest {
                    id: request_id.clone(),
                    session_id: session_id.to_string(),
                    approval_type: approval_type_proto,
                    command,
                    file_path,
                    diff,
                    question,
                    proposed_amendment,
                };

                session
                    .broadcast(ServerMessage::ApprovalRequested {
                        session_id: session_id.to_string(),
                        request,
                    })
                    .await;
            }

            ConnectorEvent::TokensUpdated(usage) => {
                session.update_tokens(usage.clone());

                let _ = persist_tx
                    .send(PersistCommand::TokensUpdate {
                        session_id: session_id.to_string(),
                        usage: usage.clone(),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::TokensUpdated {
                        session_id: session_id.to_string(),
                        usage,
                    })
                    .await;
            }

            ConnectorEvent::DiffUpdated(diff) => {
                session.update_diff(diff.clone());

                let _ = persist_tx
                    .send(PersistCommand::TurnStateUpdate {
                        session_id: session_id.to_string(),
                        diff: Some(diff),
                        plan: None,
                    })
                    .await;
            }

            ConnectorEvent::PlanUpdated(plan) => {
                session.update_plan(plan.clone());

                let _ = persist_tx
                    .send(PersistCommand::TurnStateUpdate {
                        session_id: session_id.to_string(),
                        diff: None,
                        plan: Some(plan),
                    })
                    .await;
            }

            ConnectorEvent::ThreadNameUpdated(name) => {
                info!("Thread name updated for {}: {}", session_id, name);
                session.set_custom_name(Some(name.clone()));

                let _ = persist_tx
                    .send(PersistCommand::SetCustomName {
                        session_id: session_id.to_string(),
                        custom_name: Some(name.clone()),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.to_string(),
                        changes: orbitdock_protocol::StateChanges {
                            custom_name: Some(Some(name)),
                            ..Default::default()
                        },
                    })
                    .await;
            }

            ConnectorEvent::SessionEnded { reason } => {
                info!("Session ended: {}", reason);
                session.set_work_status(WorkStatus::Ended);

                let _ = persist_tx
                    .send(PersistCommand::SessionEnd {
                        id: session_id.to_string(),
                        reason: reason.clone(),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionEnded {
                        session_id: session_id.to_string(),
                        reason,
                    })
                    .await;
            }

            ConnectorEvent::Error(msg) => {
                warn!("Connector error: {}", msg);
                // Transition to waiting so the UI isn't stuck on "working"
                session.set_work_status(WorkStatus::Waiting);

                let _ = persist_tx
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.to_string(),
                        status: None,
                        work_status: Some(WorkStatus::Waiting),
                        last_activity_at: Some(chrono_now()),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.to_string(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(WorkStatus::Waiting),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                    })
                    .await;
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
            } => {
                connector
                    .send_message(&content, model.as_deref(), effort.as_deref())
                    .await?;
            }
            CodexAction::Interrupt => {
                connector.interrupt().await?;
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
            CodexAction::EndSession => {
                connector.shutdown().await?;
            }
        }
        Ok(())
    }
}

/// Actions that can be sent to a Codex session
#[derive(Debug)]
pub enum CodexAction {
    SendMessage {
        content: String,
        model: Option<String>,
        effort: Option<String>,
    },
    Interrupt,
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
    EndSession,
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
