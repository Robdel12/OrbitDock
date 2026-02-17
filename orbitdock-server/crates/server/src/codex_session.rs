//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::HashMap;

use orbitdock_connectors::{CodexConnector, ConnectorError, ConnectorEvent, SteerOutcome};
use orbitdock_protocol::{MessageType, ServerMessage};
use tokio::sync::{mpsc, oneshot};
use tracing::{error, info, warn};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::{PersistOp, SessionCommand, SubscribeResult};
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

    /// Resume an existing Codex session from its rollout file (preserves conversation history)
    pub async fn resume(
        session_id: String,
        cwd: &str,
        thread_id: &str,
        model: Option<&str>,
        approval_policy: Option<&str>,
        sandbox_mode: Option<&str>,
    ) -> Result<Self, orbitdock_connectors::ConnectorError> {
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
            loop {
                tokio::select! {
                    // Handle events from Codex connector
                    Some(event) = event_rx.recv() => {
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

                                let _ = persist
                                    .send(PersistCommand::MessageUpdate {
                                        session_id: session_id.to_string(),
                                        message_id: message_id.clone(),
                                        content: None,
                                        tool_output: Some(status.to_string()),
                                        duration_ms: None,
                                        is_error: None,
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

                    // Handle session commands from external callers
                    Some(cmd) = command_rx.recv() => {
                        handle_session_command(cmd, &mut session_handle, &persist).await;
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
                    let _ = persist_tx.send((*op).into_persist_command()).await;
                }
                Effect::Emit(msg) => {
                    handle.broadcast(*msg);
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

/// Convert a PersistOp into a PersistCommand and send it.
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
        } => PersistCommand::SetSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
        },
    };
    let _ = persist_tx.send(cmd).await;
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
        SessionCommand::ProcessEvent { event } => {
            let now = chrono_now();
            let state = handle.extract_state();
            let (new_state, effects) = transition::transition(state, event, &now);
            handle.apply_state(new_state);

            for effect in effects {
                match effect {
                    transition::Effect::Persist(op) => {
                        let _ = persist_tx.send((*op).into_persist_command()).await;
                    }
                    transition::Effect::Emit(msg) => {
                        handle.broadcast(*msg);
                    }
                }
            }
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
            handle.set_status(orbitdock_protocol::SessionStatus::Ended);
            handle.set_work_status(orbitdock_protocol::WorkStatus::Ended);
            handle.set_last_activity_at(Some(now.clone()));
            handle.broadcast(ServerMessage::SessionDelta {
                session_id,
                changes: orbitdock_protocol::StateChanges {
                    status: Some(orbitdock_protocol::SessionStatus::Ended),
                    work_status: Some(orbitdock_protocol::WorkStatus::Ended),
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
                changes: orbitdock_protocol::StateChanges {
                    custom_name: Some(name),
                    last_activity_at: Some(chrono_now()),
                    ..Default::default()
                },
            });
            let _ = reply.send(handle.summary());
        }

        // -- Message operations --
        SessionCommand::AddMessage { message } => {
            handle.add_message(message);
        }
        SessionCommand::ReplaceMessages { messages } => {
            handle.replace_messages(messages);
        }
        SessionCommand::AddMessageAndBroadcast { message } => {
            let session_id = handle.id().to_string();
            // Update last_message for dashboard context lines
            if matches!(
                message.message_type,
                MessageType::User | MessageType::Assistant
            ) {
                let truncated: String = message.content.chars().take(200).collect();
                handle.set_last_message(Some(truncated));
            }
            handle.add_message(message.clone());
            handle.broadcast(ServerMessage::MessageAppended {
                session_id,
                message,
            });
        }
        SessionCommand::TakePendingApproval { request_id, reply } => {
            let atype = handle.take_pending_approval(&request_id);
            let amendment = handle.take_pending_amendment(&request_id);
            let _ = reply.send((atype, amendment));
        }
        SessionCommand::SetPendingApproval {
            request_id,
            approval_type,
            proposed_amendment,
        } => {
            handle.set_pending_approval(request_id, approval_type, proposed_amendment);
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

    format!("{}Z", secs)
}
