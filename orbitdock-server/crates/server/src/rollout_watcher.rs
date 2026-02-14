#![allow(clippy::items_after_test_module)]

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use anyhow::Context;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use orbitdock_protocol::{
    CodexIntegrationMode, Message, MessageType, Provider, ServerMessage, SessionStatus,
    StateChanges, WorkStatus,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::persistence::{is_direct_thread_owned_async, PersistCommand};
use crate::session::SessionHandle;
use crate::session_command::SessionCommand;
use crate::session_naming::name_from_first_prompt;
use crate::state::SessionRegistry;
use tokio::sync::oneshot;

const DEBOUNCE_MS: u64 = 150;
const SESSION_TIMEOUT_SECS: u64 = 120;
const STARTUP_SEED_RECENT_SECS: u64 = 15 * 60;
const CATCHUP_SWEEP_SECS: u64 = 3;

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

    let state_path = PathBuf::from(&home).join(".orbitdock/codex-rollout-state.json");
    let persisted_state = load_persisted_state(&state_path);

    let (tx, mut rx) = mpsc::unbounded_channel::<WatcherMessage>();
    let watcher_tx = tx.clone();

    let mut watcher = RecommendedWatcher::new(
        move |res: Result<Event, notify::Error>| match res {
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

    let mut runtime = WatcherRuntime {
        app_state,
        persist_tx,
        tx,
        state_path,
        watcher_started_at: SystemTime::now(),
        file_states: HashMap::new(),
        persisted_state,
        debounce_tasks: HashMap::new(),
        session_timeouts: HashMap::new(),
    };

    // Prime watcher from existing files on startup so active Codex CLI sessions
    // appear even when their JSONL files were created before this process launched.
    let existing_files = collect_jsonl_files(&sessions_dir);
    let mut seeded = 0usize;
    for path in &existing_files {
        if let Ok(metadata) = fs::metadata(path) {
            runtime.ensure_file_state(
                path.to_string_lossy().as_ref(),
                metadata.len(),
                metadata.created().ok(),
            );
        }

        if is_recent_file(path, STARTUP_SEED_RECENT_SECS) {
            if let Err(err) = runtime
                .ensure_session_meta(path.to_string_lossy().as_ref())
                .await
            {
                warn!(
                    component = "rollout_watcher",
                    event = "rollout_watcher.seed_failed",
                    path = %path.display(),
                    error = %err,
                    "Startup session_meta seed failed"
                );
            } else {
                seeded += 1;
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

    // Backstop for dropped filesystem events: periodically sweep known rollout files
    // and process any with new bytes.
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
                    // Some editors/writers (or platform backends) emit fs events for temp files
                    // near the target JSONL and not the JSONL path itself. Scan parent dir so
                    // rollout updates still get picked up.
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
    state_path: PathBuf,
    watcher_started_at: SystemTime,
    file_states: HashMap<String, FileState>,
    persisted_state: PersistedState,
    debounce_tasks: HashMap<String, JoinHandle<()>>,
    session_timeouts: HashMap<String, JoinHandle<()>>,
}

impl WatcherRuntime {
    async fn sweep_files(&mut self) -> anyhow::Result<()> {
        let mut candidates: Vec<PathBuf> = Vec::new();

        for (path, state) in &self.file_states {
            let path_buf = PathBuf::from(path);
            if !path_buf.exists() {
                continue;
            }
            let Ok(metadata) = fs::metadata(&path_buf) else {
                continue;
            };
            if metadata.len() != state.offset {
                candidates.push(path_buf);
            }
        }

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

        // Guard against stale persisted path->session bindings. A stale mapping can route
        // fresh rollout events to the wrong in-memory session and make the expected session
        // appear frozen in the UI.
        if let Some(hinted_session_id) = rollout_session_id_hint(&path) {
            let mapped_session_id = self
                .file_states
                .get(&path_string)
                .and_then(|state| state.session_id.clone());
            if let Some(mapped_session_id) = mapped_session_id {
                if mapped_session_id != hinted_session_id {
                    if let Some(state) = self.file_states.get_mut(&path_string) {
                        state.session_id = None;
                        state.project_path = None;
                        state.model_provider = None;
                    }
                    self.ensure_session_meta(&path_string).await?;
                }
            }
        }

        let metadata = fs::metadata(&path)?;
        let size = metadata.len();
        let created_at = metadata.created().ok();

        self.ensure_file_state(&path_string, size, created_at);

        let ignore_existing = self
            .file_states
            .get(&path_string)
            .map(|state| state.ignore_existing)
            .unwrap_or(false);

        if ignore_existing {
            let offset = self
                .file_states
                .get(&path_string)
                .map(|state| state.offset)
                .unwrap_or(0);
            if size > offset {
                if let Some(state) = self.file_states.get_mut(&path_string) {
                    state.ignore_existing = false;
                }
                self.ensure_session_meta(&path_string).await?;
            } else {
                if let Some(state) = self.file_states.get_mut(&path_string) {
                    state.offset = size;
                }
                self.persist_state(&path_string);
                return Ok(());
            }
        }

        if let Some(state) = self.file_states.get_mut(&path_string) {
            if size < state.offset {
                state.offset = 0;
                state.tail.clear();
            }
        }

        let offset = self
            .file_states
            .get(&path_string)
            .map(|state| state.offset)
            .unwrap_or(0);

        if size == offset {
            self.persist_state(&path_string);
            return Ok(());
        }

        let existing_session_id = self
            .file_states
            .get(&path_string)
            .and_then(|state| state.session_id.clone());
        let has_runtime_session = if let Some(session_id) = existing_session_id {
            self.app_state.get_session(&session_id).is_some()
        } else {
            false
        };
        if !has_runtime_session {
            self.ensure_session_meta(&path_string).await?;
        }

        let chunk = read_file_chunk(&path, offset)?;
        if let Some(state) = self.file_states.get_mut(&path_string) {
            state.offset = size;
        }

        if chunk.is_empty() {
            self.persist_state(&path_string);
            return Ok(());
        }

        let chunk = String::from_utf8_lossy(&chunk).to_string();
        if chunk.is_empty() {
            self.persist_state(&path_string);
            return Ok(());
        }

        let mut did_process_lines = false;
        let old_tail = self
            .file_states
            .get(&path_string)
            .map(|state| state.tail.clone())
            .unwrap_or_default();
        let combined = format!("{old_tail}{chunk}");
        let mut parts: Vec<&str> = combined.split('\n').collect();
        let next_tail = parts.pop().unwrap_or_default().to_string();

        if let Some(state) = self.file_states.get_mut(&path_string) {
            state.tail = next_tail;
        }

        for part in parts {
            let line = part.trim();
            if line.is_empty() {
                continue;
            }
            self.handle_line(line, &path_string).await;
            did_process_lines = true;
        }

        if did_process_lines {
            debug!(
                component = "rollout_watcher",
                event = "rollout_watcher.lines_processed",
                path = %path_string,
                "Processed rollout lines"
            );
        }

        self.persist_state(&path_string);
        Ok(())
    }

    async fn ensure_session_meta(&mut self, path: &str) -> anyhow::Result<()> {
        let Some(line) = read_first_line(Path::new(path))? else {
            return Ok(());
        };

        let Ok(json) = serde_json::from_str::<Value>(&line) else {
            warn!(
                component = "rollout_watcher",
                event = "rollout_watcher.session_meta_parse_failed",
                path = %path,
                "Failed to parse session_meta first line"
            );
            return Ok(());
        };

        if json.get("type").and_then(|v| v.as_str()) != Some("session_meta") {
            return Ok(());
        }

        let Some(payload) = json.get("payload").cloned() else {
            return Ok(());
        };

        self.handle_session_meta(payload, path).await;
        Ok(())
    }

    async fn handle_line(&mut self, line: &str, path: &str) {
        let Ok(json) = serde_json::from_str::<Value>(line) else {
            return;
        };

        let Some(line_type) = json.get("type").and_then(|v| v.as_str()) else {
            return;
        };

        let Some(payload) = json.get("payload").cloned() else {
            return;
        };

        match line_type {
            "session_meta" => self.handle_session_meta(payload, path).await,
            "turn_context" => self.handle_turn_context(payload, path).await,
            "event_msg" => self.handle_event_msg(payload, path).await,
            "response_item" => self.handle_response_item(payload, path).await,
            _ => {}
        }
    }

    async fn handle_session_meta(&mut self, payload: Value, path: &str) {
        let Some(session_id) = payload
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
        else {
            return;
        };
        let Some(cwd) = payload
            .get("cwd")
            .and_then(|v| v.as_str())
            .map(str::to_string)
        else {
            return;
        };

        let is_direct = self.app_state.is_managed_codex_thread(&session_id);
        let is_direct_in_db = is_direct_thread_owned_async(&session_id)
            .await
            .unwrap_or(false);
        if is_direct || is_direct_in_db {
            // If a stale passive runtime session exists for this thread, evict it.
            if let Some(state) = self.file_states.get_mut(path) {
                state.session_id = Some(session_id.clone());
            }
            if self.app_state.remove_session(&session_id).is_some() {
                self.app_state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: session_id.clone(),
                        reason: "direct_session_thread_claimed".into(),
                    });
            }
            if let Some(state) = self.file_states.get_mut(path) {
                state.session_id = Some(session_id);
            }
            return;
        }

        let model_provider = payload
            .get("model_provider")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let originator = payload
            .get("originator")
            .and_then(|v| v.as_str())
            .unwrap_or("codex")
            .to_string();
        let started_at = payload
            .get("timestamp")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_else(current_time_rfc3339);

        let (branch, project_name) = resolve_git_info(&cwd).await;
        let fallback_name = Path::new(&cwd)
            .file_name()
            .map(|s| s.to_string_lossy().to_string());
        let project_name = project_name.or(fallback_name);

        let exists = self.app_state.get_session(&session_id).is_some();

        if !exists {
            let mut handle = SessionHandle::new(session_id.clone(), Provider::Codex, cwd.clone());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            handle.set_transcript_path(Some(path.to_string()));
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
                    path: Some(path.to_string()),
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
                project_path: cwd.clone(),
                project_name,
                branch,
                model: model_provider.clone(),
                context_label: Some(originator),
                transcript_path: path.to_string(),
                started_at,
            })
            .await;

        if let Some(state) = self.file_states.get_mut(path) {
            state.session_id = Some(session_id.clone());
            state.project_path = Some(cwd);
            state.model_provider = model_provider;
        }

        if self.should_backfill_name_from_history(&session_id).await {
            if let Some(name) = derive_prompt_name_from_rollout_file(Path::new(path)) {
                self.set_custom_name(&session_id, Some(name)).await;
            }
        }

        self.schedule_session_timeout(&session_id);
    }

    async fn handle_turn_context(&mut self, payload: Value, path: &str) {
        let Some(session_id) = self
            .file_states
            .get(path)
            .and_then(|s| s.session_id.clone())
        else {
            return;
        };

        let mut project_path_update = None;
        let mut model_update = None;

        if let Some(model) = payload.get("model").and_then(|v| v.as_str()) {
            model_update = Some(model.to_string());
        }

        if let Some(cwd) = payload.get("cwd").and_then(|v| v.as_str()) {
            let changed = self
                .file_states
                .get(path)
                .and_then(|s| s.project_path.as_deref())
                .map(|existing| existing != cwd)
                .unwrap_or(true);
            if changed {
                project_path_update = Some(cwd.to_string());
                if let Some(state) = self.file_states.get_mut(path) {
                    state.project_path = Some(cwd.to_string());
                }
            }
        }

        if project_path_update.is_none() && model_update.is_none() {
            return;
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutSessionUpdate {
                id: session_id.clone(),
                project_path: project_path_update.clone(),
                model: model_update.clone(),
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

        if project_path_update.is_some() || model_update.is_some() {
            if let Some(actor) = self.app_state.get_session(&session_id) {
                if project_path_update.is_some() {
                    actor
                        .send(SessionCommand::SetLastActivityAt {
                            ts: Some(current_time_unix_z()),
                        })
                        .await;
                }
                if let Some(model) = model_update {
                    actor
                        .send(SessionCommand::SetModel { model: Some(model) })
                        .await;
                }
            }
            self.schedule_session_timeout(&session_id);
        }
    }

    async fn handle_event_msg(&mut self, payload: Value, path: &str) {
        let Some(session_id) = self
            .file_states
            .get(path)
            .and_then(|s| s.session_id.clone())
        else {
            return;
        };

        let Some(event_type) = payload.get("type").and_then(|v| v.as_str()) else {
            return;
        };

        match event_type {
            "task_started" | "turn_started" => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = false;
                    state.saw_user_event = false;
                }
                self.mark_working(&session_id, None).await;
                self.clear_pending(&session_id).await;
            }
            "task_complete" | "turn_complete" | "turn_aborted" => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = true;
                }
                self.mark_waiting(&session_id).await;
            }
            "user_message" => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_user_event = true;
                    state.saw_agent_event = false;
                }
                let message = payload
                    .get("message")
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
                self.handle_user_message(&session_id, message).await;
            }
            "agent_message" => {
                if let Some(state) = self.file_states.get_mut(path) {
                    state.saw_agent_event = true;
                }
                self.mark_waiting(&session_id).await;
            }
            "exec_command_begin" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_working(&session_id, Some("Shell".to_string()))
                    .await;
            }
            "exec_command_end" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_tool_completed(&session_id, Some("Shell".to_string()))
                    .await;
            }
            "patch_apply_begin" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_working(&session_id, Some("Edit".to_string()))
                    .await;
            }
            "patch_apply_end" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_tool_completed(&session_id, Some("Edit".to_string()))
                    .await;
            }
            "mcp_tool_call_begin" => {
                if self.saw_agent_event(path) {
                    return;
                }
                let label = mcp_tool_label(payload.get("invocation"));
                self.mark_working(&session_id, Some(label)).await;
            }
            "mcp_tool_call_end" => {
                if self.saw_agent_event(path) {
                    return;
                }
                let label = mcp_tool_label(payload.get("invocation"));
                self.mark_tool_completed(&session_id, Some(label)).await;
            }
            "web_search_begin" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_working(&session_id, Some("WebSearch".to_string()))
                    .await;
            }
            "web_search_end" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_tool_completed(&session_id, Some("WebSearch".to_string()))
                    .await;
            }
            "view_image_tool_call" => {
                if self.saw_agent_event(path) {
                    return;
                }
                self.mark_tool_completed(&session_id, Some("ViewImage".to_string()))
                    .await;
            }
            "exec_approval_request" => {
                let payload_json = serde_json::to_string(&payload).ok();
                self.set_permission_pending(&session_id, "ExecCommand", payload_json)
                    .await;
            }
            "apply_patch_approval_request" => {
                let payload_json = serde_json::to_string(&payload).ok();
                self.set_permission_pending(&session_id, "ApplyPatch", payload_json)
                    .await;
            }
            "request_user_input" => {
                let question = extract_question(&payload);
                self.set_question_pending(&session_id, question).await;
            }
            "elicitation_request" => {
                let question = payload
                    .get("message")
                    .and_then(|v| v.as_str())
                    .map(str::to_string)
                    .or_else(|| {
                        payload
                            .get("server_name")
                            .and_then(|v| v.as_str())
                            .map(str::to_string)
                    });
                self.set_question_pending(&session_id, question).await;
            }
            "token_count" => {
                let total_tokens = payload
                    .get("info")
                    .and_then(|v| v.get("total_token_usage"))
                    .and_then(|v| v.get("total_tokens"))
                    .and_then(as_i64);

                if let Some(total_tokens) = total_tokens {
                    let _ = self
                        .persist_tx
                        .send(PersistCommand::RolloutSessionUpdate {
                            id: session_id,
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
            }
            "thread_name_updated" => {
                if let Some(name) = payload.get("thread_name").and_then(|v| v.as_str()) {
                    self.set_custom_name(&session_id, Some(name.to_string()))
                        .await;
                }
            }
            _ => {}
        }
    }

    async fn handle_response_item(&mut self, payload: Value, path: &str) {
        let Some(session_id) = self
            .file_states
            .get(path)
            .and_then(|s| s.session_id.clone())
        else {
            return;
        };

        let Some(payload_type) = payload.get("type").and_then(|v| v.as_str()) else {
            return;
        };

        match payload_type {
            "message" => {
                let role = payload.get("role").and_then(|v| v.as_str());
                if role == Some("user") {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state.saw_user_event = true;
                        state.saw_agent_event = false;
                    }
                    let message = extract_response_item_message_text(&payload);
                    if let Some(text) = message.clone() {
                        self.append_chat_message(path, &session_id, MessageType::User, text)
                            .await;
                    }
                    self.handle_user_message(&session_id, message).await;
                } else if role == Some("assistant") {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state.saw_agent_event = true;
                    }
                    if let Some(text) = extract_response_item_message_text(&payload) {
                        self.append_chat_message(path, &session_id, MessageType::Assistant, text)
                            .await;
                    }
                    self.mark_waiting(&session_id).await;
                }
            }
            "function_call" => {
                if self.saw_agent_event(path) {
                    return;
                }
                let Some(call_id) = payload.get("call_id").and_then(|v| v.as_str()) else {
                    return;
                };
                let tool = tool_label(payload.get("name").and_then(|v| v.as_str()));
                if let Some(tool) = tool {
                    if let Some(state) = self.file_states.get_mut(path) {
                        state
                            .pending_tool_calls
                            .insert(call_id.to_string(), tool.clone());
                    }
                    self.mark_working(&session_id, Some(tool)).await;
                }
            }
            "function_call_output" => {
                if self.saw_agent_event(path) {
                    return;
                }
                let Some(call_id) = payload.get("call_id").and_then(|v| v.as_str()) else {
                    return;
                };

                let tool_name = if let Some(state) = self.file_states.get_mut(path) {
                    state.pending_tool_calls.remove(call_id)
                } else {
                    None
                };

                if let Some(tool_name) = tool_name {
                    self.mark_tool_completed(&session_id, Some(tool_name)).await;
                }
            }
            _ => {}
        }
    }

    async fn append_chat_message(
        &mut self,
        path: &str,
        session_id: &str,
        message_type: MessageType,
        content: String,
    ) {
        let content = content.trim().to_string();
        if content.is_empty() {
            return;
        }

        let next_seq = if let Some(state) = self.file_states.get_mut(path) {
            let seq = state.next_message_seq;
            state.next_message_seq = state.next_message_seq.saturating_add(1);
            seq
        } else {
            0
        };

        let message = Message {
            id: format!("rollout-{session_id}-{next_seq}"),
            session_id: session_id.to_string(),
            message_type,
            content,
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            timestamp: current_time_rfc3339(),
            duration_ms: None,
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

    async fn handle_user_message(&mut self, session_id: &str, message: Option<String>) {
        let first_prompt = message.as_deref().and_then(name_from_first_prompt);

        if let Some(prompt) = first_prompt.as_ref() {
            let current_name = self
                .app_state
                .get_session(session_id)
                .and_then(|actor| actor.snapshot().custom_name.clone());

            if current_name.is_none() {
                self.set_custom_name(session_id, Some(prompt.clone())).await;
            }
        }

        let _ = self
            .persist_tx
            .send(PersistCommand::RolloutPromptIncrement {
                id: session_id.to_string(),
                first_prompt,
            })
            .await;

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

    async fn set_permission_pending(
        &mut self,
        session_id: &str,
        tool_name: &str,
        payload: Option<String>,
    ) {
        self.update_work_state(
            session_id,
            WorkStatus::Permission,
            Some("awaitingPermission".to_string()),
            Some(Some(tool_name.to_string())),
            Some(payload),
            None,
            None,
            None,
            None,
        )
        .await;
    }

    async fn set_question_pending(&mut self, session_id: &str, question: Option<String>) {
        self.update_work_state(
            session_id,
            WorkStatus::Question,
            Some("awaitingQuestion".to_string()),
            None,
            None,
            Some(question),
            None,
            None,
            None,
        )
        .await;
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

    async fn mark_working(&mut self, session_id: &str, tool: Option<String>) {
        let now = current_time_rfc3339();
        self.update_work_state(
            session_id,
            WorkStatus::Working,
            Some("none".to_string()),
            None,
            None,
            None,
            tool.map(Some),
            Some(Some(now)),
            None,
        )
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

        if let Some(tool_name) = tool {
            let _ = tool_name;
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

    async fn mark_waiting(&mut self, session_id: &str) {
        self.update_work_state(
            session_id,
            WorkStatus::Waiting,
            Some("awaitingReply".to_string()),
            Some(None),
            Some(None),
            Some(None),
            None,
            None,
            None,
        )
        .await;
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
                    persist_op: None, // Already persisted via RolloutSessionUpdate above
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

            // Ensure status is Active (merge into changes) for reactivation
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
                // Check if reactivation happened by reading snapshot
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

    fn saw_agent_event(&self, path: &str) -> bool {
        self.file_states
            .get(path)
            .map(|s| s.saw_agent_event)
            .unwrap_or(false)
    }

    async fn should_backfill_name_from_history(&self, session_id: &str) -> bool {
        let current_name = self
            .app_state
            .get_session(session_id)
            .and_then(|actor| actor.snapshot().custom_name.clone());

        current_name.is_none()
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

    fn ensure_file_state(&mut self, path: &str, size: u64, created_at: Option<SystemTime>) {
        if self.file_states.contains_key(path) {
            return;
        }

        if let Some(persisted) = self.persisted_state.files.get(path) {
            self.file_states.insert(
                path.to_string(),
                FileState {
                    offset: persisted.offset,
                    tail: String::new(),
                    session_id: persisted.session_id.clone(),
                    project_path: persisted.project_path.clone(),
                    model_provider: persisted.model_provider.clone(),
                    ignore_existing: persisted.ignore_existing.unwrap_or(false),
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            );
            return;
        }

        let mut ignore_existing = false;
        let mut offset = 0;

        if let Some(created_at) = created_at {
            if created_at < self.watcher_started_at {
                ignore_existing = true;
                offset = size;
            }
        }

        self.file_states.insert(
            path.to_string(),
            FileState {
                offset,
                tail: String::new(),
                session_id: None,
                project_path: None,
                model_provider: None,
                ignore_existing,
                pending_tool_calls: HashMap::new(),
                next_message_seq: 0,
                saw_user_event: false,
                saw_agent_event: false,
            },
        );
    }

    fn persist_state(&mut self, path: &str) {
        if let Some(state) = self.file_states.get(path) {
            self.persisted_state.files.insert(
                path.to_string(),
                PersistedFileState {
                    offset: state.offset,
                    session_id: state.session_id.clone(),
                    project_path: state.project_path.clone(),
                    model_provider: state.model_provider.clone(),
                    ignore_existing: Some(state.ignore_existing),
                },
            );
            if let Err(err) = save_persisted_state(&self.state_path, &self.persisted_state) {
                warn!(
                    component = "rollout_watcher",
                    event = "rollout_watcher.state_persist_failed",
                    path = %self.state_path.display(),
                    error = %err,
                    "Failed writing rollout state"
                );
            }
        }
    }
}

#[derive(Debug, Clone)]
struct FileState {
    offset: u64,
    tail: String,
    session_id: Option<String>,
    project_path: Option<String>,
    model_provider: Option<String>,
    ignore_existing: bool,
    pending_tool_calls: HashMap<String, String>,
    next_message_seq: u64,
    saw_user_event: bool,
    saw_agent_event: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct PersistedState {
    version: i32,
    files: HashMap<String, PersistedFileState>,
}

impl Default for PersistedState {
    fn default() -> Self {
        Self {
            version: 1,
            files: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct PersistedFileState {
    offset: u64,
    session_id: Option<String>,
    project_path: Option<String>,
    model_provider: Option<String>,
    ignore_existing: Option<bool>,
}

fn load_persisted_state(path: &Path) -> PersistedState {
    let Ok(data) = fs::read(path) else {
        return PersistedState::default();
    };
    serde_json::from_slice(&data).unwrap_or_default()
}

fn save_persisted_state(path: &Path, state: &PersistedState) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let data = serde_json::to_vec(state)?;
    let tmp_path = path.with_extension("json.tmp");
    fs::write(&tmp_path, data)?;
    fs::rename(&tmp_path, path)?;
    Ok(())
}

fn collect_jsonl_files(root: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if is_jsonl_path(&path) {
                result.push(path);
            }
        }
    }

    result
}

fn is_recent_file(path: &Path, within_secs: u64) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    let Ok(modified) = meta.modified() else {
        return false;
    };
    let Ok(age) = SystemTime::now().duration_since(modified) else {
        return true;
    };
    age.as_secs() <= within_secs
}

fn read_first_line(path: &Path) -> anyhow::Result<Option<String>> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err.into()),
    };

    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let read = reader.read_line(&mut line)?;
    if read == 0 {
        return Ok(None);
    }
    Ok(Some(line.trim_end_matches(['\r', '\n']).to_string()))
}

fn read_file_chunk(path: &Path, offset: u64) -> anyhow::Result<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(path)
        .with_context(|| format!("open {}", path.display()))?;

    file.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

fn derive_prompt_name_from_rollout_file(path: &Path) -> Option<String> {
    let file = File::open(path).ok()?;
    let reader = BufReader::new(file);

    for line in reader.lines().take(4096).flatten() {
        let json: Value = serde_json::from_str(&line).ok()?;
        let line_type = json.get("type").and_then(|v| v.as_str())?;
        let payload = json.get("payload")?;

        match line_type {
            "event_msg" => {
                if payload.get("type").and_then(|v| v.as_str()) == Some("user_message") {
                    if let Some(message) = payload.get("message").and_then(|v| v.as_str()) {
                        if let Some(name) = name_from_first_prompt(message) {
                            return Some(name);
                        }
                    }
                }
            }
            "response_item" => {
                if payload.get("type").and_then(|v| v.as_str()) == Some("message")
                    && payload.get("role").and_then(|v| v.as_str()) == Some("user")
                {
                    if let Some(message) = extract_response_item_message_text(payload) {
                        if let Some(name) = name_from_first_prompt(&message) {
                            return Some(name);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    None
}

fn is_jsonl_path(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some("jsonl")
}

fn rollout_session_id_hint(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    if stem.len() < 36 {
        return None;
    }
    let tail = &stem[stem.len() - 36..];
    if is_uuid_like(tail) {
        Some(tail.to_string())
    } else {
        None
    }
}

fn is_uuid_like(value: &str) -> bool {
    if value.len() != 36 {
        return false;
    }
    for (idx, ch) in value.chars().enumerate() {
        let is_dash = matches!(idx, 8 | 13 | 18 | 23);
        if is_dash {
            if ch != '-' {
                return false;
            }
        } else if !ch.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

async fn resolve_git_info(path: &str) -> (Option<String>, Option<String>) {
    let branch = run_git(&["rev-parse", "--abbrev-ref", "HEAD"], path).await;
    let repo_root = run_git(&["rev-parse", "--show-toplevel"], path).await;
    let repo_name = repo_root
        .as_deref()
        .and_then(|root| Path::new(root).file_name())
        .map(|name| name.to_string_lossy().to_string());

    (branch, repo_name)
}

async fn run_git(args: &[&str], cwd: &str) -> Option<String> {
    let output = Command::new("/usr/bin/git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8(output.stdout).ok()?;
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

fn extract_response_item_message_text(payload: &Value) -> Option<String> {
    if let Some(text) = payload.get("content").and_then(|v| v.as_str()) {
        return Some(text.to_string());
    }

    let content = payload.get("content")?.as_array()?;
    let mut parts = Vec::new();
    for item in content {
        if let Some(text) = item.get("text").and_then(|v| v.as_str()) {
            if !text.trim().is_empty() {
                parts.push(text.trim().to_string());
            }
            continue;
        }
        if let Some(text) = item.get("input_text").and_then(|v| v.as_str()) {
            if !text.trim().is_empty() {
                parts.push(text.trim().to_string());
            }
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

fn extract_question(payload: &Value) -> Option<String> {
    payload
        .get("questions")
        .and_then(|v| v.as_array())
        .and_then(|questions| questions.first())
        .and_then(|first| {
            first
                .get("question")
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .or_else(|| {
                    first
                        .get("header")
                        .and_then(|v| v.as_str())
                        .map(str::to_string)
                })
        })
}

fn mcp_tool_label(invocation: Option<&Value>) -> String {
    if let Some(invocation) = invocation {
        let server = invocation.get("server").and_then(|v| v.as_str());
        let tool = invocation.get("tool").and_then(|v| v.as_str());
        if let (Some(server), Some(tool)) = (server, tool) {
            return format!("MCP:{server}/{tool}");
        }
    }

    "MCP".to_string()
}

fn tool_label(raw: Option<&str>) -> Option<String> {
    let raw = raw?;
    if raw.is_empty() {
        return None;
    }

    Some(match raw {
        "exec_command" => "Shell".to_string(),
        "patch_apply" | "apply_patch" => "Edit".to_string(),
        "web_search" => "WebSearch".to_string(),
        "view_image" => "ViewImage".to_string(),
        "mcp_tool_call" => "MCP".to_string(),
        other => other.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::persistence::flush_batch_for_test;
    use rusqlite::{params, Connection};
    use serde_json::json;
    use std::collections::HashMap;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::{Duration, SystemTime};
    use tokio::sync::mpsc;
    use tokio::time::timeout;

    #[test]
    fn extracts_text_from_response_item_content_array() {
        let payload = json!({
            "type": "message",
            "role": "user",
            "content": [
                { "type": "input_text", "text": "Investigate flaky tests" },
                { "type": "input_text", "text": "and propose a fix" }
            ]
        });

        let text = extract_response_item_message_text(&payload).expect("expected extracted text");
        assert!(text.contains("Investigate flaky tests"));
        assert!(text.contains("and propose a fix"));
    }

    #[test]
    fn derives_prompt_name_from_rollout_history() {
        let path = std::env::temp_dir().join(format!(
            "orbitdock-rollout-test-{}.jsonl",
            std::process::id()
        ));
        let contents = r#"{"type":"session_meta","payload":{"id":"abc","cwd":"/tmp/repo"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate flaky session naming behavior please"}]}}
"#;
        std::fs::write(&path, contents).expect("write test file");

        let derived = derive_prompt_name_from_rollout_file(&path);
        std::fs::remove_file(&path).ok();

        assert_eq!(
            derived.as_deref(),
            Some("Investigate flaky session naming behavior please")
        );
    }

    #[test]
    fn skips_bootstrap_payloads_when_deriving_prompt_name() {
        let path = std::env::temp_dir().join(format!(
            "orbitdock-rollout-bootstrap-test-{}.jsonl",
            std::process::id()
        ));
        let contents = r#"{"type":"session_meta","payload":{"id":"abc","cwd":"/tmp/repo"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>...</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Investigate flaky session naming behavior please"}]}}
"#;
        std::fs::write(&path, contents).expect("write test file");

        let derived = derive_prompt_name_from_rollout_file(&path);
        std::fs::remove_file(&path).ok();

        assert_eq!(
            derived.as_deref(),
            Some("Investigate flaky session naming behavior please")
        );
    }

    #[tokio::test]
    async fn startup_seeded_passive_session_backfills_name_from_rollout_prompt() {
        let session_id = format!("passive-name-backfill-{}", std::process::id());
        let tmp_dir = std::env::temp_dir().join(format!("orbitdock-rollout-name-{}", session_id));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join("rollout.jsonl");
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n\
{{\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"type\":\"input_text\",\"text\":\"Investigate flaky session naming behavior please\"}}]}}}}\n",
                session_id
            ),
        )
        .expect("write rollout seed");

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::new(),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

        runtime
            .ensure_session_meta(rollout_path.to_string_lossy().as_ref())
            .await
            .expect("seed session meta");

        let snapshot = {
            let actor = app_state.get_session(&session_id).expect("session exists");
            actor.snapshot()
        };

        assert_eq!(
            snapshot.custom_name.as_deref(),
            Some("Investigate flaky session naming behavior please")
        );

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn rollout_activity_reactivates_ended_passive_session_in_memory() {
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
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

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

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                type TEXT NOT NULL,
                content TEXT,
                timestamp TEXT NOT NULL,
                sequence INTEGER NOT NULL DEFAULT 0,
                tool_name TEXT,
                tool_input TEXT,
                tool_output TEXT,
                tool_duration REAL,
                is_in_progress INTEGER NOT NULL DEFAULT 0
            );",
        )
        .expect("ensure messages table");
    }

    #[tokio::test]
    async fn rollout_activity_reactivates_closed_passive_session_in_memory_and_db() {
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
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

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

        // End the session directly via actor command
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
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

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
    async fn stale_file_mapping_rebinds_to_rollout_session_id_before_processing_lines() {
        let actual_session_id = format!("019c0000-0000-4000-8000-{:012x}", std::process::id());
        let stale_session_id = format!("019cffff-ffff-4000-8000-{:012x}", std::process::id());
        let tmp_dir =
            std::env::temp_dir().join(format!("orbitdock-rollout-rebind-{}", std::process::id()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
        let rollout_path = tmp_dir.join(format!(
            "rollout-2026-02-10T03-20-00-{}.jsonl",
            actual_session_id
        ));
        std::fs::write(
            &rollout_path,
            format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"/tmp/repo\"}}}}\n",
                actual_session_id
            ),
        )
        .expect("write rollout seed");
        let initial_size = std::fs::metadata(&rollout_path)
            .expect("stat rollout")
            .len();

        let (persist_tx, _persist_rx) = mpsc::channel(128);
        let app_state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        {
            let mut stale_handle = SessionHandle::new(
                stale_session_id.clone(),
                Provider::Codex,
                "/tmp/repo".to_string(),
            );
            stale_handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            stale_handle.set_status(SessionStatus::Ended);
            stale_handle.set_work_status(WorkStatus::Ended);
            app_state.add_session(stale_handle);

            let mut actual_handle = SessionHandle::new(
                actual_session_id.clone(),
                Provider::Codex,
                "/tmp/repo".to_string(),
            );
            actual_handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            actual_handle.set_status(SessionStatus::Ended);
            actual_handle.set_work_status(WorkStatus::Ended);
            actual_handle.set_transcript_path(Some(rollout_path.to_string_lossy().to_string()));
            app_state.add_session(actual_handle);
        }

        let (watcher_tx, _watcher_rx) = mpsc::unbounded_channel();
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(stale_session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

        std::fs::OpenOptions::new()
            .append(true)
            .open(&rollout_path)
            .expect("open rollout")
            .write_all(
                b"{\"timestamp\":\"2026-02-10T03:20:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"new work\"}}\n",
            )
            .expect("append user_message");

        runtime
            .process_file(PathBuf::from(&rollout_path))
            .await
            .expect("process rollout");

        let (actual_snapshot, stale_snapshot) = {
            let actual = app_state
                .get_session(&actual_session_id)
                .expect("actual session exists")
                .snapshot();
            let stale = app_state
                .get_session(&stale_session_id)
                .expect("stale session exists")
                .snapshot();
            (actual, stale)
        };

        assert_eq!(actual_snapshot.status, SessionStatus::Active);
        assert_eq!(actual_snapshot.work_status, WorkStatus::Working);
        assert_eq!(stale_snapshot.status, SessionStatus::Ended);
        assert_eq!(stale_snapshot.work_status, WorkStatus::Ended);

        let _ = std::fs::remove_file(&rollout_path);
        let _ = std::fs::remove_file(tmp_dir.join("state.json"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[tokio::test]
    async fn catchup_sweep_processes_appended_lines_without_fs_event() {
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
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

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
        let mut runtime = WatcherRuntime {
            app_state: app_state.clone(),
            persist_tx,
            tx: watcher_tx,
            state_path: tmp_dir.join("state.json"),
            watcher_started_at: SystemTime::now(),
            file_states: HashMap::from([(
                rollout_path.to_string_lossy().to_string(),
                FileState {
                    offset: initial_size,
                    tail: String::new(),
                    session_id: Some(session_id.clone()),
                    project_path: Some("/tmp/repo".to_string()),
                    model_provider: Some("openai".to_string()),
                    ignore_existing: false,
                    pending_tool_calls: HashMap::new(),
                    next_message_seq: 0,
                    saw_user_event: false,
                    saw_agent_event: false,
                },
            )]),
            persisted_state: PersistedState::default(),
            debounce_tasks: HashMap::new(),
            session_timeouts: HashMap::new(),
        };

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

fn as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|v| v as i64))
        .or_else(|| value.as_f64().map(|v| v as i64))
        .or_else(|| value.as_str().and_then(|v| v.parse::<i64>().ok()))
}

fn current_time_rfc3339() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}Z", duration.as_secs())
}

fn current_time_unix_z() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
}

fn matches_supported_event_kind(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Access(_) | EventKind::Any
    )
}
