//! HTTP hook handler for Claude Code hooks.
//!
//! Replaces the Swift CLI — hooks now POST JSON directly to the Rust server.
//! The 5 Claude hook message types are handled here, extracted from websocket.rs.
//!
//! **Deferred session creation:** `ClaudeSessionStart` no longer creates a DB row
//! or broadcasts `SessionCreated`. Instead it caches metadata in memory. The session
//! is only materialized when the first actionable hook (status/tool/subagent) arrives.
//! If `SessionEnd` arrives first the pending entry is silently discarded, preventing
//! ghost sessions from `claude -c` bootstrap processes.

use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::{extract::State, http::StatusCode, Json};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

use orbitdock_protocol::{ClientMessage, Provider, ServerMessage};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_utils::{
    chrono_now, claude_transcript_path_from_cwd, is_stale_empty_claude_shell,
    project_name_from_cwd, sync_transcript_messages,
};
use crate::state::SessionRegistry;

/// Cached metadata from a `ClaudeSessionStart` hook, held in memory until the
/// first actionable hook materializes the session (or `SessionEnd` discards it).
pub struct PendingClaudeSession {
    pub cwd: String,
    pub model: Option<String>,
    pub source: Option<String>,
    pub context_label: Option<String>,
    pub transcript_path: Option<String>,
    pub permission_mode: Option<String>,
    pub agent_type: Option<String>,
    pub terminal_session_id: Option<String>,
    pub terminal_app: Option<String>,
    pub cached_at: Instant,
}

/// HTTP POST handler for `/api/hook`.
///
/// Accepts a `ClientMessage` JSON body, validates it's one of the 5 Claude hook
/// types, spawns fire-and-forget processing, and returns 204 immediately.
pub async fn hook_handler(
    State(state): State<Arc<SessionRegistry>>,
    Json(msg): Json<ClientMessage>,
) -> StatusCode {
    if !is_claude_hook(&msg) {
        return StatusCode::BAD_REQUEST;
    }

    tokio::spawn(async move {
        handle_hook_message(msg, &state).await;
    });

    StatusCode::NO_CONTENT
}

fn is_claude_hook(msg: &ClientMessage) -> bool {
    matches!(
        msg,
        ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. }
    )
}

fn normalized_non_empty(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn claude_permission_request_id(
    actor: Option<&SessionActorHandle>,
    tool_name: &str,
    tool_use_id: Option<&str>,
) -> String {
    if let Some(tool_use_id) = normalized_non_empty(tool_use_id) {
        return format!("claude-perm-tooluse-{tool_use_id}");
    }

    if let Some(existing_id) = actor
        .and_then(|actor| normalized_non_empty(actor.snapshot().pending_approval_id.as_deref()))
    {
        return existing_id;
    }

    format!(
        "claude-perm-{}-{}",
        tool_name,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    )
}

/// Classify a `PermissionRequest` hook by tool name into the appropriate
/// approval type, work status, and attention reason.
fn classify_permission_request(
    tool_name: &str,
) -> (
    orbitdock_protocol::ApprovalType,
    orbitdock_protocol::WorkStatus,
    &'static str,
) {
    match tool_name {
        "AskUserQuestion" => (
            orbitdock_protocol::ApprovalType::Question,
            orbitdock_protocol::WorkStatus::Question,
            "awaitingQuestion",
        ),
        "Edit" | "Write" | "NotebookEdit" => (
            orbitdock_protocol::ApprovalType::Patch,
            orbitdock_protocol::WorkStatus::Permission,
            "awaitingPermission",
        ),
        _ => (
            orbitdock_protocol::ApprovalType::Exec,
            orbitdock_protocol::WorkStatus::Permission,
            "awaitingPermission",
        ),
    }
}

/// Extract the first question text from an `AskUserQuestion` tool input.
fn extract_question_from_tool_input(tool_input: Option<&Value>) -> Option<String> {
    let input = tool_input?;
    // Try input.question first
    if let Some(q) = input.get("question").and_then(|v| v.as_str()) {
        return Some(q.to_string());
    }
    // Try input.questions[0].question
    input
        .get("questions")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|q| q.get("question"))
        .and_then(|v| v.as_str())
        .map(String::from)
}

async fn resolve_pending_approvals_after_tool_outcome(
    actor: &SessionActorHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
    session_id: &str,
    decision: &str,
    fallback_work_status: orbitdock_protocol::WorkStatus,
) {
    loop {
        let Some(request_id) =
            normalized_non_empty(actor.snapshot().pending_approval_id.as_deref())
        else {
            break;
        };

        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::ResolvePendingApproval {
                request_id: request_id.clone(),
                fallback_work_status,
                reply: reply_tx,
            })
            .await;

        let Ok(resolution) = reply_rx.await else {
            break;
        };

        if resolution.approval_type.is_none() {
            break;
        }

        let _ = persist_tx
            .send(PersistCommand::ApprovalDecision {
                session_id: session_id.to_string(),
                request_id,
                decision: decision.to_string(),
            })
            .await;

        let _ = persist_tx
            .send(PersistCommand::SessionUpdate {
                id: session_id.to_string(),
                status: None,
                work_status: Some(resolution.work_status),
                last_activity_at: None,
            })
            .await;

        if resolution.next_pending_approval.is_none() {
            break;
        }
    }
}

