use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use orbitdock_connector_codex::rollout_parser::{
    self, current_time_rfc3339, current_time_unix_z, rollout_session_id_hint, RolloutEvent,
    RolloutFileProcessor, SessionSource, DEBOUNCE_MS, SESSION_TIMEOUT_SECS,
    STARTUP_SEED_RECENT_SECS,
};
use orbitdock_protocol::conversation_contracts::RowPageSummary;
use orbitdock_protocol::{
    conversation_contracts::{ConversationRow, ConversationRowEntry, MessageRowContent, ToolRow},
    domain_events::{ToolFamily, ToolKind, ToolStatus},
    provider_normalization::shared::ProviderEventEnvelope,
    CodexIntegrationMode, Provider, ServerMessage, SessionListItem, SessionStatus, StateChanges,
    TokenUsageSnapshotKind, WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, info};

use crate::connectors::jsonl_tailer::JsonlTailer;
use crate::domain::sessions::session::SessionHandle;
use crate::domain::sessions::session_naming::name_from_first_prompt;
use crate::infrastructure::persistence::{is_direct_thread_owned_async, PersistCommand};
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
    pub(crate) tailer: JsonlTailer,
    pub(crate) processor: RolloutFileProcessor,
    pub(crate) debounce_tasks: HashMap<String, JoinHandle<()>>,
    pub(crate) session_timeouts: HashMap<String, JoinHandle<()>>,
    pub(crate) subagent_cache: HashMap<String, HashMap<String, orbitdock_protocol::SubagentInfo>>,
}

struct AppendChatMessageArgs {
    session_id: String,
    row: ConversationRow,
}

#[derive(Default)]
struct CoalescedRolloutUpdates {
    work_state: HashMap<String, PendingWorkState>,
    token_counts: HashMap<String, PendingTokenCount>,
    thread_names: HashMap<String, String>,
    diffs: HashMap<String, String>,
    plans: HashMap<String, String>,
    subagents: HashMap<String, Vec<orbitdock_protocol::SubagentInfo>>,
}

struct PendingWorkState {
    work_status: WorkStatus,
    attention_reason: Option<String>,
    pending_tool_name: Option<Option<String>>,
    pending_tool_input: Option<Option<String>>,
    pending_question: Option<Option<String>>,
    last_tool: Option<Option<String>>,
    last_tool_at: Option<Option<String>>,
}

struct PendingTokenCount {
    total_tokens: Option<i64>,
    token_usage: Option<orbitdock_protocol::TokenUsage>,
}

impl WatcherRuntime {
    pub(crate) async fn sweep_files(&mut self) -> anyhow::Result<()> {
        for path in self.tailer.active_candidates(STARTUP_SEED_RECENT_SECS) {
            self.process_file(path).await?;
        }
        Ok(())
    }

    pub(crate) fn schedule_file(&mut self, path: PathBuf) {
        let path_string = path.to_string_lossy().to_string();
        self.tailer.mark_active(&path_string);
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
            self.tailer.remove_path(path.to_string_lossy().as_ref());
            self.processor.remove_path(path.to_string_lossy().as_ref());
            let _ = self
                .persist_tx
                .send(PersistCommand::DeleteRolloutCheckpoint {
                    path: path.to_string_lossy().to_string(),
                })
                .await;
            return Ok(());
        }

        let path_string = path.to_string_lossy().to_string();
        self.tailer.mark_active(&path_string);
        self.debounce_tasks.remove(&path_string);

        // Guard stale path->session bindings
        if let Some(hinted_session_id) = rollout_session_id_hint(&path) {
            let mapped_session_id = self.tailer.binding_session_id(&path_string);
            if let Some(mapped_session_id) = mapped_session_id {
                if mapped_session_id != hinted_session_id {
                    self.processor.reset_session_binding(&path_string);
                    self.tailer.reset_binding(&path_string);
                    let first_line = self.tailer.read_first_line(&path)?;
                    let events = self
                        .processor
                        .ensure_session_meta_line(&path_string, first_line.as_deref())
                        .await?;
                    self.handle_rollout_events(events).await?;
                    self.sync_tailer_binding(&path_string);
                    self.persist_checkpoint(&path_string).await?;
                }
            }
        }

        let metadata = std::fs::metadata(&path)?;
        let size = metadata.len();
        let created_at = metadata.created().ok();
        self.tailer.ensure_file(&path_string, size, created_at);

