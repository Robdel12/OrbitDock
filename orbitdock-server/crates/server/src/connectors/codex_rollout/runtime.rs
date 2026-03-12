use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use orbitdock_connector_codex::rollout_parser::{
    self, current_time_rfc3339, current_time_unix_z, rollout_session_id_hint, RolloutEvent,
    RolloutFileProcessor, SessionSource, DEBOUNCE_MS, SESSION_TIMEOUT_SECS,
};
use orbitdock_protocol::{
    CodexIntegrationMode, Message, MessageType, Provider, ServerMessage, SessionListItem,
    SessionStatus, StateChanges, TokenUsageSnapshotKind, WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::info;

use crate::domain::sessions::session::SessionHandle;
use crate::domain::sessions::session_naming::name_from_first_prompt;
use crate::infrastructure::persistence::{
    is_direct_thread_owned_async, load_subagents_for_session, PersistCommand,
};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use tokio::sync::oneshot;

pub(crate) enum WatcherMessage {
    FsEvent(PathBuf),
    ProcessFile(PathBuf),
    SessionTimeout(String),
    Sweep,
}

pub(crate) struct WatcherRuntime {
    pub(crate) app_state: Arc<SessionRegistry>,
    pub(crate) persist_tx: mpsc::Sender<PersistCommand>,
    pub(crate) tx: mpsc::UnboundedSender<WatcherMessage>,
    pub(crate) processor: RolloutFileProcessor,
    pub(crate) debounce_tasks: HashMap<String, JoinHandle<()>>,
    pub(crate) session_timeouts: HashMap<String, JoinHandle<()>>,
}

struct AppendChatMessageArgs {
    session_id: String,
    message_type: MessageType,
    content: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    is_error: bool,
    images: Vec<orbitdock_protocol::ImageInput>,
}

impl WatcherRuntime {
    pub(crate) async fn sweep_files(&mut self) -> anyhow::Result<()> {
        let candidates = self.processor.sweep_candidates();
        for path in candidates {
            self.process_file(path).await?;
        }
        Ok(())
    }

    pub(crate) fn schedule_file(&mut self, path: PathBuf) {
        let path_string = path.to_string_lossy().to_string();
        if let Some(handle) = self.debounce_tasks.remove(&path_string) {
            handle.abort();
        }

        let tx = self.tx.clone();
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(DEBOUNCE_MS)).await;
            let _ = tx.send(WatcherMessage::ProcessFile(path));
        });

        self.debounce_tasks.insert(path_string, handle);
    }

    pub(crate) async fn process_file(&mut self, path: PathBuf) -> anyhow::Result<()> {
        if !path.exists() {
            return Ok(());
        }

        let path_string = path.to_string_lossy().to_string();
        self.debounce_tasks.remove(&path_string);

        // Guard stale path->session bindings
        if let Some(hinted_session_id) = rollout_session_id_hint(&path) {
            let mapped_session_id = self
                .processor
                .file_states
                .get(&path_string)
                .and_then(|state| state.session_id.clone());
            if let Some(mapped_session_id) = mapped_session_id {
                if mapped_session_id != hinted_session_id {
                    self.processor.reset_session_binding(&path_string);
                    let events = self.processor.ensure_session_meta(&path_string).await?;
                    self.handle_rollout_events(events).await?;
                }
            }
        }

        let metadata = std::fs::metadata(&path)?;
        let size = metadata.len();
        let created_at = metadata.created().ok();
        self.processor
            .ensure_file_state(&path_string, size, created_at);

        // Check if we need a runtime session
        let existing_session_id = self
            .processor
            .file_states
            .get(&path_string)
            .and_then(|state| state.session_id.clone());
        let has_runtime_session = if let Some(session_id) = existing_session_id {
            self.app_state.get_session(&session_id).is_some()
        } else {
            false
        };
        if !has_runtime_session {
            let events = self.processor.ensure_session_meta(&path_string).await?;
            self.handle_rollout_events(events).await?;
        }

        let events = self.processor.process_file(&path).await?;
        self.handle_rollout_events(events).await?;
        Ok(())
    }

    // ── Event dispatch ───────────────────────────────────────────────────

    pub(crate) async fn handle_rollout_events(
        &mut self,
        events: Vec<RolloutEvent>,
    ) -> anyhow::Result<()> {
        for event in events {
            match event {
                RolloutEvent::SessionMeta {
                    session_id,
                    cwd,
                    model_provider,
                    originator,
                    source,
                    started_at,
                    transcript_path,
                    branch,
                } => {
                    self.handle_session_meta_event(
                        session_id,
                        cwd,
                        model_provider,
                        originator,
                        source,
                        started_at,
                        &transcript_path,
                        branch,
                    )
                    .await;
                }
                RolloutEvent::TurnContext {
                    session_id,
                    project_path,
                    model,
                    effort,
                } => {
                    self.handle_turn_context_event(session_id, project_path, model, effort)
                        .await;
                }
                RolloutEvent::WorkStateChange {
                    session_id,
                    work_status,
                    attention_reason,
                    pending_tool_name,
                    pending_tool_input,
                    pending_question,
                    last_tool,
                    last_tool_at,
                } => {
                    self.update_work_state(
                        &session_id,
                        work_status,
                        attention_reason,
                        pending_tool_name,
                        pending_tool_input,
                        pending_question,
                        last_tool,
                        last_tool_at,
                        None,
                    )
                    .await;
                }
                RolloutEvent::ClearPending { session_id } => {
                    self.clear_pending(&session_id).await;
                }
                RolloutEvent::UserMessage {
                    session_id,
                    message,
                } => {
                    self.handle_user_message(&session_id, message).await;
                }
                RolloutEvent::AppendChatMessage {
                    session_id,
                    message_type,
                    content,
                    tool_name,
                    tool_input,
                    is_error,
                    images,
                } => {
                    self.append_chat_message(AppendChatMessageArgs {
                        session_id,
                        message_type,
                        content,
                        tool_name,
                        tool_input,
                        is_error,
                        images,
                    })
                    .await;
                }
                RolloutEvent::ShellCommandBegin {
                    session_id,
                    call_id,
                    command,
                } => {
                    self.append_rollout_shell_message(&session_id, &call_id, command)
                        .await;
                }
                RolloutEvent::ShellCommandEnd {
                    session_id,
                    call_id,
                    output,
                    is_error,
                    duration_ms,
                } => {
                    self.finish_rollout_shell_message(
                        &session_id,
                        &call_id,
                        output,
                        is_error,
                        duration_ms,
                    )
                    .await;
                }
                RolloutEvent::ToolCompleted { session_id, tool } => {
                    self.mark_tool_completed(&session_id, tool).await;
                }
                RolloutEvent::TokenCount {
                    session_id,
                    total_tokens,
                    token_usage,
                } => {
                    self.handle_token_count(&session_id, total_tokens, token_usage)
                        .await;
                }
                RolloutEvent::ThreadNameUpdated { session_id, name } => {
                    self.set_custom_name(&session_id, Some(name)).await;
                }
                RolloutEvent::DiffUpdated { session_id, diff } => {
                    self.update_turn_diff(&session_id, diff).await;
                }
                RolloutEvent::PlanUpdated { session_id, plan } => {
                    self.update_turn_plan(&session_id, plan).await;
                }
                RolloutEvent::SessionEnded { session_id, reason } => {
                    self.end_rollout_session(&session_id, &reason).await;
                }
                RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents,
                } => {
                    self.update_subagents(&session_id, subagents).await;
                }
            }
        }
        Ok(())
    }

    // ── Server orchestration (kept from original) ────────────────────────

    #[allow(clippy::too_many_arguments)]
    async fn handle_session_meta_event(
        &mut self,
        session_id: String,
        cwd: String,
        model_provider: Option<String>,
        originator: String,
        source: SessionSource,
        started_at: String,
        transcript_path: &str,
        branch: Option<String>,
    ) {
        let is_direct = self.app_state.is_managed_codex_thread(&session_id);
        let is_direct_in_db = is_direct_thread_owned_async(&session_id)
            .await
            .unwrap_or(false);
        if is_direct || is_direct_in_db {
            if self.app_state.remove_session(&session_id).is_some() {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: session_id.clone(),
                        reason: "direct_session_thread_claimed".into(),
                    });
            }
            return;
        }

        // Direct Codex sessions emit rollout files with source="mcp".
        if matches!(source, SessionSource::Mcp) {
            if self.app_state.remove_session(&session_id).is_some() {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: session_id.clone(),
                        reason: "direct_session_thread_claimed".into(),
                    });
            }

            let _ = self
                .persist_tx
                .send(PersistCommand::CleanupThreadShadowSession {
                    thread_id: session_id.clone(),
                    reason: "mcp_shadow_session_ignored".into(),
                })
                .await;

            return;
        }

        let (resolved_branch, project_name) = rollout_parser::resolve_git_info(&cwd).await;
        let branch = branch.or(resolved_branch);
        let fallback_name = Path::new(&cwd)
            .file_name()
            .map(|s| s.to_string_lossy().to_string());
        let project_name = project_name.or(fallback_name);

        let exists = self.app_state.get_session(&session_id).is_some();

        if !exists {
            let mut handle = SessionHandle::new(session_id.clone(), Provider::Codex, cwd.clone());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(transcript_path.to_string()));
            handle.set_project_name(project_name.clone());
            handle.set_model(model_provider.clone());
            handle.set_started_at(Some(started_at.clone()));
            handle.set_last_activity_at(Some(current_time_unix_z()));

            let summary = handle.summary();
            self.app_state.add_session(handle);
            self.app_state
                .broadcast_to_list(ServerMessage::SessionCreated {
                    session: SessionListItem::from_summary(&summary),
                });
        } else if let Some(actor) = self.app_state.get_session(&session_id) {
            let snap = actor.snapshot();
            actor
                .send(SessionCommand::SetCodexIntegrationMode {
                    mode: Some(CodexIntegrationMode::Passive),
                })
                .await;
            actor
                .send(SessionCommand::SetTranscriptPath {
                    path: Some(transcript_path.to_string()),
                })
                .await;
            actor
                .send(SessionCommand::SetProjectName {
                    name: project_name.clone(),
                })
                .await;
            actor
                .send(SessionCommand::SetModel {
                    model: model_provider.clone(),
                })
                .await;
            actor
                .send(SessionCommand::SetStatus {
                    status: SessionStatus::Active,
                })
                .await;
            if snap.work_status == WorkStatus::Ended {
                actor
                    .send(SessionCommand::SetWorkStatus {
                        status: WorkStatus::Waiting,
                    })
                    .await;
            }
            actor
                .send(SessionCommand::SetLastActivityAt {
                    ts: Some(current_time_unix_z()),
                })
                .await;

            if let Ok(summary) = actor.summary().await {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionCreated {
                        session: SessionListItem::from_summary(&summary),
                    });
            }
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpsert {
                id: session_id.clone(),
                thread_id: session_id.clone(),
                project_path: cwd,
                project_name,
                branch,
                model: model_provider,
                context_label: Some(originator),
                transcript_path: transcript_path.to_string(),
                started_at,
            })
            .await;

        self.schedule_session_timeout(&session_id);
    }

    async fn handle_turn_context_event(
        &mut self,
        session_id: String,
        project_path: Option<String>,
        model: Option<String>,
        effort: Option<String>,
    ) {
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.clone(),
                project_path: project_path.clone(),
                model: model.clone(),
                status: None,
                work_status: None,
                attention_reason: None,
                pending_tool_name: None,
                pending_tool_input: None,
                pending_question: None,
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: None,
            })
            .await;

        if let Some(ref effort) = effort {
            let _ = self
                .persist_tx
                .send(PersistCommand::EffortUpdate {
                    session_id: session_id.clone(),
                    effort: Some(effort.clone()),
                })
                .await;
        }

        if project_path.is_some() || model.is_some() || effort.is_some() {
            if let Some(actor) = self.app_state.get_session(&session_id) {
                if project_path.is_some() {
                    actor
                        .send(SessionCommand::SetLastActivityAt {
                            ts: Some(current_time_unix_z()),
                        })
                        .await;
                }
                if let Some(model) = model {
                    actor
                        .send(SessionCommand::SetModel { model: Some(model) })
                        .await;
                }
                if let Some(effort) = effort {
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: StateChanges {
                                effort: Some(Some(effort)),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
            }
            self.schedule_session_timeout(&session_id);
        }
    }

    async fn append_chat_message(&mut self, args: AppendChatMessageArgs) {
        let AppendChatMessageArgs {
            session_id,
            message_type,
            content,
            tool_name,
            tool_input,
            is_error,
            images,
        } = args;
        let content = content.trim().to_string();
        if content.is_empty() && images.is_empty() {
            return;
        }

        // Allocate next sequence number from processor's file state
        let next_seq = {
            // Find the file state for this session to get next_message_seq
            let mut seq = 0u64;
            for state in self.processor.file_states.values_mut() {
                if state.session_id.as_deref() == Some(session_id.as_str()) {
                    seq = state.next_message_seq;
                    state.next_message_seq = state.next_message_seq.saturating_add(1);
                    break;
                }
            }
            seq
        };

        let msg_id = format!("rollout-{session_id}-{next_seq}");
        let Some(actor) = self.app_state.get_session(&session_id) else {
            return;
        };
        let message = Message {
            id: msg_id,
            session_id,
            sequence: Some(next_seq),
            message_type,
            content,
            tool_name,
            tool_input,
            tool_output: None,
            is_error,
            is_in_progress: false,
            timestamp: current_time_rfc3339(),
            duration_ms: None,
            images,
        };

        actor
            .send(SessionCommand::AddMessageAndBroadcast {
                message: message.clone(),
            })
            .await;

        let _ = self
            .persist_tx
            .send(PersistCommand::MessageAppend {
                session_id: message.session_id.clone(),
                message,
            })
            .await;
    }

    async fn update_subagents(
        &mut self,
        session_id: &str,
        subagents: Vec<orbitdock_protocol::SubagentInfo>,
    ) {
        if subagents.is_empty() {
            return;
        }

        let fallback_subagents = subagents.clone();

        for info in subagents {
            let _ = self
                .persist_tx
                .send(PersistCommand::UpsertSubagent {
                    session_id: session_id.to_string(),
                    info,
                })
                .await;
        }

        let loaded_subagents = match load_subagents_for_session(session_id).await {
            Ok(loaded) if !loaded.is_empty() => loaded,
            _ => fallback_subagents,
        };

        let Some(actor) = self.app_state.get_session(session_id) else {
            return;
        };

        actor
            .send(SessionCommand::SetSubagents {
                subagents: loaded_subagents,
            })
            .await;
        actor
            .send(SessionCommand::SetLastActivityAt {
                ts: Some(current_time_unix_z()),
            })
            .await;

        if let Ok(state) = actor.retained_state().await {
            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::SessionSnapshot { session: state },
                })
                .await;
        }

        self.schedule_session_timeout(session_id);
    }

    async fn append_rollout_shell_message(
        &mut self,
        session_id: &str,
        call_id: &str,
        command: String,
    ) {
        let message = Message {
            id: format!("rollout-tool-{call_id}"),
            session_id: session_id.to_string(),
            sequence: None,
            message_type: MessageType::Tool,
            content: if command.trim().is_empty() {
                "Shell".to_string()
            } else {
                command
            },
            tool_name: Some("Bash".to_string()),
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: true,
            timestamp: current_time_rfc3339(),
            duration_ms: None,
            images: vec![],
        };

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::AddMessageAndBroadcast {
                    message: message.clone(),
                })
                .await;
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::MessageAppend {
                session_id: session_id.to_string(),
                message,
            })
            .await;
    }

    async fn finish_rollout_shell_message(
        &self,
        session_id: &str,
        call_id: &str,
        output: Option<String>,
        is_error: Option<bool>,
        duration_ms: Option<u64>,
    ) {
        let Some(actor) = self.app_state.get_session(session_id) else {
            return;
        };

        actor
            .send(SessionCommand::ProcessEvent {
                event: crate::domain::sessions::transition::Input::MessageUpdated {
                    message_id: format!("rollout-tool-{call_id}"),
                    content: None,
                    tool_output: output,
                    is_error,
                    is_in_progress: Some(false),
                    duration_ms,
                },
            })
            .await;
    }

    async fn handle_user_message(&mut self, session_id: &str, message: Option<String>) {
        let first_prompt = message.as_deref().and_then(name_from_first_prompt);

        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutPromptIncrement {
                id: session_id.to_string(),
                first_prompt: first_prompt.clone(),
            })
            .await;

        if let Some(ref prompt) = first_prompt {
            if let Some(actor) = self.app_state.get_session(session_id) {
                let changes = StateChanges {
                    first_prompt: Some(Some(prompt.clone())),
                    ..Default::default()
                };
                let _ = actor
                    .send(SessionCommand::ApplyDelta {
                        changes,
                        persist_op: None,
                    })
                    .await;

                if self.app_state.naming_guard().try_claim(session_id) {
                    crate::support::ai_naming::spawn_naming_task(
                        session_id.to_string(),
                        prompt.clone(),
                        actor,
                        self.persist_tx.clone(),
                        self.app_state.list_tx(),
                    );
                }
            }
        }

        self.update_work_state(
            session_id,
            WorkStatus::Working,
            Some("none".to_string()),
            None,
            None,
            Some(None),
            None,
            None,
            None,
        )
        .await;
    }

    async fn handle_token_count(
        &mut self,
        session_id: &str,
        total_tokens: Option<i64>,
        token_usage: Option<orbitdock_protocol::TokenUsage>,
    ) {
        if let Some(total_tokens) = total_tokens {
            let _ = self
                .persist_tx
                .send(PersistCommand::RolloutSessionUpdate {
                    id: session_id.to_string(),
                    project_path: None,
                    model: None,
                    status: None,
                    work_status: None,
                    attention_reason: None,
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                    total_tokens: Some(total_tokens),
                    last_tool: None,
                    last_tool_at: None,
                    custom_name: None,
                })
                .await;
        }

        if let Some(usage) = token_usage {
            if let Some(actor) = self.app_state.get_session(session_id) {
                actor
                    .send(SessionCommand::ProcessEvent {
                        event: crate::domain::sessions::transition::Input::TokensUpdated {
                            usage,
                            snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
                        },
                    })
                    .await;
            } else {
                let _ = self
                    .persist_tx
                    .send(PersistCommand::TokensUpdate {
                        session_id: session_id.to_string(),
                        usage,
                        snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
                    })
                    .await;
            }
        }
    }

    async fn clear_pending(&mut self, session_id: &str) {
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.to_string(),
                project_path: None,
                model: None,
                status: None,
                work_status: None,
                attention_reason: None,
                pending_tool_name: Some(None),
                pending_tool_input: Some(None),
                pending_question: Some(None),
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: None,
            })
            .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::SetPendingAttention {
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                })
                .await;
        }
    }

    async fn mark_tool_completed(&mut self, session_id: &str, tool: Option<String>) {
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutToolIncrement {
                id: session_id.to_string(),
            })
            .await;

        let now = current_time_rfc3339();
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.to_string(),
                project_path: None,
                model: None,
                status: None,
                work_status: None,
                attention_reason: None,
                pending_tool_name: Some(None),
                pending_tool_input: Some(None),
                pending_question: None,
                total_tokens: None,
                last_tool: tool.clone().map(Some),
                last_tool_at: Some(Some(now)),
                custom_name: None,
            })
            .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::SetPendingAttention {
                    pending_tool_name: None,
                    pending_tool_input: None,
                    pending_question: None,
                })
                .await;
        }

        if tool.is_some() {
            self.broadcast_session_delta(
                session_id,
                StateChanges {
                    last_activity_at: Some(current_time_unix_z()),
                    ..Default::default()
                },
            )
            .await;
        }

        self.schedule_session_timeout(session_id);
    }

    async fn set_custom_name(&mut self, session_id: &str, name: Option<String>) {
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.to_string(),
                project_path: None,
                model: None,
                status: None,
                work_status: None,
                attention_reason: None,
                pending_tool_name: None,
                pending_tool_input: None,
                pending_question: None,
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: Some(name.clone()),
            })
            .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            let (tx, rx) = oneshot::channel();
            actor
                .send(SessionCommand::SetCustomNameAndNotify {
                    name,
                    persist_op: None,
                    reply: tx,
                })
                .await;
            if let Ok(summary) = rx.await {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionCreated {
                        session: SessionListItem::from_summary(&summary),
                    });
            }
        }
    }

    async fn update_turn_diff(&mut self, session_id: &str, diff: String) {
        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::domain::sessions::transition::Input::DiffUpdated(diff),
                })
                .await;
        } else {
            let _ = self
                .persist_tx
                .send(PersistCommand::TurnStateUpdate {
                    session_id: session_id.to_string(),
                    diff: Some(diff),
                    plan: None,
                })
                .await;
        }

        self.schedule_session_timeout(session_id);
    }

    async fn update_turn_plan(&mut self, session_id: &str, plan: String) {
        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::domain::sessions::transition::Input::PlanUpdated(plan),
                })
                .await;
        } else {
            let _ = self
                .persist_tx
                .send(PersistCommand::TurnStateUpdate {
                    session_id: session_id.to_string(),
                    diff: None,
                    plan: Some(plan),
                })
                .await;
        }

        self.schedule_session_timeout(session_id);
    }

    async fn end_rollout_session(&mut self, session_id: &str, reason: &str) {
        if let Some(handle) = self.session_timeouts.remove(session_id) {
            handle.abort();
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::SessionEnd {
                id: session_id.to_string(),
                reason: reason.to_string(),
            })
            .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor.send(SessionCommand::EndLocally).await;
        }

        self.app_state
            .broadcast_to_list(ServerMessage::SessionEnded {
                session_id: session_id.to_string(),
                reason: reason.to_string(),
            });
    }

    #[allow(clippy::too_many_arguments)]
    async fn update_work_state(
        &mut self,
        session_id: &str,
        work_status: WorkStatus,
        attention_reason: Option<String>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        status: Option<SessionStatus>,
    ) {
        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::SetPendingAttention {
                    pending_tool_name: pending_tool_name.clone().flatten(),
                    pending_tool_input: pending_tool_input.clone().flatten(),
                    pending_question: pending_question.clone().flatten(),
                })
                .await;
        }

        let status = status.or(Some(SessionStatus::Active));
        let attention_pending_tool_name = pending_tool_name.clone().flatten();
        let attention_pending_tool_input = pending_tool_input.clone().flatten();
        let attention_pending_question = pending_question.clone().flatten();
        let has_attention_payload = pending_tool_name.is_some()
            || pending_tool_input.is_some()
            || pending_question.is_some();
        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.to_string(),
                project_path: None,
                model: None,
                status,
                work_status: Some(work_status),
                attention_reason: attention_reason.map(Some),
                pending_tool_name,
                pending_tool_input,
                pending_question,
                total_tokens: None,
                last_tool,
                last_tool_at,
                custom_name: None,
            })
            .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::SetPendingAttention {
                    pending_tool_name: attention_pending_tool_name,
                    pending_tool_input: attention_pending_tool_input,
                    pending_question: attention_pending_question,
                })
                .await;
        }

        self.broadcast_session_delta(
            session_id,
            StateChanges {
                status: Some(SessionStatus::Active),
                work_status: Some(work_status),
                last_activity_at: Some(current_time_unix_z()),
                ..Default::default()
            },
        )
        .await;

        if let Some(actor) = self.app_state.get_session(session_id) {
            if has_attention_payload {
                if let Ok(state) = actor.retained_state().await {
                    actor
                        .send(SessionCommand::Broadcast {
                            msg: ServerMessage::SessionSnapshot { session: state },
                        })
                        .await;
                }
            }
        }

        self.schedule_session_timeout(session_id);
    }

    async fn broadcast_session_delta(&mut self, session_id: &str, changes: StateChanges) {
        if let Some(actor) = self.app_state.get_session(session_id) {
            let was_ended = actor.snapshot().status == SessionStatus::Ended;

            let mut merged = changes;
            if merged.status.is_none() {
                merged.status = Some(SessionStatus::Active);
            }

            actor
                .send(SessionCommand::ApplyDelta {
                    changes: merged,
                    persist_op: None,
                })
                .await;

            if was_ended {
                let snap = actor.snapshot();
                if snap.status == SessionStatus::Active {
                    info!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.session_reactivated",
                        session_id = %session_id,
                        "Reactivated ended passive session from rollout activity"
                    );
                }
            }

            if let Ok(summary) = actor.summary().await {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionCreated {
                        session: SessionListItem::from_summary(&summary),
                    });
            }
        }
    }

    fn schedule_session_timeout(&mut self, session_id: &str) {
        if let Some(handle) = self.session_timeouts.remove(session_id) {
            handle.abort();
        }

        let tx = self.tx.clone();
        let sid = session_id.to_string();
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(SESSION_TIMEOUT_SECS)).await;
            let _ = tx.send(WatcherMessage::SessionTimeout(sid));
        });

        self.session_timeouts.insert(session_id.to_string(), handle);
    }

    pub(crate) async fn handle_session_timeout(&mut self, session_id: String) {
        self.session_timeouts.remove(&session_id);

        let is_active = self
            .app_state
            .get_session(&session_id)
            .map(|actor| actor.snapshot().status == SessionStatus::Active)
            .unwrap_or(false);

        if !is_active {
            return;
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::SessionEnd {
                id: session_id.clone(),
                reason: "timeout".to_string(),
            })
            .await;

        if let Some(actor) = self.app_state.get_session(&session_id) {
            actor.send(SessionCommand::EndLocally).await;
        }

        self.app_state
            .broadcast_to_list(ServerMessage::SessionEnded {
                session_id,
                reason: "timeout".to_string(),
            });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::infrastructure::persistence::flush_batch_for_test;
    use crate::support::test_support::ensure_server_test_data_dir;
    use orbitdock_connector_codex::rollout_parser::{FileState, PersistedState};
    use rusqlite::{params, Connection};
    use std::collections::HashMap;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::mpsc;
    use tokio::time::timeout;

    fn make_test_runtime(
        app_state: Arc<SessionRegistry>,
        persist_tx: mpsc::Sender<PersistCommand>,
        watcher_tx: mpsc::UnboundedSender<WatcherMessage>,
        state_path: PathBuf,
        file_states: HashMap<String, FileState>,
    ) -> WatcherRuntime {
        let mut processor = RolloutFileProcessor::new(state_path, PersistedState::default());
        processor.file_states = file_states;
        WatcherRuntime {
            app_state,
            persist_tx,
            tx: watcher_tx,
            processor,
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        }
    }

    fn default_file_state(session_id: Option<String>, offset: u64) -> FileState {
        FileState {
            offset,
            tail: String::new(),
            session_id,
            project_path: None,
            model_provider: None,
            ignore_existing: false,
            pending_tool_calls: HashMap::new(),
            next_message_seq: 0,
            saw_user_event: false,
            saw_agent_event: false,
        }
    }

    #[tokio::test]
    async fn mcp_session_meta_is_ignored_for_passive_materialization() {
        ensure_server_test_data_dir();
        let session_id = format!("mcp-direct-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-mcp-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let path = tmp_dir.join("rollout.jsonl");
        std::fs::write(&path, "").expect("create rollout placeholder");
        let path_string = path.to_string_lossy().to_string();

        let (persist_tx, mut persist_rx) = mpsc::channel(16);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();

        let file_states = HashMap::from([(
            path_string.clone(),
            default_file_state(Some(session_id.clone()), 0),
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        // Simulate a SessionMeta event with MCP source
        let events = vec![RolloutEvent::SessionMeta {
            session_id: session_id.clone(),
            cwd: "/tmp/repo".to_string(),
            model_provider: None,
            originator: "codex_cli_rs".to_string(),
            source: SessionSource::Mcp,
            started_at: "2026-02-10T00:00:00Z".to_string(),
            transcript_path: path_string.clone(),
            branch: None,
        }];

        runtime
            .handle_rollout_events(events)
            .await
            .expect("handle events");

        assert!(
            app_state.get_session(&session_id).is_none(),
            "mcp session_meta should not create passive runtime sessions"
        );

        match persist_rx.recv().await.expect("expected cleanup command") {
            PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
                assert_eq!(thread_id, session_id);
                assert_eq!(reason, "mcp_shadow_session_ignored");
            }
            other => panic!("expected CleanupThreadShadowSession, got {:?}", other),
        }
        assert!(
            persist_rx.try_recv().is_err(),
            "should not enqueue passive rollout upserts for mcp source"
        );

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn rollout_subagent_updates_refresh_passive_session_snapshot() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-subagents-{}", std::process::id());
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            std::env::temp_dir().join(format!("orbitdock-subagents-{}.json", session_id)),
            HashMap::new(),
        );

        runtime
            .handle_rollout_events(vec![RolloutEvent::SubagentsUpdated {
                session_id: session_id.clone(),
                subagents: vec![orbitdock_protocol::SubagentInfo {
                    id: "worker-1".to_string(),
                    agent_type: "explorer".to_string(),
                    started_at: "2026-03-11T00:00:00Z".to_string(),
                    ended_at: None,
                    provider: Some(Provider::Codex),
                    label: Some("Scout".to_string()),
                    status: orbitdock_protocol::SubagentStatus::Running,
                    task_summary: Some("Inspect the auth flow".to_string()),
                    result_summary: None,
                    error_summary: None,
                    parent_subagent_id: Some("parent-1".to_string()),
                    model: None,
                    last_activity_at: Some("2026-03-11T00:00:00Z".to_string()),
                }],
            }])
            .await
            .expect("handle rollout subagent event");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.retained_state().await.expect("retained state")
        };

        assert_eq!(snapshot.subagents.len(), 1);
        let subagent = &snapshot.subagents[0];
        assert_eq!(subagent.id, "worker-1");
        assert_eq!(subagent.label.as_deref(), Some("Scout"));
        assert_eq!(subagent.status, orbitdock_protocol::SubagentStatus::Running);
    }

    #[tokio::test]
    async fn rollout_activity_reactivates_ended_passive_session_in_memory() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-reactivate-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");

        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write initial rollout");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_status(SessionStatus::Ended);
            handle.set_work_status(WorkStatus::Ended);
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        let append_line =
            "{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"wake up\"}}\n".to_string();
        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout append")
            .write_all(append_line.as_bytes())
            .expect("append rollout line");

        runtime
            .process_file(PathBuf::from(&rollout_path))
            .await
            .expect("process rollout");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };
        assert_eq!(snapshot.status, SessionStatus::Active);
        assert_eq!(snapshot.work_status, WorkStatus::Working);

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir(&tmp_dir);
    }

    fn find_migrations_dir() -> PathBuf {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        for ancestor in manifest_dir.ancestors() {
            let candidate = ancestor.join("migrations");
            if candidate.is_dir() {
                return candidate;
            }
        }
        panic!(
            "Could not locate migrations directory from {:?}",
            manifest_dir
        );
    }

    fn run_all_migrations(db_path: &Path) {
        let conn = Connection::open(db_path).expect("open db");
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
        )
        .expect("set pragmas");

        let migrations_dir = find_migrations_dir();
        let mut files: Vec<PathBuf> = std::fs::read_dir(&migrations_dir)
            .expect("read migrations")
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("sql"))
            .collect();
        files.sort();

        for file in files {
            let sql = std::fs::read_to_string(&file).expect("read migration");
            conn.execute_batch(&sql).unwrap_or_else(|err| {
                panic!("migration failed for {}: {}", file.display(), err);
            });
        }
    }

    #[tokio::test]
    async fn rollout_activity_reactivates_closed_passive_session_in_memory_and_db() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-reactivate-db-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-db-{}", session_id));
        std::fs::create_dir_all(tmp_dir.join(".orbitdock")).expect("create .orbitdock dir");
        let db_path = tmp_dir.join(".orbitdock/orbitdock.db");
        run_all_migrations(&db_path);

        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write initial rollout");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        flush_batch_for_test(
            &db_path,
            vec![
                PersistCommand::RolloutSessionUpsert {
                    id: session_id.clone(),
                    thread_id: session_id.clone(),
                    project_path: "/tmp/repo".to_string(),
                    project_name: Some("repo".to_string()),
                    branch: Some("main".to_string()),
                    model: Some("gpt-5".to_string()),
                    context_label: Some("codex_cli_rs".to_string()),
                    transcript_path: rollout_path.to_string_lossy().to_string(),
                    started_at: "2026-02-10T00:00:00Z".to_string(),
                },
                PersistCommand::SessionEnd {
                    id: session_id.clone(),
                    reason: "user_requested".to_string(),
                },
            ],
        )
        .expect("seed ended passive session");

        let (persist_tx, mut persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            handle.set_status(SessionStatus::Ended);
            handle.set_work_status(WorkStatus::Ended);
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        let append_line =
            "{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"wake up\"}}\n".to_string();
        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout append")
            .write_all(append_line.as_bytes())
            .expect("append rollout line");

        runtime
            .process_file(PathBuf::from(&rollout_path))
            .await
            .expect("process rollout");

        let mut persist_batch = Vec::new();
        while let Ok(cmd) = persist_rx.try_recv() {
            persist_batch.push(cmd);
        }
        flush_batch_for_test(&db_path, persist_batch).expect("flush watcher updates");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };
        assert_eq!(snapshot.status, SessionStatus::Active);
        assert_eq!(snapshot.work_status, WorkStatus::Working);

        let conn = Connection::open(&db_path).expect("open db");
        let (status, work_status, ended_at, end_reason): (
            String,
            String,
            Option<String>,
            Option<String>,
        ) = conn
            .query_row(
                "SELECT status, work_status, ended_at, end_reason FROM sessions WHERE id = ?1",
                params![session_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("query session");
        assert_eq!(status, "active");
        assert_eq!(work_status, "working");
        assert!(ended_at.is_none(), "ended_at should be cleared");
        assert!(end_reason.is_none(), "end_reason should be cleared");

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_file(&db_path);
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn close_then_append_rollout_event_reactivates_via_watcher_event_queue() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-close-reopen-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-close-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write rollout seed");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            app_state.add_session(handle);
        }

        {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.send(SessionCommand::EndLocally).await;
            tokio::task::yield_now().await;
            tokio::task::yield_now().await;
        }
        let ended_snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };
        assert_eq!(ended_snapshot.status, SessionStatus::Ended);

        let (watcher_tx, mut watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout")
            .write_all(
                b"{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"wake\"}}\n",
            )
            .expect("append user message");

        runtime.schedule_file(PathBuf::from(&rollout_path));
        let msg = timeout(Duration::from_secs(2), watcher_rx.recv())
            .await
            .expect("debounce should emit process_file")
            .expect("watcher channel open");
        if let WatcherMessage::ProcessFile(path) = msg {
            runtime
                .process_file(path)
                .await
                .expect("process appended rollout event");
        } else {
            panic!("unexpected watcher message");
        }

        let reactivated_snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };
        assert_eq!(reactivated_snapshot.status, SessionStatus::Active);
        assert_eq!(reactivated_snapshot.work_status, WorkStatus::Working);

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn catchup_sweep_processes_appended_lines_without_fs_event() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-sweep-reactivate-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-sweep-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write rollout seed");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            handle.set_status(SessionStatus::Ended);
            handle.set_work_status(WorkStatus::Ended);
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout")
            .write_all(
                b"{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"wake\"}}\n",
            )
            .expect("append user_message");

        runtime.sweep_files().await.expect("run catchup sweep");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };
        assert_eq!(snapshot.status, SessionStatus::Active);
        assert_eq!(snapshot.work_status, WorkStatus::Working);

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn response_item_message_line_appends_passive_chat_message() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-msg-append-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-msg-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write rollout seed");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout")
            .write_all(
                b"{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello from passive\"}]}}\n",
            )
            .expect("append response_item user message");

        runtime
            .process_file(PathBuf::from(&rollout_path))
            .await
            .expect("process rollout");

        let state = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.retained_state().await.expect("get state")
        };
        let has_user_message = state.messages.iter().any(|msg| {
            msg.message_type == MessageType::User && msg.content.contains("hello from passive")
        });
        assert!(
            has_user_message,
            "response_item user message should be appended to passive session"
        );

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn passive_request_permissions_event_updates_attention_state_and_timeline() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-permissions-{}", std::process::id());
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-rollout-permissions-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                session_id
            ),
        )
        .expect("write rollout seed");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let file_states = HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            FileState {
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("openai".to_string()),
                ..default_file_state(Some(session_id.clone()), initial_size)
            },
        )]);
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            tmp_dir.join("state.json"),
            file_states,
        );

        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout")
            .write_all(
                b"{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"request_permissions\",\"call_id\":\"call-1\",\"turn_id\":\"turn-1\",\"reason\":\"Need network access for package metadata\",\"permissions\":{\"network\":null,\"file_system\":null,\"macos\":null}}}\n",
            )
            .expect("append request_permissions event");

        runtime
            .process_file(PathBuf::from(&rollout_path))
            .await
            .expect("process rollout");

        let state = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.retained_state().await.expect("get state")
        };

        assert_eq!(state.work_status, WorkStatus::Permission);
        assert_eq!(
            state.pending_tool_name.as_deref(),
            Some("RequestPermissions")
        );
        assert_eq!(
            state.pending_question.as_deref(),
            Some("Need network access for package metadata")
        );

        let has_permissions_message = state.messages.iter().any(|msg| {
            msg.message_type == MessageType::Tool
                && msg.tool_name.as_deref() == Some("request_permissions")
                && msg
                    .content
                    .contains("Need network access for package metadata")
        });
        assert!(
            has_permissions_message,
            "passive request_permissions should append a visible tool message"
        );

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn rollout_turn_state_updates_refresh_passive_session_state() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-turn-state-{}", std::process::id());
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            std::env::temp_dir().join(format!("orbitdock-turn-state-{}.json", session_id)),
            HashMap::new(),
        );

        runtime
            .handle_rollout_events(vec![
                RolloutEvent::DiffUpdated {
                    session_id: session_id.clone(),
                    diff: "diff --git a/file b/file".to_string(),
                },
                RolloutEvent::PlanUpdated {
                    session_id: session_id.clone(),
                    plan:
                        "{\"plan\":[{\"step\":\"Ship passive parity\",\"status\":\"in_progress\"}]}"
                            .to_string(),
                },
            ])
            .await
            .expect("handle rollout turn-state updates");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.retained_state().await.expect("retained state")
        };

        assert_eq!(
            snapshot.current_diff.as_deref(),
            Some("diff --git a/file b/file")
        );
        assert!(snapshot
            .current_plan
            .as_deref()
            .expect("plan persisted")
            .contains("Ship passive parity"));
    }

    #[tokio::test]
    async fn rollout_shutdown_ends_passive_session_immediately() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-shutdown-{}", std::process::id());
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(
            app_state.clone(),
            persist_tx,
            watcher_tx,
            std::env::temp_dir().join(format!("orbitdock-shutdown-{}.json", session_id)),
            HashMap::new(),
        );

        runtime
            .handle_rollout_events(vec![RolloutEvent::SessionEnded {
                session_id: session_id.clone(),
                reason: "shutdown".to_string(),
            }])
            .await
            .expect("handle rollout shutdown");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.retained_state().await.expect("retained state")
        };

        assert_eq!(snapshot.status, SessionStatus::Ended);
        assert_eq!(snapshot.work_status, WorkStatus::Ended);
    }
}