/// Process a Claude hook message. Extracted from `handle_client_message` in websocket.rs.
/// These handlers never need `client_tx` or `conn_id` — only `state`.
pub async fn handle_hook_message(msg: ClientMessage, state: &Arc<SessionRegistry>) {
    match msg {
        ClientMessage::ClaudeSessionStart {
            session_id,
            cwd,
            model,
            source,
            context_label,
            transcript_path,
            permission_mode,
            agent_type,
            terminal_session_id,
            terminal_app,
        } => {
            // Defensive guard: codex rollout payloads should stay on Codex path.
            if context_label.as_deref() == Some("codex_cli_rs") {
                return;
            }

            // Enhanced Codex filter: reject payloads from Codex CLI sessions
            if is_codex_rollout_payload(transcript_path.as_deref(), model.as_deref()) {
                return;
            }

            // Skip if this session ID belongs to a managed Claude direct session
            if state.is_managed_claude_thread(&session_id) {
                return;
            }

            // If there's a direct Claude session awaiting SDK ID registration, claim it eagerly.
            if let Some(owning_id) = state.find_unregistered_direct_claude_session(&cwd) {
                state.register_claude_thread(&owning_id, &session_id);
                let _ = state
                    .persist()
                    .send(PersistCommand::SetClaudeSdkSessionId {
                        session_id: owning_id,
                        claude_sdk_session_id: session_id,
                    })
                    .await;
                return;
            }

            // If session already exists (e.g. restored from DB), update it directly
            // instead of caching as pending.
            if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
                existing
                    .send(SessionCommand::SetModel {
                        model: model.clone(),
                    })
                    .await;
                if transcript_path.is_some() {
                    existing
                        .send(SessionCommand::SetTranscriptPath {
                            path: transcript_path.clone(),
                        })
                        .await;
                }
                let git_info = crate::git::resolve_git_info(&cwd).await;
                let git_branch = git_info.as_ref().map(|g| g.branch.clone());
                let git_sha = git_info.as_ref().map(|g| g.sha.clone());
                let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
                let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

                // Use repository root for grouping so worktree sessions group correctly
                let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());

                existing
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                            git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                            git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                            repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                            is_worktree: if is_worktree { Some(true) } else { None },
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                        persist_op: None,
                    })
                    .await;
                // Seed the model into claude_models if not already present
                if let Some(ref m) = model {
                    let _ = state
                        .persist()
                        .send(PersistCommand::UpsertClaudeModelIfAbsent {
                            value: m.clone(),
                            display_name: crate::persistence::display_name_from_model_string(m),
                        })
                        .await;
                }
                let _ = state
                    .persist()
                    .send(PersistCommand::ClaudeSessionUpsert {
                        id: session_id,
                        project_path: effective_project_path.clone(),
                        project_name: project_name_from_cwd(&effective_project_path),
                        branch: git_branch,
                        model,
                        context_label,
                        transcript_path,
                        source,
                        agent_type,
                        permission_mode,
                        terminal_session_id,
                        terminal_app,
                        forked_from_session_id: None,
                        repository_root,
                        is_worktree,
                        git_sha,
                    })
                    .await;
                return;
            }

            // Defer session creation — cache metadata until an actionable hook arrives.
            state.cache_pending_claude(
                session_id,
                PendingClaudeSession {
                    cwd,
                    model,
                    source,
                    context_label,
                    transcript_path,
                    permission_mode,
                    agent_type,
                    terminal_session_id,
                    terminal_app,
                    cached_at: Instant::now(),
                },
            );
        }

        ClientMessage::ClaudeSessionEnd { session_id, reason } => {
            // Skip if this session ID belongs to a managed Claude direct session
            if state.is_managed_claude_thread(&session_id) {
                return;
            }

            // If session was never materialized (ghost from `claude -c`), discard silently.
            if state.discard_pending_claude(&session_id) {
                return;
            }

            let persist_tx = state.persist().clone();

            if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }

                // Extract AI-generated summary from transcript before ending
                if let Some(transcript_path) = &existing.snapshot().transcript_path {
                    if let Some(summary) =
                        crate::persistence::extract_summary_from_transcript_path(transcript_path)
                            .await
                    {
                        let _ = persist_tx
                            .send(PersistCommand::SetSummary {
                                session_id: session_id.clone(),
                                summary,
                            })
                            .await;
                    }
                }
            }

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionEnd {
                    id: session_id.clone(),
                    reason: reason.clone(),
                })
                .await;

            if state.remove_session(&session_id).is_some() {
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id,
                    reason: reason.unwrap_or_else(|| "hook_session_end".to_string()),
                });
            }
        }

        ClientMessage::ClaudeStatusEvent {
            session_id,
            cwd,
            transcript_path,
            hook_event_name,
            notification_type,
            tool_name,
            stop_hook_active: _,
            prompt,
            message: _,
            title: _,
            trigger: _,
            custom_instructions: _,
            permission_mode,
            last_assistant_message: _,
            teammate_name,
            team_name,
            task_id,
            task_subject,
            task_description: _,
            config_source,
            config_file_path,
        } => {
            if matches!(
                hook_event_name.as_str(),
                "TeammateIdle" | "TaskCompleted" | "ConfigChange"
            ) {
                tracing::info!(
                    component = "hook_handler",
                    event = "claude.status.extended",
                    session_id = %session_id,
                    hook_event_name = %hook_event_name,
                    teammate_name = ?teammate_name,
                    team_name = ?team_name,
                    task_id = ?task_id,
                    task_subject = ?task_subject,
                    config_source = ?config_source,
                    config_file_path = ?config_file_path,
                    "Received extended Claude status hook event"
                );
            }

            // If this hook is from a managed Claude direct session, route
            // supplementary data to the owning session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    if let Some(actor) = state.get_session(&owning_id) {
                        let persist_tx = state.persist().clone();

                        // Route summary extraction on Stop
                        if hook_event_name == "Stop" {
                            let snap = actor.snapshot();
                            if snap.summary.is_none() {
                                let derived = cwd
                                    .as_deref()
                                    .and_then(|p| claude_transcript_path_from_cwd(p, &session_id));
                                let tp = snap
                                    .transcript_path
                                    .clone()
                                    .or_else(|| transcript_path.clone())
                                    .or(derived);
                                if let Some(path) = tp {
                                    if let Some(summary) =
                                        crate::persistence::extract_summary_from_transcript_path(
                                            &path,
                                        )
                                        .await
                                    {
                                        actor
                                            .send(SessionCommand::ApplyDelta {
                                                changes: orbitdock_protocol::StateChanges {
                                                    summary: Some(Some(summary.clone())),
                                                    ..Default::default()
                                                },
                                                persist_op: None,
                                            })
                                            .await;
                                        let _ = persist_tx
                                            .send(PersistCommand::SetSummary {
                                                session_id: owning_id.clone(),
                                                summary,
                                            })
                                            .await;
                                    }
                                }
                            }
                        }

                        // Route compact_count increment on PreCompact
                        if hook_event_name == "PreCompact" {
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id.clone(),
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: None,
                                    last_tool_at: None,
                                    pending_tool_name: None,
                                    pending_tool_input: None,
                                    pending_question: None,
                                    source: None,
                                    agent_type: None,
                                    permission_mode: None,
                                    active_subagent_id: None,
                                    active_subagent_type: None,
                                    first_prompt: None,
                                    compact_count_increment: true,
                                })
                                .await;
                        }

                        // Route last_tool tracking
                        if let Some(ref tool_name) = tool_name {
                            actor
                                .send(SessionCommand::SetLastTool {
                                    tool: Some(tool_name.clone()),
                                })
                                .await;
                        }
                    }
                }
                return;
            }

            let persist_tx = state.persist().clone();
            let derived_transcript_path = cwd
                .as_deref()
                .and_then(|path| claude_transcript_path_from_cwd(path, &session_id));

            // Resolve full git info from cwd if available
            let git_info = match cwd.as_deref() {
                Some(path) => crate::git::resolve_git_info(path).await,
                None => None,
            };
            let git_branch = git_info.as_ref().map(|g| g.branch.clone());
            let git_sha = git_info.as_ref().map(|g| g.sha.clone());
            let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
            let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

            let actor = if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
                // Update branch/worktree info if we have it and it's missing
                if git_branch.is_some() && existing.snapshot().git_branch.is_none() {
                    existing
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                                repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                                is_worktree: if is_worktree { Some(true) } else { None },
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
                existing
            } else {
                // Materialize from pending cache or create a fallback session
                let fallback_cwd = cwd.clone().unwrap_or_else(|| "/unknown".to_string());
                let actor = materialize_claude_session(
                    &session_id,
                    &fallback_cwd,
                    transcript_path
                        .clone()
                        .or_else(|| derived_transcript_path.clone()),
                    git_info.as_ref(),
                    state,
                    &persist_tx,
                )
                .await;
                actor
            };

            if transcript_path.is_some() || derived_transcript_path.is_some() {
                actor
                    .send(SessionCommand::SetTranscriptPath {
                        path: transcript_path
                            .clone()
                            .or_else(|| derived_transcript_path.clone()),
                    })
                    .await;
            }

            // Use repository root for grouping so worktree sessions group correctly
            if let Some(cwd) = cwd.clone() {
                let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());
                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpsert {
                        id: session_id.clone(),
                        project_path: effective_project_path.clone(),
                        project_name: project_name_from_cwd(&effective_project_path),
                        branch: git_branch.clone(),
                        model: None,
                        context_label: None,
                        transcript_path: transcript_path
                            .clone()
                            .or_else(|| derived_transcript_path.clone()),
                        source: None,
                        agent_type: None,
                        permission_mode: permission_mode.clone(),
                        terminal_session_id: None,
                        terminal_app: None,
                        forked_from_session_id: None,
                        repository_root,
                        is_worktree,
                        git_sha,
                    })
                    .await;
            }

            let (next_work_status, persist_attention_reason) = match hook_event_name.as_str() {
                "UserPromptSubmit" => (
                    Some(orbitdock_protocol::WorkStatus::Working),
                    Some(Some("none".to_string())),
                ),
                "Stop" => {
                    let is_question = {
                        let (lt_tx, lt_rx) = oneshot::channel();
                        actor
                            .send(SessionCommand::GetLastTool { reply: lt_tx })
                            .await;
                        lt_rx.await.ok().flatten().as_deref() == Some("AskUserQuestion")
                    };
                    if is_question {
                        (
                            Some(orbitdock_protocol::WorkStatus::Question),
                            Some(Some("awaitingQuestion".to_string())),
                        )
                    } else {
                        (
                            Some(orbitdock_protocol::WorkStatus::Waiting),
                            Some(Some("awaitingReply".to_string())),
                        )
                    }
                }
                "Notification" => match notification_type.as_deref() {
                    // Notification events are informational; actionable permission/question
                    // state is driven by PermissionRequest tool hooks.
                    Some("permission_prompt") => (None, None),
                    Some("elicitation_dialog") => (None, None),
                    Some("idle_prompt") => {
                        let is_question = {
                            let (lt_tx, lt_rx) = oneshot::channel();
                            actor
                                .send(SessionCommand::GetLastTool { reply: lt_tx })
                                .await;
                            lt_rx.await.ok().flatten().as_deref() == Some("AskUserQuestion")
                        };
                        if is_question {
                            (
                                Some(orbitdock_protocol::WorkStatus::Question),
                                Some(Some("awaitingQuestion".to_string())),
                            )
                        } else {
                            (
                                Some(orbitdock_protocol::WorkStatus::Waiting),
                                Some(Some("awaitingReply".to_string())),
                            )
                        }
                    }
                    _ => (None, None),
                },
                "TeammateIdle" => (
                    Some(orbitdock_protocol::WorkStatus::Waiting),
                    Some(Some("awaitingReply".to_string())),
                ),
                _ => (None, None),
            };

            if hook_event_name == "UserPromptSubmit" {
                let _ = persist_tx
                    .send(PersistCommand::ClaudePromptIncrement {
                        id: session_id.clone(),
                        first_prompt: prompt.clone(),
                    })
                    .await;

                // Broadcast first_prompt delta and trigger AI naming
                if let Some(ref prompt_text) = prompt {
                    let changes = orbitdock_protocol::StateChanges {
                        first_prompt: Some(Some(prompt_text.clone())),
                        ..Default::default()
                    };
                    let _ = actor
                        .send(SessionCommand::ApplyDelta {
                            changes,
                            persist_op: None,
                        })
                        .await;

                    if state.naming_guard().try_claim(&session_id) {
                        crate::ai_naming::spawn_naming_task(
                            session_id.clone(),
                            prompt_text.clone(),
                            actor.clone(),
                            persist_tx.clone(),
                            state.list_tx(),
                        );
                    }
                }

                // Branch freshness: re-resolve git info on every user prompt to catch
                // branch switches between turns. Cost: ~10ms per user prompt.
                if let Some(ref prompt_cwd) = cwd {
                    let fresh_info = crate::git::resolve_git_info(prompt_cwd).await;
                    if let Some(ref info) = fresh_info {
                        // Push delta to clients
                        let _ = actor
                            .send(SessionCommand::ApplyDelta {
                                changes: orbitdock_protocol::StateChanges {
                                    git_branch: Some(Some(info.branch.clone())),
                                    git_sha: Some(Some(info.sha.clone())),
                                    repository_root: Some(Some(info.common_dir_root.clone())),
                                    is_worktree: if info.is_worktree { Some(true) } else { None },
                                    ..Default::default()
                                },
                                persist_op: None,
                            })
                            .await;
                        // Persist updated environment to DB
                        let _ = persist_tx
                            .send(PersistCommand::EnvironmentUpdate {
                                session_id: session_id.clone(),
                                cwd: Some(prompt_cwd.clone()),
                                git_branch: Some(info.branch.clone()),
                                git_sha: Some(info.sha.clone()),
                                repository_root: Some(info.common_dir_root.clone()),
                                is_worktree: Some(info.is_worktree),
                            })
                            .await;
                    }
                }
            }

            // On Stop events, try to extract AI-generated summary from transcript.
            if hook_event_name == "Stop" {
                let snap = actor.snapshot();
                if snap.summary.is_none() {
                    let tp = snap
                        .transcript_path
                        .clone()
                        .or_else(|| transcript_path.clone())
                        .or_else(|| derived_transcript_path.clone());
                    if let Some(path) = tp {
                        if let Some(extracted_summary) =
                            crate::persistence::extract_summary_from_transcript_path(&path).await
                        {
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes: orbitdock_protocol::StateChanges {
                                        summary: Some(Some(extracted_summary.clone())),
                                        ..Default::default()
                                    },
                                    persist_op: None,
                                })
                                .await;
                            let _ = persist_tx
                                .send(PersistCommand::SetSummary {
                                    session_id: session_id.clone(),
                                    summary: extracted_summary,
                                })
                                .await;
                        }
                    }
                }
            }

            if hook_event_name == "PreCompact" {
                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpdate {
                        id: session_id.clone(),
                        work_status: None,
                        attention_reason: None,
                        last_tool: None,
                        last_tool_at: None,
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        source: None,
                        agent_type: None,
                        permission_mode: None,
                        active_subagent_id: None,
                        active_subagent_type: None,
                        first_prompt: None,
                        compact_count_increment: true,
                    })
                    .await;
            }

            if let Some(tool_name) = tool_name {
                actor
                    .send(SessionCommand::SetLastTool {
                        tool: Some(tool_name),
                    })
                    .await;
            }

            if let Some(work_status) = next_work_status {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(work_status),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                        persist_op: None,
                    })
                    .await;

                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpdate {
                        id: session_id.clone(),
                        work_status: Some(match work_status {
                            orbitdock_protocol::WorkStatus::Working => "working".to_string(),
                            orbitdock_protocol::WorkStatus::Waiting => "waiting".to_string(),
                            orbitdock_protocol::WorkStatus::Permission => "permission".to_string(),
                            orbitdock_protocol::WorkStatus::Question => "question".to_string(),
                            orbitdock_protocol::WorkStatus::Reply => "reply".to_string(),
                            orbitdock_protocol::WorkStatus::Ended => "ended".to_string(),
                        }),
                        attention_reason: persist_attention_reason,
                        last_tool: None,
                        last_tool_at: None,
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        source: None,
                        agent_type: None,
                        permission_mode: permission_mode.clone().map(Some),
                        active_subagent_id: None,
                        active_subagent_type: None,
                        first_prompt: None,
                        compact_count_increment: false,
                    })
                    .await;
            }

            // Sync new messages from transcript
            sync_transcript_messages(&actor, &persist_tx).await;
        }

        ClientMessage::ClaudeToolEvent {
            session_id,
            cwd,
            hook_event_name,
            tool_name,
            tool_input,
            tool_response: _,
            tool_use_id,
            permission_suggestions,
            error: _,
            is_interrupt,
            permission_mode,
        } => {
            // If this hook is from a managed Claude direct session, route
            // supplementary data (tool_count, last_tool) to the owning session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    let persist_tx = state.persist().clone();

                    match hook_event_name.as_str() {
                        "PreToolUse" => {
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id.clone(),
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: Some(Some(tool_name.clone())),
                                    last_tool_at: Some(Some(chrono_now())),
                                    pending_tool_name: None,
                                    pending_tool_input: None,
                                    pending_question: None,
                                    source: None,
                                    agent_type: None,
                                    permission_mode: None,
                                    active_subagent_id: None,
                                    active_subagent_type: None,
                                    first_prompt: None,
                                    compact_count_increment: false,
                                })
                                .await;

                            if let Some(actor) = state.get_session(&owning_id) {
                                actor
                                    .send(SessionCommand::SetLastTool {
                                        tool: Some(tool_name.clone()),
                                    })
                                    .await;
                            }
                        }
                        "PermissionRequest" => {
                            // For managed direct sessions, the connector's
                            // can_use_tool control_request is the single source
                            // of truth for approvals. The hook PermissionRequest
                            // is redundant — skip approval creation and only
                            // persist supplementary metadata.
                            let permission_suggestions_count = permission_suggestions
                                .as_ref()
                                .and_then(|value| value.as_array())
                                .map_or(0, |items| items.len());

                            tracing::info!(
                                component = "hook_handler",
                                event = "claude.permission_request.managed_skip",
                                session_id = %owning_id,
                                tool_name = %tool_name,
                                permission_suggestions_count,
                                "Skipping hook-based approval for managed direct session (connector handles it)"
                            );

                            if let Some(actor) = state.get_session(&owning_id) {
                                actor
                                    .send(SessionCommand::SetLastTool {
                                        tool: Some(tool_name.clone()),
                                    })
                                    .await;
                            }

                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id.clone(),
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: Some(Some(tool_name)),
                                    last_tool_at: Some(Some(chrono_now())),
                                    pending_tool_name: None,
                                    pending_tool_input: None,
                                    pending_question: None,
                                    source: None,
                                    agent_type: None,
                                    permission_mode: None,
                                    active_subagent_id: None,
                                    active_subagent_type: None,
                                    first_prompt: None,
                                    compact_count_increment: false,
                                })
                                .await;
                        }
                        "PostToolUse" | "PostToolUseFailure" => {
                            if let Some(actor) = state.get_session(&owning_id) {
                                let decision = if hook_event_name == "PostToolUseFailure"
                                    && is_interrupt.unwrap_or(false)
                                {
                                    "denied"
                                } else {
                                    "approved"
                                };
                                resolve_pending_approvals_after_tool_outcome(
                                    &actor,
                                    &persist_tx,
                                    &owning_id,
                                    decision,
                                    orbitdock_protocol::WorkStatus::Working,
                                )
                                .await;
                            }

                            let _ = persist_tx
                                .send(PersistCommand::ClaudeToolIncrement {
                                    id: owning_id.clone(),
                                })
                                .await;
                        }
                        _ => {}
                    }
                }
                return;
            }

            let persist_tx = state.persist().clone();
            let derived_transcript_path = claude_transcript_path_from_cwd(&cwd, &session_id);

            // Resolve full git info from cwd
            let git_info = crate::git::resolve_git_info(&cwd).await;
            let git_branch = git_info.as_ref().map(|g| g.branch.clone());
            let git_sha = git_info.as_ref().map(|g| g.sha.clone());
            let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
            let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

            let actor = if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
                // Update branch/worktree info if missing
                if git_branch.is_some() && existing.snapshot().git_branch.is_none() {
                    existing
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                                repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                                is_worktree: if is_worktree { Some(true) } else { None },
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
                existing
            } else {
                // Materialize from pending cache or create a fallback session
                materialize_claude_session(
                    &session_id,
                    &cwd,
                    derived_transcript_path.clone(),
                    git_info.as_ref(),
                    state,
                    &persist_tx,
                )
                .await
            };

            let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());
            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionUpsert {
                    id: session_id.clone(),
                    project_path: effective_project_path.clone(),
                    project_name: project_name_from_cwd(&effective_project_path),
                    branch: git_branch,
                    model: None,
                    context_label: None,
                    transcript_path: derived_transcript_path,
                    source: None,
                    agent_type: None,
                    permission_mode: permission_mode.clone(),
                    terminal_session_id: None,
                    terminal_app: None,
                    forked_from_session_id: None,
                    repository_root,
                    is_worktree,
                    git_sha,
                })
                .await;

            match hook_event_name.as_str() {
                "PreToolUse" => {
                    let snapshot = actor.snapshot();
                    let was_permission =
                        snapshot.work_status == orbitdock_protocol::WorkStatus::Permission;
                    let had_pending_approval = snapshot.pending_approval_id.is_some();

                    let question = tool_input
                        .as_ref()
                        .and_then(|value| value.get("question"))
                        .and_then(Value::as_str)
                        .map(|s| s.to_string());
                    let serialized_input =
                        tool_input.and_then(|value| serde_json::to_string(&value).ok());

                    actor
                        .send(SessionCommand::SetLastTool {
                            tool: Some(tool_name.clone()),
                        })
                        .await;
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;

                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("working".to_string()),
                            attention_reason: Some(Some("none".to_string())),
                            last_tool: Some(Some(tool_name.clone())),
                            last_tool_at: Some(Some(chrono_now())),
                            pending_tool_name: if was_permission || had_pending_approval {
                                None
                            } else {
                                Some(Some(tool_name.clone()))
                            },
                            pending_tool_input: if was_permission || had_pending_approval {
                                None
                            } else {
                                Some(serialized_input)
                            },
                            pending_question: if was_permission || had_pending_approval {
                                None
                            } else {
                                Some(question)
                            },
                            source: None,
                            agent_type: None,
                            permission_mode: permission_mode.clone().map(Some),
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                "PostToolUse" => {
                    resolve_pending_approvals_after_tool_outcome(
                        &actor,
                        &persist_tx,
                        &session_id,
                        "approved",
                        orbitdock_protocol::WorkStatus::Working,
                    )
                    .await;

                    let _ = persist_tx
                        .send(PersistCommand::ClaudeToolIncrement {
                            id: session_id.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("working".to_string()),
                            attention_reason: Some(Some("none".to_string())),
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: Some(None),
                            pending_tool_input: Some(None),
                            pending_question: Some(None),
                            source: None,
                            agent_type: None,
                            permission_mode: permission_mode.clone().map(Some),
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;

                    // Broadcast permission_mode changes (e.g. EnterPlanMode sets "plan",
                    // ExitPlanMode restores "default") so clients update immediately.
                    let mut delta = orbitdock_protocol::StateChanges {
                        work_status: Some(orbitdock_protocol::WorkStatus::Working),
                        last_activity_at: Some(chrono_now()),
                        ..Default::default()
                    };
                    if permission_mode.is_some() {
                        delta.permission_mode = Some(permission_mode.clone());
                    }
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: delta,
                            persist_op: None,
                        })
                        .await;
                }
                "PostToolUseFailure" => {
                    let decision = if is_interrupt.unwrap_or(false) {
                        "denied"
                    } else {
                        "approved"
                    };
                    resolve_pending_approvals_after_tool_outcome(
                        &actor,
                        &persist_tx,
                        &session_id,
                        decision,
                        orbitdock_protocol::WorkStatus::Working,
                    )
                    .await;

                    let _ = persist_tx
                        .send(PersistCommand::ClaudeToolIncrement {
                            id: session_id.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("working".to_string()),
                            attention_reason: Some(Some("none".to_string())),
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: Some(None),
                            pending_tool_input: Some(None),
                            pending_question: Some(None),
                            source: None,
                            agent_type: None,
                            permission_mode: permission_mode.clone().map(Some),
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;

                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
                "PermissionRequest" => {
                    let permission_suggestions_count = permission_suggestions
                        .as_ref()
                        .and_then(|value| value.as_array())
                        .map_or(0, |items| items.len());
                    let question_text = extract_question_from_tool_input(tool_input.as_ref());
                    let serialized_input =
                        tool_input.and_then(|value| serde_json::to_string(&value).ok());
                    let (approval_type, work_status, attention_reason) =
                        classify_permission_request(&tool_name);
                    let request_id = claude_permission_request_id(
                        Some(&actor),
                        &tool_name,
                        tool_use_id.as_deref(),
                    );

                    actor
                        .send(SessionCommand::SetLastTool {
                            tool: Some(tool_name.clone()),
                        })
                        .await;
                    actor
                        .send(SessionCommand::SetPendingApproval {
                            request_id: request_id.clone(),
                            approval_type,
                            proposed_amendment: None,
                            tool_name: Some(tool_name.clone()),
                            tool_input: serialized_input.clone(),
                            question: question_text.clone(),
                        })
                        .await;
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(work_status),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;

                    tracing::info!(
                        component = "hook_handler",
                        event = "claude.permission_request",
                        session_id = %session_id,
                        tool_name = %tool_name,
                        ?approval_type,
                        permission_suggestions_count,
                        "Received Claude permission request"
                    );

                    let _ = persist_tx
                        .send(PersistCommand::ApprovalRequested {
                            session_id: session_id.clone(),
                            request_id,
                            approval_type,
                            tool_name: Some(tool_name.clone()),
                            command: None,
                            file_path: None,
                            cwd: None,
                            proposed_amendment: None,
                        })
                        .await;

                    let pending_question =
                        if approval_type == orbitdock_protocol::ApprovalType::Question {
                            Some(question_text)
                        } else {
                            None
                        };

                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some(
                                serde_json::to_value(work_status)
                                    .ok()
                                    .and_then(|v| v.as_str().map(String::from))
                                    .unwrap_or_else(|| "permission".to_string()),
                            ),
                            attention_reason: Some(Some(attention_reason.to_string())),
                            last_tool: Some(Some(tool_name.clone())),
                            last_tool_at: Some(Some(chrono_now())),
                            pending_tool_name: Some(Some(tool_name)),
                            pending_tool_input: Some(serialized_input),
                            pending_question,
                            source: None,
                            agent_type: None,
                            permission_mode: permission_mode.map(Some),
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                _ => {}
            }

            // Sync new messages from transcript
            sync_transcript_messages(&actor, &persist_tx).await;
        }

        ClientMessage::ClaudeSubagentEvent {
            session_id,
            hook_event_name,
            agent_id,
            agent_type,
            agent_transcript_path,
            stop_hook_active: _,
            last_assistant_message: _,
        } => {
            // If this hook is from a managed Claude direct session, route
            // subagent tracking to the owning session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    let persist_tx = state.persist().clone();

                    match hook_event_name.as_str() {
                        "SubagentStart" => {
                            let normalized_type =
                                agent_type.clone().unwrap_or_else(|| "unknown".to_string());
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSubagentStart {
                                    id: agent_id.clone(),
                                    session_id: owning_id.clone(),
                                    agent_type: normalized_type.clone(),
                                })
                                .await;
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id,
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: None,
                                    last_tool_at: None,
                                    pending_tool_name: None,
                                    pending_tool_input: None,
                                    pending_question: None,
                                    source: None,
                                    agent_type: None,
                                    permission_mode: None,
                                    active_subagent_id: Some(Some(agent_id)),
                                    active_subagent_type: Some(Some(normalized_type)),
                                    first_prompt: None,
                                    compact_count_increment: false,
                                })
                                .await;
                        }
                        "SubagentStop" => {
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSubagentEnd {
                                    id: agent_id,
                                    transcript_path: agent_transcript_path,
                                })
                                .await;
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id,
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: None,
                                    last_tool_at: None,
                                    pending_tool_name: None,
                                    pending_tool_input: None,
                                    pending_question: None,
                                    source: None,
                                    agent_type: None,
                                    permission_mode: None,
                                    active_subagent_id: Some(None),
                                    active_subagent_type: Some(None),
                                    first_prompt: None,
                                    compact_count_increment: false,
                                })
                                .await;
                        }
                        _ => {}
                    }
                }
                return;
            }

            let persist_tx = state.persist().clone();

            // If session doesn't exist yet, try to materialize from pending cache.
            // Subagent events don't carry cwd, so peek it from the pending entry.
            if state.get_session(&session_id).is_none() {
                if let Some(pending_cwd) = state.peek_pending_claude_cwd(&session_id) {
                    let git_info = crate::git::resolve_git_info(&pending_cwd).await;
                    let derived_tp = claude_transcript_path_from_cwd(&pending_cwd, &session_id);
                    materialize_claude_session(
                        &session_id,
                        &pending_cwd,
                        derived_tp,
                        git_info.as_ref(),
                        state,
                        &persist_tx,
                    )
                    .await;
                }
            }

            if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
            }

            match hook_event_name.as_str() {
                "SubagentStart" => {
                    let normalized_type =
                        agent_type.clone().unwrap_or_else(|| "unknown".to_string());
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSubagentStart {
                            id: agent_id.clone(),
                            session_id: session_id.clone(),
                            agent_type: normalized_type.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id,
                            work_status: None,
                            attention_reason: None,
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: None,
                            pending_tool_input: None,
                            pending_question: None,
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: Some(Some(agent_id)),
                            active_subagent_type: Some(Some(normalized_type)),
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                "SubagentStop" => {
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSubagentEnd {
                            id: agent_id,
                            transcript_path: agent_transcript_path,
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id,
                            work_status: None,
                            attention_reason: None,
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: None,
                            pending_tool_input: None,
                            pending_question: None,
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: Some(None),
                            active_subagent_type: Some(None),
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                _ => {}
            }
        }

        _ => {
            warn!(
                component = "hook_handler",
                event = "hook_handler.unexpected_message",
                "Received non-hook message type in hook handler"
            );
        }
    }
}

/// Materialize a Claude session from the pending cache (or create a bare fallback).
///
/// Called by status/tool/subagent handlers when the session doesn't exist yet.
/// Consumes the pending entry (if any), runs stale shell pruning, creates the
/// `SessionHandle`, broadcasts `SessionCreated`, and persists the upsert.
async fn materialize_claude_session(
    session_id: &str,
    fallback_cwd: &str,
    fallback_transcript_path: Option<String>,
    fallback_git_info: Option<&crate::git::GitInfo>,
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
) -> SessionActorHandle {
    // Pull cached metadata if available
    let pending = state.take_pending_claude(session_id);

    let cwd = pending
        .as_ref()
        .map(|p| p.cwd.clone())
        .unwrap_or_else(|| fallback_cwd.to_string());
    let model = pending.as_ref().and_then(|p| p.model.clone());
    let transcript_path = pending
        .as_ref()
        .and_then(|p| p.transcript_path.clone())
        .or(fallback_transcript_path);
    let source = pending.as_ref().and_then(|p| p.source.clone());
    let context_label = pending.as_ref().and_then(|p| p.context_label.clone());
    let agent_type = pending.as_ref().and_then(|p| p.agent_type.clone());
    let permission_mode = pending.as_ref().and_then(|p| p.permission_mode.clone());
    let terminal_session_id = pending.as_ref().and_then(|p| p.terminal_session_id.clone());
    let terminal_app = pending.as_ref().and_then(|p| p.terminal_app.clone());

    // Resolve git info — prefer fresh resolution when we have a pending cwd,
    // fall back to caller-provided info
    let resolved_git_info = if pending.is_some() {
        crate::git::resolve_git_info(&cwd).await
    } else {
        fallback_git_info.cloned()
    };

    let git_branch = resolved_git_info.as_ref().map(|g| g.branch.clone());
    let git_sha = resolved_git_info.as_ref().map(|g| g.sha.clone());
    let repository_root = resolved_git_info
        .as_ref()
        .map(|g| g.common_dir_root.clone());
    let is_worktree = resolved_git_info.as_ref().is_some_and(|g| g.is_worktree);

    // Use repository root as project path so worktree sessions group with parent repo
    let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());

    // Detect fork: source "resume" (claude -c) or "clear" (accept plan / clear context)
    // means this session continues from a previous one in the same project.
    let forked_from_session_id = if matches!(source.as_deref(), Some("resume") | Some("clear")) {
        find_most_recent_claude_session(session_id, &effective_project_path, state)
    } else {
        None
    };

    // Prune stale empty shells in the same project
    run_stale_shell_pruning(session_id, &effective_project_path, state, persist_tx).await;

    // Create the session with effective project path for correct grouping
    let mut handle = SessionHandle::new(
        session_id.to_string(),
        Provider::Claude,
        effective_project_path.clone(),
    );
    handle.set_claude_integration_mode(Some(orbitdock_protocol::ClaudeIntegrationMode::Passive));
    handle.set_project_name(project_name_from_cwd(&effective_project_path));
    handle.set_model(model.clone());
    handle.set_transcript_path(transcript_path.clone());
    handle.set_work_status(orbitdock_protocol::WorkStatus::Waiting);
    handle.set_terminal_info(terminal_session_id.clone(), terminal_app.clone());
    handle.set_worktree_info(repository_root.clone(), is_worktree, None);
    if let Some(ref fork_src) = forked_from_session_id {
        handle.set_forked_from(fork_src.clone());
    }
    let actor = state.add_session(handle);

    // Set branch + worktree info via delta
    if git_branch.is_some() || repository_root.is_some() {
        actor
            .send(SessionCommand::ApplyDelta {
                changes: orbitdock_protocol::StateChanges {
                    git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                    git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                    repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                    is_worktree: if is_worktree { Some(true) } else { None },
                    ..Default::default()
                },
                persist_op: None,
            })
            .await;
    }

    // Broadcast creation
    let (sum_tx, sum_rx) = oneshot::channel();
    actor
        .send(SessionCommand::GetSummary { reply: sum_tx })
        .await;
    if let Ok(summary) = sum_rx.await {
        state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
    }

    // Seed the model into claude_models if not already present
    if let Some(ref m) = model {
        let _ = persist_tx
            .send(PersistCommand::UpsertClaudeModelIfAbsent {
                value: m.clone(),
                display_name: crate::persistence::display_name_from_model_string(m),
            })
            .await;
    }

    // Persist full upsert with all cached metadata
    let _ = persist_tx
        .send(PersistCommand::ClaudeSessionUpsert {
            id: session_id.to_string(),
            project_path: effective_project_path.clone(),
            project_name: project_name_from_cwd(&effective_project_path),
            branch: git_branch,
            model,
            context_label,
            transcript_path,
            source,
            agent_type,
            permission_mode,
            terminal_session_id,
            terminal_app,
            forked_from_session_id,
            repository_root,
            is_worktree,
            git_sha,
        })
        .await;

    actor
}

