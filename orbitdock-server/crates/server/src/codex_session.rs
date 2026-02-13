//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_connectors::{ApprovalType, CodexConnector, ConnectorError, ConnectorEvent};
use orbitdock_protocol::{ServerMessage, WorkStatus};
use tokio::sync::{mpsc, oneshot, Mutex};
use tracing::{debug, error, info, warn};

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
                            error!(
                                component = "codex_connector",
                                event = "codex.action.failed",
                                session_id = %session_id,
                                error = %e,
                                "Failed to handle codex action"
                            );
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
                debug!(
                    component = "codex_connector",
                    event = "codex.turn.started",
                    session_id = %session_id
                );
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
                debug!(
                    component = "codex_connector",
                    event = "codex.turn.completed",
                    session_id = %session_id
                );
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
                info!(
                    component = "codex_connector",
                    event = "codex.turn.aborted",
                    session_id = %session_id,
                    reason = %reason,
                    "Codex turn aborted"
                );
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
                info!(
                    component = "approval",
                    event = "approval.requested",
                    session_id = %session_id,
                    request_id = %request_id,
                    approval_type = %match approval_type {
                        ApprovalType::Exec => "exec",
                        ApprovalType::Patch => "patch",
                        ApprovalType::Question => "question",
                    },
                    "Approval requested by connector"
                );
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

                let _ = persist_tx
                    .send(PersistCommand::ApprovalRequested {
                        session_id: session_id.to_string(),
                        request_id: request.id.clone(),
                        approval_type: request.approval_type,
                        tool_name: Some(match request.approval_type {
                            orbitdock_protocol::ApprovalType::Exec => "Bash".to_string(),
                            orbitdock_protocol::ApprovalType::Patch => "Edit".to_string(),
                            orbitdock_protocol::ApprovalType::Question => "Question".to_string(),
                        }),
                        command: request.command.clone(),
                        file_path: request.file_path.clone(),
                        cwd: Some(session.project_path().to_string()),
                        proposed_amendment: request.proposed_amendment.clone(),
                    })
                    .await;

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
                info!(
                    component = "session",
                    event = "session.thread_name.updated",
                    session_id = %session_id,
                    name = %name,
                    "Thread name updated"
                );
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
                info!(
                    component = "session",
                    event = "session.ended.by_connector",
                    session_id = %session_id,
                    reason = %reason,
                    "Session ended by connector"
                );
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

            ConnectorEvent::SkillsList { skills, errors } => {
                session
                    .broadcast(ServerMessage::SkillsList {
                        session_id: session_id.to_string(),
                        skills,
                        errors,
                    })
                    .await;
            }

            ConnectorEvent::RemoteSkillsList { skills } => {
                session
                    .broadcast(ServerMessage::RemoteSkillsList {
                        session_id: session_id.to_string(),
                        skills,
                    })
                    .await;
            }

            ConnectorEvent::RemoteSkillDownloaded { id, name, path } => {
                session
                    .broadcast(ServerMessage::RemoteSkillDownloaded {
                        session_id: session_id.to_string(),
                        id,
                        name,
                        path,
                    })
                    .await;
            }

            ConnectorEvent::SkillsUpdateAvailable => {
                session
                    .broadcast(ServerMessage::SkillsUpdateAvailable {
                        session_id: session_id.to_string(),
                    })
                    .await;
            }

            ConnectorEvent::McpToolsList {
                tools,
                resources,
                resource_templates,
                auth_statuses,
            } => {
                debug!(
                    component = "codex_connector",
                    event = "codex.mcp.tools_list",
                    session_id = %session_id,
                    tool_count = tools.len(),
                    "MCP tools list received"
                );
                session
                    .broadcast(ServerMessage::McpToolsList {
                        session_id: session_id.to_string(),
                        tools,
                        resources,
                        resource_templates,
                        auth_statuses,
                    })
                    .await;
            }

            ConnectorEvent::McpStartupUpdate { server, status } => {
                info!(
                    component = "codex_connector",
                    event = "codex.mcp.startup_update",
                    session_id = %session_id,
                    server = %server,
                    "MCP startup update"
                );
                session
                    .broadcast(ServerMessage::McpStartupUpdate {
                        session_id: session_id.to_string(),
                        server,
                        status,
                    })
                    .await;
            }

            ConnectorEvent::McpStartupComplete {
                ready,
                failed,
                cancelled,
            } => {
                info!(
                    component = "codex_connector",
                    event = "codex.mcp.startup_complete",
                    session_id = %session_id,
                    ready_count = ready.len(),
                    failed_count = failed.len(),
                    cancelled_count = cancelled.len(),
                    "MCP startup complete"
                );
                session
                    .broadcast(ServerMessage::McpStartupComplete {
                        session_id: session_id.to_string(),
                        ready,
                        failed,
                        cancelled,
                    })
                    .await;
            }

            ConnectorEvent::ContextCompacted => {
                debug!(
                    component = "codex_connector",
                    event = "codex.context.compacted",
                    session_id = %session_id,
                    "Context compacted"
                );
                // Turn lifecycle (TurnStarted→TurnCompleted) handles status transitions.
                // Just broadcast the event so clients know compaction happened.
                session
                    .broadcast(ServerMessage::ContextCompacted {
                        session_id: session_id.to_string(),
                    })
                    .await;
            }

            ConnectorEvent::UndoStarted { message } => {
                info!(
                    component = "codex_connector",
                    event = "codex.undo.started",
                    session_id = %session_id,
                    "Undo started"
                );
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

                session
                    .broadcast(ServerMessage::UndoStarted {
                        session_id: session_id.to_string(),
                        message,
                    })
                    .await;
            }

            ConnectorEvent::UndoCompleted { success, message } => {
                info!(
                    component = "codex_connector",
                    event = "codex.undo.completed",
                    session_id = %session_id,
                    success = success,
                    "Undo completed"
                );
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

                session
                    .broadcast(ServerMessage::UndoCompleted {
                        session_id: session_id.to_string(),
                        success,
                        message,
                    })
                    .await;
            }

            ConnectorEvent::ThreadRolledBack { num_turns } => {
                info!(
                    component = "codex_connector",
                    event = "codex.thread.rolled_back",
                    session_id = %session_id,
                    num_turns = num_turns,
                    "Thread rolled back"
                );
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

                session
                    .broadcast(ServerMessage::ThreadRolledBack {
                        session_id: session_id.to_string(),
                        num_turns,
                    })
                    .await;
            }

            ConnectorEvent::Error(msg) => {
                warn!(
                    component = "codex_connector",
                    event = "codex.error",
                    session_id = %session_id,
                    error = %msg,
                    "Connector error"
                );
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
                skills,
            } => {
                connector
                    .send_message(&content, model.as_deref(), effort.as_deref(), &skills)
                    .await?;
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
            Self::SendMessage { content, model, effort, skills } => f
                .debug_struct("SendMessage")
                .field("content_len", &content.len())
                .field("model", model)
                .field("effort", effort)
                .field("skills_count", &skills.len())
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
            Self::ApproveExec { request_id, decision, .. } => f
                .debug_struct("ApproveExec")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::ApprovePatch { request_id, decision } => f
                .debug_struct("ApprovePatch")
                .field("request_id", request_id)
                .field("decision", decision)
                .finish(),
            Self::AnswerQuestion { request_id, .. } => f
                .debug_struct("AnswerQuestion")
                .field("request_id", request_id)
                .finish(),
            Self::UpdateConfig { approval_policy, sandbox_mode } => f
                .debug_struct("UpdateConfig")
                .field("approval_policy", approval_policy)
                .field("sandbox_mode", sandbox_mode)
                .finish(),
            Self::SetThreadName { name } => f
                .debug_struct("SetThreadName")
                .field("name", name)
                .finish(),
            Self::ListMcpTools => write!(f, "ListMcpTools"),
            Self::RefreshMcpServers => write!(f, "RefreshMcpServers"),
            Self::Compact => write!(f, "Compact"),
            Self::Undo => write!(f, "Undo"),
            Self::ThreadRollback { num_turns } => f
                .debug_struct("ThreadRollback")
                .field("num_turns", num_turns)
                .finish(),
            Self::EndSession => write!(f, "EndSession"),
            Self::ForkSession { source_session_id, nth_user_message, model, .. } => f
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
