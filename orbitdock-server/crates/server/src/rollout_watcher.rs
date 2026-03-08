#![allow(clippy::items_after_test_module)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use orbitdock_connector_codex::rollout_parser::{
    self, collect_jsonl_files, current_time_rfc3339, current_time_unix_z, is_jsonl_path,
    is_recent_file, load_persisted_state, matches_supported_event_kind, rollout_session_id_hint,
    RolloutEvent, RolloutFileProcessor, SessionSource, CATCHUP_SWEEP_SECS, DEBOUNCE_MS,
    SESSION_TIMEOUT_SECS, STARTUP_SEED_RECENT_SECS,
};
use orbitdock_protocol::{
    CodexIntegrationMode, Message, MessageType, Provider, ServerMessage, SessionStatus,
    StateChanges, TokenUsageSnapshotKind, WorkStatus,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{info, warn};

use crate::persistence::{is_direct_thread_owned_async, PersistCommand};
use crate::session::SessionHandle;
use crate::session_command::SessionCommand;
use crate::session_naming::name_from_first_prompt;
use crate::state::SessionRegistry;
use tokio::sync::oneshot;

pub async fn start_rollout_watcher(
    app_state: Arc<SessionRegistry>,
    persist_tx: mpsc::Sender<PersistCommand>,
) -> anyhow::Result<()> {
    if std::env::var("ORBITDOCK_DISABLE_CODEX_WATCHER").as_deref() == Ok("1") {
        info!(
            component = "rollout_watcher",
            event = "rollout_watcher.disabled",
            "Rollout watcher disabled by ORBITDOCK_DISABLE_CODEX_WATCHER"
        );
        return Ok(());
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let sessions_dir = PathBuf::from(&home).join(".codex/sessions");
    if !sessions_dir.exists() {
        info!(
            component = "rollout_watcher",
            event = "rollout_watcher.sessions_dir_missing",
            path = %sessions_dir.display(),
            "Rollout sessions directory missing"
        );
        return Ok(());
    }

    let state_path = crate::paths::rollout_state_path();
    let persisted_state = load_persisted_state(&state_path);

    let (tx, mut rx) = mpsc::unbounded_channel::<WatcherMessage>();
    let watcher_tx = tx.clone();

    let mut watcher = RecommendedWatcher::new(
        move |res: Result<notify::Event, notify::Error>| match res {
            Ok(event) => {
                if !matches_supported_event_kind(&event.kind) {
                    return;
                }
                for path in event.paths {
                    let _ = watcher_tx.send(WatcherMessage::FsEvent(path));
                }
            }
            Err(err) => {
                warn!(
                    component = "rollout_watcher",
                    event = "rollout_watcher.fs_event_error",
                    error = %err,
                    "Rollout watcher event error"
                );
            }
        },
        notify::Config::default(),
    )?;

    watcher.watch(&sessions_dir, RecursiveMode::Recursive)?;

    info!(
        component = "rollout_watcher",
        event = "rollout_watcher.started",
        path = %sessions_dir.display(),
        "Rollout watcher started"
    );

    let processor = RolloutFileProcessor::new(state_path, persisted_state);

    let mut runtime = WatcherRuntime {
        app_state,
        persist_tx,
        tx,
        processor,
        debounce_tasks: HashMap::new(),
        session_timeouts: HashMap::new(),
    };

    // Prime watcher from existing files on startup
    let existing_files = collect_jsonl_files(&sessions_dir);
    let mut seeded = 0usize;
    for path in &existing_files {
        if let Ok(metadata) = std::fs::metadata(path) {
            runtime.processor.ensure_file_state(
                path.to_string_lossy().as_ref(),
                metadata.len(),
                metadata.created().ok(),
            );
        }

        if is_recent_file(path, STARTUP_SEED_RECENT_SECS) {
            let path_string = path.to_string_lossy().to_string();
            match runtime.processor.ensure_session_meta(&path_string).await {
                Ok(events) => {
                    if let Err(err) = runtime.handle_rollout_events(events).await {
                        warn!(
                            component = "rollout_watcher",
                            event = "rollout_watcher.seed_event_failed",
                            path = %path.display(),
                            error = %err,
                            "Startup seed event handling failed"
                        );
                    }
                    seeded += 1;
                }
                Err(err) => {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.seed_failed",
                        path = %path.display(),
                        error = %err,
                        "Startup session_meta seed failed"
                    );
                }
            }
        }
    }
    info!(
        component = "rollout_watcher",
        event = "rollout_watcher.seed_complete",
        seeded_files = seeded,
        total_files = existing_files.len(),
        "Rollout startup seed complete"
    );

    // Backstop sweep
    let sweep_tx = runtime.tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(CATCHUP_SWEEP_SECS)).await;
            if sweep_tx.send(WatcherMessage::Sweep).is_err() {
                break;
            }
        }
    });

    while let Some(msg) = rx.recv().await {
        match msg {
            WatcherMessage::FsEvent(path) => {
                if is_jsonl_path(&path) {
                    runtime.schedule_file(path);
                } else if path.is_dir() {
                    for child in collect_jsonl_files(&path) {
                        runtime.schedule_file(child);
                    }
                } else if let Some(parent) = path.parent() {
                    for child in collect_jsonl_files(parent) {
                        runtime.schedule_file(child);
                    }
                }
            }
            WatcherMessage::ProcessFile(path) => {
                if let Err(err) = runtime.process_file(path).await {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.process_file_failed",
                        error = %err,
                        "Failed processing rollout file"
                    );
                }
            }
            WatcherMessage::SessionTimeout(session_id) => {
                runtime.handle_session_timeout(session_id).await;
            }
            WatcherMessage::Sweep => {
                if let Err(err) = runtime.sweep_files().await {
                    warn!(
                        component = "rollout_watcher",
                        event = "rollout_watcher.sweep_failed",
                        error = %err,
                        "Catch-up sweep failed"
                    );
                }
            }
        }
    }

    drop(watcher);
    Ok(())
}