/// Prune stale empty Claude shells in the same project directory.
async fn run_stale_shell_pruning(
    session_id: &str,
    cwd: &str,
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let stale_shell_ids: Vec<String> = state
        .get_session_summaries()
        .into_iter()
        .filter(|summary| is_stale_empty_claude_shell(summary, session_id, cwd, now_secs))
        .map(|summary| summary.id)
        .collect();

    for stale_id in stale_shell_ids {
        let _ = persist_tx
            .send(PersistCommand::ClaudeSessionEnd {
                id: stale_id.clone(),
                reason: Some("stale_empty_shell".to_string()),
            })
            .await;
        if state.remove_session(&stale_id).is_some() {
            state.broadcast_to_list(ServerMessage::SessionEnded {
                session_id: stale_id,
                reason: "stale_empty_shell".to_string(),
            });
        }
    }
}

/// Find the most recent Claude session in the same project directory.
/// Used to detect the fork origin when `source` is `"resume"` or `"clear"`.
fn find_most_recent_claude_session(
    current_session_id: &str,
    project_path: &str,
    state: &Arc<SessionRegistry>,
) -> Option<String> {
    state
        .get_session_summaries()
        .into_iter()
        .filter(|s| {
            s.provider == Provider::Claude
                && s.id != current_session_id
                && s.project_path == project_path
        })
        // Most recent by last_activity_at (descending)
        .max_by(|a, b| a.last_activity_at.cmp(&b.last_activity_at))
        .map(|s| s.id)
}

/// Check if a session-start payload is actually from Codex CLI.
fn is_codex_rollout_payload(transcript_path: Option<&str>, model: Option<&str>) -> bool {
    if let Some(path) = transcript_path {
        if path.contains("/.codex/sessions/") {
            return true;
        }
    }
    if let Some(m) = model {
        let lower = m.to_lowercase();
        if lower.contains("codex") || lower.starts_with("gpt-") {
            return true;
        }
    }
    false
}