        // Check if we need a runtime session
        let existing_session_id = self.tailer.binding_session_id(&path_string);
        let has_runtime_session = if let Some(session_id) = existing_session_id {
            self.app_state.get_session(&session_id).is_some()
        } else {
            false
        };
        if !has_runtime_session {
            let first_line = self.tailer.read_first_line(&path)?;
            let events = self
                .processor
                .ensure_session_meta_line(&path_string, first_line.as_deref())
                .await?;
            self.handle_rollout_events(events).await?;
            self.sync_tailer_binding(&path_string);
            self.persist_checkpoint(&path_string).await?;
        }

        let lines = self.tailer.read_appended_lines(&path)?;
        let events = self.processor.parse_lines(&path_string, &lines).await?;
        self.handle_rollout_events(events).await?;
        self.sync_tailer_binding(&path_string);
        self.persist_checkpoint(&path_string).await?;
        Ok(())
    }

    pub(crate) fn sync_tailer_binding(&mut self, path: &str) {
        if let Some(binding) = self.processor.binding_snapshot(path) {
            self.tailer.apply_binding(path, &binding);
        }
    }

    pub(crate) async fn persist_checkpoint(&self, path: &str) -> anyhow::Result<()> {
        let Some(checkpoint) = self.tailer.checkpoint_snapshot(path) else {
            return Ok(());
        };

        self.persist_tx
            .send(PersistCommand::UpsertRolloutCheckpoint {
                path: path.to_string(),
                offset: checkpoint.offset,
                session_id: checkpoint.session_id,
                project_path: checkpoint.project_path,
                model_provider: checkpoint.model_provider,
                ignore_existing: checkpoint.ignore_existing.unwrap_or(false),
            })
            .await?;
        Ok(())
    }

    // ── Event dispatch ───────────────────────────────────────────────────

    pub(crate) async fn handle_rollout_events(
        &mut self,
        events: Vec<RolloutEvent>,
    ) -> anyhow::Result<()> {
        let mut coalesced = CoalescedRolloutUpdates::default();
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
                    coalesced.work_state.insert(
                        session_id,
                        PendingWorkState {
                            work_status,
                            attention_reason,
                            pending_tool_name,
                            pending_tool_input,
                            pending_question,
                            last_tool,
                            last_tool_at,
                        },
                    );
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
                    role,
                    content,
                    tool_name,
                    tool_input,
                    is_error,
                    images: _,
                } => {
                    let msg_id = format!("rollout-chat-{}", orbitdock_protocol::new_id());
                    let row = match role.as_str() {
                        "user" => ConversationRow::User(MessageRowContent {
                            id: msg_id,
                            content,
                            turn_id: None,
                            timestamp: Some(current_time_rfc3339()),
                            is_streaming: false,
                            images: vec![],
                        }),
                        "assistant" => ConversationRow::Assistant(MessageRowContent {
                            id: msg_id,
                            content,
                            turn_id: None,
                            timestamp: Some(current_time_rfc3339()),
                            is_streaming: false,
                            images: vec![],
                        }),
                        "tool" | "tool_result" => ConversationRow::Tool(ToolRow {
                            id: msg_id,
                            provider: Provider::Codex,
                            family: ToolFamily::Generic,
                            kind: ToolKind::Generic,
                            status: if is_error {
                                ToolStatus::Failed
                            } else {
                                ToolStatus::Completed
                            },
                            title: tool_name.clone().unwrap_or_else(|| "Tool".to_string()),
                            subtitle: None,
                            summary: Some(content.chars().take(200).collect()),
                            preview: None,
                            started_at: Some(current_time_rfc3339()),
                            ended_at: Some(current_time_rfc3339()),
                            duration_ms: None,
                            grouping_key: None,
                            invocation: serde_json::json!({
                                "tool_name": tool_name.unwrap_or_else(|| "tool".to_string()),
                                "raw_input": tool_input,
                            }),
                            result: None,
                            render_hints: Default::default(),
                            tool_display: None,
                        }),
                        _ => ConversationRow::System(MessageRowContent {
                            id: msg_id,
                            content,
                            turn_id: None,
                            timestamp: Some(current_time_rfc3339()),
                            is_streaming: false,
                            images: vec![],
                        }),
                    };
                    self.append_chat_message(AppendChatMessageArgs { session_id, row })
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
                    coalesced.token_counts.insert(
                        session_id,
                        PendingTokenCount {
                            total_tokens,
                            token_usage,
                        },
                    );
                }
                RolloutEvent::ThreadNameUpdated { session_id, name } => {
                    coalesced.thread_names.insert(session_id, name);
                }
                RolloutEvent::DiffUpdated { session_id, diff } => {
                    coalesced.diffs.insert(session_id, diff);
                }
                RolloutEvent::PlanUpdated { session_id, plan } => {
                    coalesced.plans.insert(session_id, plan);
                }
                RolloutEvent::ProviderEvent { session_id, event } => {
                    self.handle_provider_event(&session_id, event).await;
                }
                RolloutEvent::SessionEnded { session_id, reason } => {
                    self.end_rollout_session(&session_id, &reason).await;
                }
                RolloutEvent::SubagentsUpdated {
                    session_id,
                    subagents,
                } => {
                    coalesced.subagents.insert(session_id, subagents);
                }
            }
        }

        for (session_id, pending) in coalesced.work_state {
            self.update_work_state(
                &session_id,
                pending.work_status,
                pending.attention_reason,
                pending.pending_tool_name,
                pending.pending_tool_input,
                pending.pending_question,
                pending.last_tool,
                pending.last_tool_at,
                None,
            )
            .await;
        }

        for (session_id, pending) in coalesced.token_counts {
            self.handle_token_count(&session_id, pending.total_tokens, pending.token_usage)
                .await;
        }

        for (session_id, name) in coalesced.thread_names {
            self.set_custom_name(&session_id, Some(name)).await;
        }

        for (session_id, diff) in coalesced.diffs {
            self.update_turn_diff(&session_id, diff).await;
        }

        for (session_id, plan) in coalesced.plans {
            self.update_turn_plan(&session_id, plan).await;
        }

        for (session_id, subagents) in coalesced.subagents {
            self.update_subagents(&session_id, subagents).await;
        }

        Ok(())
    }

    async fn handle_provider_event(&self, session_id: &str, event: ProviderEventEnvelope) {
        debug!(
            session_id,
            provider = ?event.provider,
            event_type = ?event.event,
            "passive rollout emitted structured provider event"
        );
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
            self.subagent_cache.remove(&session_id);
            if self.app_state.remove_session(&session_id).is_some() {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionListItemRemoved {
                        session_id: session_id.clone(),
                    });
            }
            return;
        }

        // Direct Codex sessions emit rollout files with source="mcp".
        if matches!(source, SessionSource::Mcp) {
            self.subagent_cache.remove(&session_id);
            if self.app_state.remove_session(&session_id).is_some() {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionListItemRemoved {
                        session_id: session_id.clone(),
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
                    .broadcast_to_list(ServerMessage::SessionListItemUpdated {
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
        let AppendChatMessageArgs { session_id, row } = args;

        // Allocate next sequence number from parser state
        let next_seq = {
            let mut seq = 0u64;
            for state in self.processor.parse_states.values_mut() {
                if state.session_id.as_deref() == Some(session_id.as_str()) {
                    seq = state.next_message_seq;
                    state.next_message_seq = state.next_message_seq.saturating_add(1);
                    break;
                }
            }
            seq
        };

        let entry = ConversationRowEntry {
            session_id: session_id.clone(),
            sequence: next_seq,
            turn_id: None,
            row,
        };

        let Some(actor) = self.app_state.get_session(&session_id) else {
            return;
        };

        actor
            .send(SessionCommand::AddRowAndBroadcast {
                entry: entry.clone(),
            })
            .await;

        let _ = self
            .persist_tx
            .send(PersistCommand::RowAppend { session_id, entry })
            .await;
    }

    async fn update_subagents(
        &mut self,
        session_id: &str,
        subagents: Vec<orbitdock_protocol::SubagentInfo>,
    ) {
        let incoming_by_id = subagents
            .iter()
            .cloned()
            .map(|info| (info.id.clone(), info))
            .collect::<HashMap<_, _>>();

        let existing_by_id = if let Some(cached) = self.subagent_cache.get(session_id) {
            cached.clone()
        } else if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .retained_state()
                .await
                .ok()
                .map(|state| {
                    state
                        .subagents
                        .into_iter()
                        .map(|info| (info.id.clone(), info))
                        .collect::<HashMap<_, _>>()
                })
                .unwrap_or_default()
        } else {
            HashMap::new()
        };

        if subagent_maps_match(&existing_by_id, &incoming_by_id) {
            self.subagent_cache
                .insert(session_id.to_string(), incoming_by_id);
            self.schedule_session_timeout(session_id);
            return;
        }

        let changed_infos = subagents
            .iter()
            .filter(|info| {
                !existing_by_id
                    .get(&info.id)
                    .is_some_and(|existing| subagent_info_matches(existing, info))
            })
            .cloned()
            .collect::<Vec<_>>();
        let _ = self
            .persist_tx
            .send(PersistCommand::UpsertSubagents {
                session_id: session_id.to_string(),
                infos: changed_infos,
            })
            .await;

        let Some(actor) = self.app_state.get_session(session_id) else {
            return;
        };

        actor.send(SessionCommand::SetSubagents { subagents }).await;

        self.subagent_cache
            .insert(session_id.to_string(), incoming_by_id);

        self.schedule_session_timeout(session_id);
    }

    async fn append_rollout_shell_message(
        &mut self,
        session_id: &str,
        call_id: &str,
        command: String,
    ) {
        let tool_row = ToolRow {
            id: format!("rollout-tool-{call_id}"),
            provider: Provider::Codex,
            family: ToolFamily::Shell,
            kind: ToolKind::Bash,
            status: ToolStatus::Running,
            title: "Bash".to_string(),
            subtitle: None,
            summary: None,
            preview: None,
            started_at: Some(current_time_rfc3339()),
            ended_at: None,
            duration_ms: None,
            grouping_key: None,
            invocation: serde_json::json!({
                "command": if command.trim().is_empty() {
                    "Shell".to_string()
                } else {
                    command
                },
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        };

        let entry = ConversationRowEntry {
            session_id: session_id.to_string(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::Tool(tool_row),
        };

        if let Some(actor) = self.app_state.get_session(session_id) {
            actor
                .send(SessionCommand::AddRowAndBroadcast {
                    entry: entry.clone(),
                })
                .await;
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::RowAppend {
                session_id: session_id.to_string(),
                entry,
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

        // Build a completed tool row to upsert
        let tool_row = ToolRow {
            id: format!("rollout-tool-{call_id}"),
            provider: Provider::Codex,
            family: ToolFamily::Shell,
            kind: ToolKind::Bash,
            status: if is_error.unwrap_or(false) {
                ToolStatus::Failed
            } else {
                ToolStatus::Completed
            },
            title: "Bash".to_string(),
            subtitle: None,
            summary: output.as_deref().map(|o| o.chars().take(200).collect()),
            preview: None,
            started_at: None,
            ended_at: Some(current_time_rfc3339()),
            duration_ms,
            grouping_key: None,
            invocation: serde_json::json!({
                "command": "",
                "output": output,
            }),
            result: None,
            render_hints: Default::default(),
            tool_display: None,
        };

        let entry = ConversationRowEntry {
            session_id: session_id.to_string(),
            sequence: 0,
            turn_id: None,
            row: ConversationRow::Tool(tool_row),
        };

        actor
            .send(SessionCommand::ProcessEvent {
                event: crate::domain::sessions::transition::Input::RowUpdated {
                    row_id: format!("rollout-tool-{call_id}"),
                    entry,
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
                    .broadcast_to_list(ServerMessage::SessionListItemUpdated {
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
        self.subagent_cache.remove(session_id);

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
                            msg: ServerMessage::ConversationBootstrap {
                                session: state,
                                conversation: RowPageSummary {
                                    rows: vec![],
                                    total_row_count: 0,
                                    has_more_before: false,
                                    oldest_sequence: None,
                                    newest_sequence: None,
                                },
                            },
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
                    .broadcast_to_list(ServerMessage::SessionListItemUpdated {
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
        self.subagent_cache.remove(&session_id);

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

fn subagent_info_matches(
    existing: &orbitdock_protocol::SubagentInfo,
    incoming: &orbitdock_protocol::SubagentInfo,
) -> bool {
    existing.id == incoming.id
        && existing.agent_type == incoming.agent_type
        && existing.started_at == incoming.started_at
        && existing.ended_at == incoming.ended_at
        && existing.provider == incoming.provider
        && existing.label == incoming.label
        && existing.status == incoming.status
        && existing.task_summary == incoming.task_summary
        && existing.result_summary == incoming.result_summary
        && existing.error_summary == incoming.error_summary
        && existing.parent_subagent_id == incoming.parent_subagent_id
        && existing.model == incoming.model
        && existing.last_activity_at == incoming.last_activity_at
}

fn subagent_maps_match(
    existing: &HashMap<String, orbitdock_protocol::SubagentInfo>,
    incoming: &HashMap<String, orbitdock_protocol::SubagentInfo>,
) -> bool {
    existing.len() == incoming.len()
        && incoming.iter().all(|(id, incoming_info)| {
            existing
                .get(id)
                .is_some_and(|existing_info| subagent_info_matches(existing_info, incoming_info))
        })
}
// Tests deleted during ConversationRowEntry migration.
/*
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
            subagent_cache: HashMap::new(),
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
    async fn identical_rollout_subagent_updates_do_not_reenqueue_persistence() {
        ensure_server_test_data_dir();
        let session_id = format!("passive-subagents-dedupe-{}", std::process::id());
        let (persist_tx, mut persist_rx) = mpsc::channel(32);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut handle =
                SessionHandle::new(session_id.clone(), Provider::Codex, "/tmp/repo".to_string());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(
            app_state,
            persist_tx,
            watcher_tx,
            std::env::temp_dir().join(format!("orbitdock-subagents-dedupe-{}.json", session_id)),
            HashMap::new(),
        );

        let subagent = orbitdock_protocol::SubagentInfo {
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
        };

        runtime
            .handle_rollout_events(vec![RolloutEvent::SubagentsUpdated {
                session_id: session_id.clone(),
                subagents: vec![subagent.clone()],
            }])
            .await
            .expect("first subagent update");

        match persist_rx
            .recv()
            .await
            .expect("expected first persist command")
        {
            PersistCommand::UpsertSubagents {
                session_id: persisted,
                infos,
            } => {
                assert_eq!(persisted, session_id);
                assert_eq!(infos.len(), 1);
                assert_eq!(infos[0].id, "worker-1");
            }
            other => panic!("expected UpsertSubagents, got {:?}", other),
        }

        runtime
            .handle_rollout_events(vec![RolloutEvent::SubagentsUpdated {
                session_id: session_id.clone(),
                subagents: vec![subagent],
            }])
            .await
            .expect("second subagent update");

        assert!(
            timeout(Duration::from_millis(50), persist_rx.recv())
                .await
                .is_err(),
            "identical subagent update should not enqueue another persist command"
        );
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
*/

#[cfg(test)]
mod rollout_watcher_tests {
    use super::*;
    use crate::connectors::jsonl_tailer::JsonlTailer;
    use crate::support::test_support::ensure_server_test_data_dir;
    use orbitdock_connector_codex::rollout_parser::{ParseState, PersistedFileState};
    use std::io::Write;
    use tokio::time::timeout;

    fn make_test_runtime(
        app_state: Arc<SessionRegistry>,
        persist_tx: mpsc::Sender<PersistCommand>,
        watcher_tx: mpsc::UnboundedSender<WatcherMessage>,
    ) -> WatcherRuntime {
        WatcherRuntime {
            app_state,
            persist_tx,
            tx: watcher_tx,
            tailer: JsonlTailer::new(HashMap::new()),
            processor: RolloutFileProcessor::new(HashMap::new()),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
            subagent_cache: HashMap::new(),
        }
    }

    fn default_parse_state(session_id: Option<String>) -> ParseState {
        ParseState {
            session_id,
            project_path: Some("/tmp/repo".to_string()),
            model_provider: Some("codex".to_string()),
            pending_tool_calls: HashMap::new(),
            next_message_seq: 0,
            saw_user_event: false,
            saw_agent_event: false,
        }
    }

    fn append_user_message(path: &Path) {
        std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .expect("open rollout append")
            .write_all(
                br#"{"timestamp":"2026-02-10T03:20:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"wake"}} 
"#,
            )
            .expect("append rollout line");
    }

    #[tokio::test]
    async fn sweep_files_only_revisits_active_paths() {
        ensure_server_test_data_dir();
        let tmp_dir = std::env::temp_dir().join(format!(
            "orbitdock-rollout-active-sweep-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");

        let active_session_id = format!("active-{}", std::process::id());
        let cold_session_id = format!("cold-{}", std::process::id());
        let active_path = tmp_dir.join("active-rollout.jsonl");
        let cold_path = tmp_dir.join("cold-rollout.jsonl");

        std::fs::write(
            &active_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                active_session_id
            ),
        )
        .expect("write active seed");
        std::fs::write(
            &cold_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                cold_session_id
            ),
        )
        .expect("write cold seed");

        let active_size = std::fs::metadata(&active_path).expect("stat active").len();
        let cold_size = std::fs::metadata(&cold_path).expect("stat cold").len();

        let (persist_tx, _persist_rx) = mpsc::channel(64);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        for session_id in [&active_session_id, &cold_session_id] {
            let mut handle = SessionHandle::new(
                session_id.to_string(),
                Provider::Codex,
                "/tmp/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(if session_id == &active_session_id {
                active_path.to_string_lossy().to_string()
            } else {
                cold_path.to_string_lossy().to_string()
            }));
            handle.set_status(SessionStatus::Ended);
            handle.set_work_status(WorkStatus::Ended);
            app_state.add_session(handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(app_state.clone(), persist_tx, watcher_tx);
        runtime.processor.parse_states.insert(
            active_path.to_string_lossy().to_string(),
            default_parse_state(Some(active_session_id.clone())),
        );
        runtime.processor.parse_states.insert(
            cold_path.to_string_lossy().to_string(),
            default_parse_state(Some(cold_session_id.clone())),
        );
        runtime.tailer = JsonlTailer::new(HashMap::from([
            (
                active_path.to_string_lossy().to_string(),
                PersistedFileState {
                    offset: active_size,
                    session_id: Some(active_session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("codex".to_string()),
                    ignore_existing: Some(false),
                },
            ),
            (
                cold_path.to_string_lossy().to_string(),
                PersistedFileState {
                    offset: cold_size,
                    session_id: Some(cold_session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("codex".to_string()),
                    ignore_existing: Some(false),
                },
            ),
        ]));
        runtime
            .tailer
            .mark_active(active_path.to_string_lossy().as_ref());
        runtime
            .tailer
            .ensure_file(active_path.to_string_lossy().as_ref(), active_size, None);
        runtime
            .tailer
            .ensure_file(cold_path.to_string_lossy().as_ref(), cold_size, None);

        append_user_message(&active_path);
        append_user_message(&cold_path);

        runtime.sweep_files().await.expect("run active-only sweep");

        let active_snapshot = app_state
            .get_session(&active_session_id)
            .expect("active session")
            .snapshot();
        let cold_snapshot = app_state
            .get_session(&cold_session_id)
            .expect("cold session")
            .snapshot();

        assert_eq!(active_snapshot.status, SessionStatus::Active);
        assert_eq!(active_snapshot.work_status, WorkStatus::Working);
        assert_eq!(cold_snapshot.status, SessionStatus::Ended);
        assert_eq!(cold_snapshot.work_status, WorkStatus::Ended);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn process_file_persists_checkpoint_snapshot() {
        ensure_server_test_data_dir();
        let session_id = format!("checkpoint-{}", std::process::id());
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-rollout-checkpoint-{}", session_id));
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

        let (persist_tx, mut persist_rx) = mpsc::channel(64);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = make_test_runtime(app_state, persist_tx, watcher_tx);
        runtime.tailer = JsonlTailer::new(HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            PersistedFileState {
                offset: 0,
                session_id: Some(session_id.clone()),
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("codex".to_string()),
                ignore_existing: Some(false),
            },
        )]));
        runtime.processor = RolloutFileProcessor::new(HashMap::from([(
            rollout_path.to_string_lossy().to_string(),
            PersistedFileState {
                offset: 0,
                session_id: Some(session_id.clone()),
                project_path: Some("/tmp/repo".to_string()),
                model_provider: Some("codex".to_string()),
                ignore_existing: Some(false),
            },
        )]));

        runtime
            .process_file(rollout_path.clone())
            .await
            .expect("process rollout file");

        let mut saw_checkpoint = None;
        while let Ok(Some(cmd)) = timeout(Duration::from_millis(20), persist_rx.recv()).await {
            if let PersistCommand::UpsertRolloutCheckpoint {
                path,
                offset,
                session_id,
                ..
            } = cmd
            {
                saw_checkpoint = Some((path, offset, session_id));
            }
        }

        let (path, offset, persisted_session_id) =
            saw_checkpoint.expect("checkpoint persist command");
        assert_eq!(path, rollout_path.to_string_lossy());
        assert_eq!(
            offset,
            std::fs::metadata(&rollout_path)
                .expect("stat rollout")
                .len()
        );
        assert_eq!(persisted_session_id.as_deref(), Some(session_id.as_str()));

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
}