enum WatcherMessage {
    FsEvent(PathBuf),
    ProcessFile(PathBuf),
    SessionTimeout(String),
    Sweep,
}

struct WatcherRuntime {
    app_state: Arc<SessionRegistry>,
    persist_tx: mpsc::Sender<PersistCommand>,
    tx: mpsc::UnboundedSender<WatcherMessage>,
    processor: RolloutFileProcessor,
    debounce_tasks: HashMap<String, JoinHandle<()>>,
    session_timeouts: HashMap<String, JoinHandle<()>>,
}

impl WatcherRuntime {
    async fn sweep_files(&mut self) -> anyhow::Result<()> {
        let candidates = self.processor.sweep_candidates();
        for path in candidates {
            self.process_file(path).await?;
        }
        Ok(())
    }

    fn schedule_file(&mut self, path: PathBuf) {
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

    async fn process_file(&mut self, path: PathBuf) -> anyhow::Result<()> {
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

    async fn handle_rollout_events(&mut self, events: Vec<RolloutEvent>) -> anyhow::Result<()> {
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
                    images,
                } => {
                    self.append_chat_message(&session_id, message_type, content, images)
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
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary });
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

            let (tx, rx) = oneshot::channel();
            actor.send(SessionCommand::GetSummary { reply: tx }).await;
            if let Ok(summary) = rx.await {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionCreated { session: summary });
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

    async fn append_chat_message(
        &mut self,
        session_id: &str,
        message_type: MessageType,
        content: String,
        images: Vec<orbitdock_protocol::ImageInput>,
    ) {
        let content = content.trim().to_string();
        if content.is_empty() && images.is_empty() {
            return;
        }

        // Allocate next sequence number from processor's file state
        let next_seq = {
            // Find the file state for this session to get next_message_seq
            let mut seq = 0u64;
            for state in self.processor.file_states.values_mut() {
                if state.session_id.as_deref() == Some(session_id) {
                    seq = state.next_message_seq;
                    state.next_message_seq = state.next_message_seq.saturating_add(1);
                    break;
                }
            }
            seq
        };

        let msg_id = format!("rollout-{session_id}-{next_seq}");
        let message = Message {
            id: msg_id,
            session_id: session_id.to_string(),
            sequence: Some(next_seq),
            message_type,
            content,
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: current_time_rfc3339(),
            duration_ms: None,
            images,
        };

        let Some(actor) = self.app_state.get_session(session_id) else {
            return;
        };

        actor
            .send(SessionCommand::AddMessageAndBroadcast {
                message: message.clone(),
            })
            .await;

        let _ = self
            .persist_tx
            .send(PersistCommand::MessageAppend {
                session_id: session_id.to_string(),
                message,
            })
            .await;
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
                event: crate::transition::Input::MessageUpdated {
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
                    crate::ai_naming::spawn_naming_task(
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
                        event: crate::transition::Input::TokensUpdated {
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
                    .broadcast_to_list(ServerMessage::SessionCreated { session: summary });
            }
        }
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
        let status = status.or(Some(SessionStatus::Active));
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

            let (tx, rx) = oneshot::channel();
            actor.send(SessionCommand::GetSummary { reply: tx }).await;
            if let Ok(summary) = rx.await {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionCreated { session: summary });
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

    async fn handle_session_timeout(&mut self, session_id: String) {
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
    use crate::persistence::flush_batch_for_test;
    use orbitdock_connector_codex::rollout_parser::{FileState, PersistedState};
    use rusqlite::{params, Connection};
    use std::collections::HashMap;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Once};
    use std::time::Duration;
    use tokio::sync::mpsc;
    use tokio::time::timeout;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-rollout-tests");
            std::fs::create_dir_all(&dir).expect("create rollout test data dir");
            crate::paths::init_data_dir(Some(&dir));
        });
    }

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
        ensure_test_data_dir();
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
    async fn rollout_activity_reactivates_ended_passive_session_in_memory() {
        ensure_test_data_dir();
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
        ensure_test_data_dir();
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
        ensure_test_data_dir();
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
        ensure_test_data_dir();
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
        ensure_test_data_dir();
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
            let (tx, rx) = tokio::sync::oneshot::channel();
            actor.send(SessionCommand::GetState { reply: tx }).await;
            rx.await.expect("get state")
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
}
