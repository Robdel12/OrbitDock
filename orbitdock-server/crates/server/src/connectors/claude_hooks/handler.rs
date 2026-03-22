//! HTTP hook handler for Claude Code hooks.
//!
//! Replaces the Swift CLI — hooks now POST JSON directly to the Rust server.
//! The 5 Claude hook message types are handled here, grouped behind the
//! Claude hook transport module instead of the WebSocket transport layer.
//!
//! **Deferred session creation:** `ClaudeSessionStart` no longer creates a DB row
//! or broadcasts `SessionCreated`. Instead it caches metadata in memory. The session
//! is only materialized when the first actionable hook (status/tool/subagent) arrives.
//! If `SessionEnd` arrives first the pending entry is silently discarded, preventing
//! ghost sessions from `claude -c` bootstrap processes.

use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tracing::warn;

use orbitdock_protocol::{ClientMessage, Provider, ServerMessage, SubagentInfo, SubagentStatus};

use crate::domain::sessions::transition::{
    approval_preview, approval_question, approval_question_prompts, ApprovalPreviewInput,
};
use crate::infrastructure::persistence::{ApprovalRequestedParams, PersistCommand};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::{PendingClaudeSession, SessionRegistry};
use crate::runtime::session_runtime_helpers::sync_transcript_messages;
use crate::support::session_paths::{claude_transcript_path_from_cwd, project_name_from_cwd};
use crate::support::session_time::chrono_now;

use super::approval::{
    classify_permission_request, claude_permission_request_id, extract_plan_from_tool_input,
    extract_question_from_tool_input, permission_request_matches_snapshot,
    resolve_pending_approvals_after_tool_outcome, PermissionRequestSnapshotMatch,
};
use super::session_materialization::{
    emit_capabilities_from_transcript, is_codex_rollout_payload, materialize_claude_session,
};

/// Process a Claude hook message.
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
                let git_info = crate::domain::git::repo::resolve_git_info(&cwd).await;
                let git_branch = git_info.as_ref().map(|g| g.branch.clone());
                let git_sha = git_info.as_ref().map(|g| g.sha.clone());
                let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
                let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

                // Use repository root for grouping so worktree sessions group correctly
                let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());

                existing
                    .send(SessionCommand::ApplyDelta {
                        changes: Box::new(orbitdock_protocol::StateChanges {
                            work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                            git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                            git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                            repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                            is_worktree: if is_worktree { Some(true) } else { None },
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        }),
                        persist_op: None,
                    })
                    .await;
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
                        crate::infrastructure::persistence::extract_summary_from_transcript_path(
                            transcript_path,
                        )
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
                state.broadcast_to_list(ServerMessage::SessionListItemRemoved { session_id });
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
                                        crate::infrastructure::persistence::extract_summary_from_transcript_path(
                                            &path,
                                        )
                                        .await
                                    {
                                        actor
                                            .send(SessionCommand::ApplyDelta {
                                                changes: Box::new(orbitdock_protocol::StateChanges {
                                                    summary: Some(Some(summary.clone())),
                                                    ..Default::default()
                                                }),
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
                Some(path) => crate::domain::git::repo::resolve_git_info(path).await,
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
                            changes: Box::new(orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                                repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                                is_worktree: if is_worktree { Some(true) } else { None },
                                ..Default::default()
                            }),
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
                    let is_question = actor.last_tool().await.ok().flatten().as_deref()
                        == Some("AskUserQuestion");
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
                        let is_question = actor.last_tool().await.ok().flatten().as_deref()
                            == Some("AskUserQuestion");
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
                            changes: Box::new(changes),
                            persist_op: None,
                        })
                        .await;

                    if state.naming_guard().try_claim(&session_id) {
                        crate::support::ai_naming::spawn_naming_task(
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
                    let fresh_info = crate::domain::git::repo::resolve_git_info(prompt_cwd).await;
                    if let Some(ref info) = fresh_info {
                        // Push delta to clients
                        let _ = actor
                            .send(SessionCommand::ApplyDelta {
                                changes: Box::new(orbitdock_protocol::StateChanges {
                                    git_branch: Some(Some(info.branch.clone())),
                                    git_sha: Some(Some(info.sha.clone())),
                                    repository_root: Some(Some(info.common_dir_root.clone())),
                                    is_worktree: if info.is_worktree { Some(true) } else { None },
                                    ..Default::default()
                                }),
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

            // On the first prompt, extract capabilities (skills, tools, slash_commands)
            // from the transcript and broadcast to subscribers. By UserPromptSubmit time
            // the init system message is always present in the transcript.
            if hook_event_name == "UserPromptSubmit" {
                emit_capabilities_from_transcript(&session_id, &actor).await;
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
                            crate::infrastructure::persistence::extract_summary_from_transcript_path(&path).await
                        {
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes: Box::new(orbitdock_protocol::StateChanges {
                                        summary: Some(Some(extracted_summary.clone())),
                                        ..Default::default()
                                    }),
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
                        changes: Box::new(orbitdock_protocol::StateChanges {
                            work_status: Some(work_status),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        }),
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
                            // For managed direct sessions, the connector owns
                            // the approval lifecycle via control_response.
                            // Do NOT call resolve_pending_approvals here — it
                            // clears the server queue without sending the CLI
                            // the control_response it's waiting for, causing a
                            // deadlock when parallel tool calls are in flight.
                            // Only persist supplementary metadata (tool count).
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
            let git_info = crate::domain::git::repo::resolve_git_info(&cwd).await;
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
                            changes: Box::new(orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
                                repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
                                is_worktree: if is_worktree { Some(true) } else { None },
                                ..Default::default()
                            }),
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
                    let serialized_input = tool_input
                        .as_ref()
                        .and_then(|value| serde_json::to_string(value).ok());

                    actor
                        .send(SessionCommand::SetLastTool {
                            tool: Some(tool_name.clone()),
                        })
                        .await;
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: Box::new(orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            }),
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
                            changes: Box::new(delta),
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
                            changes: Box::new(orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            }),
                            persist_op: None,
                        })
                        .await;
                }
                "PermissionRequest" => {
                    let permission_suggestions_count = permission_suggestions
                        .as_ref()
                        .and_then(|value| value.as_array())
                        .map_or(0, |items| items.len());
                    let serialized_input = tool_input
                        .as_ref()
                        .and_then(|value| serde_json::to_string(value).ok());
                    let (approval_type, work_status, attention_reason) =
                        classify_permission_request(&tool_name);
                    let request_id = claude_permission_request_id(
                        Some(&actor),
                        &tool_name,
                        tool_use_id.as_deref(),
                    );
                    let fallback_question = extract_question_from_tool_input(tool_input.as_ref());
                    let question_text = approval_question(
                        serialized_input.as_deref(),
                        fallback_question.as_deref(),
                    );
                    let question_prompts = approval_question_prompts(
                        serialized_input.as_deref(),
                        question_text.as_deref(),
                    );
                    let preview = approval_preview(ApprovalPreviewInput {
                        request_id: request_id.as_str(),
                        approval_type,
                        tool_name: Some(tool_name.as_str()),
                        tool_input: serialized_input.as_deref(),
                        command: None,
                        file_path: None,
                        diff: None,
                        question: question_text.as_deref(),
                        permission_reason: None,
                    });
                    let plan_text = extract_plan_from_tool_input(tool_input.as_ref());
                    let snapshot = actor.snapshot();
                    let is_duplicate_request = permission_request_matches_snapshot(
                        &snapshot,
                        &PermissionRequestSnapshotMatch {
                            request_id: request_id.as_str(),
                            tool_name: tool_name.as_str(),
                            tool_input: serialized_input.as_deref(),
                            question: question_text.as_deref(),
                            work_status,
                            permission_mode: permission_mode.as_deref(),
                            plan_text: plan_text.as_deref(),
                        },
                    );

                    if is_duplicate_request {
                        tracing::info!(
                            component = "hook_handler",
                            event = "claude.permission_request.duplicate_ignored",
                            session_id = %session_id,
                            request_id = %request_id,
                            tool_name = %tool_name,
                            ?approval_type,
                            permission_suggestions_count,
                            "Ignoring duplicate Claude permission request with unchanged effective state"
                        );
                    } else {
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
                                changes: Box::new(orbitdock_protocol::StateChanges {
                                    work_status: Some(work_status),
                                    current_plan: plan_text.clone().map(Some),
                                    last_activity_at: Some(chrono_now()),
                                    ..Default::default()
                                }),
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
                            .send(PersistCommand::ApprovalRequested(Box::new(
                                ApprovalRequestedParams {
                                    session_id: session_id.clone(),
                                    request_id: request_id.clone(),
                                    approval_type,
                                    tool_name: Some(tool_name.clone()),
                                    tool_input: serialized_input.clone(),
                                    command: None,
                                    file_path: None,
                                    diff: None,
                                    question: question_text.clone(),
                                    question_prompts,
                                    preview,
                                    permission_reason: None,
                                    requested_permissions: None,
                                    granted_permissions: None,
                                    cwd: None,
                                    proposed_amendment: None,
                                    permission_suggestions: permission_suggestions.clone(),
                                    elicitation_mode: None,
                                    elicitation_schema: None,
                                    elicitation_url: None,
                                    elicitation_message: None,
                                    mcp_server_name: None,
                                    network_host: None,
                                    network_protocol: None,
                                },
                            )))
                            .await;

                        if let Some(plan_text) = plan_text {
                            let _ = persist_tx
                                .send(PersistCommand::TurnStateUpdate {
                                    session_id: session_id.clone(),
                                    diff: None,
                                    plan: Some(plan_text),
                                })
                                .await;
                        }

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
                            publish_claude_subagent_update(
                                state,
                                &owning_id,
                                ClaudeSubagentUpdate::Started {
                                    agent_id: agent_id.clone(),
                                    agent_type: normalized_type.clone(),
                                },
                            )
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
                            let subagent_id = agent_id.clone();
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSubagentEnd {
                                    id: subagent_id.clone(),
                                    transcript_path: agent_transcript_path,
                                })
                                .await;
                            publish_claude_subagent_update(
                                state,
                                &owning_id,
                                ClaudeSubagentUpdate::Stopped {
                                    agent_id: subagent_id,
                                },
                            )
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
                    let git_info = crate::domain::git::repo::resolve_git_info(&pending_cwd).await;
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
                    publish_claude_subagent_update(
                        state,
                        &session_id,
                        ClaudeSubagentUpdate::Started {
                            agent_id: agent_id.clone(),
                            agent_type: normalized_type.clone(),
                        },
                    )
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
                    let subagent_id = agent_id.clone();
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSubagentEnd {
                            id: subagent_id.clone(),
                            transcript_path: agent_transcript_path,
                        })
                        .await;
                    publish_claude_subagent_update(
                        state,
                        &session_id,
                        ClaudeSubagentUpdate::Stopped {
                            agent_id: subagent_id,
                        },
                    )
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

enum ClaudeSubagentUpdate {
    Started {
        agent_id: String,
        agent_type: String,
    },
    Stopped {
        agent_id: String,
    },
}

async fn publish_claude_subagent_update(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    update: ClaudeSubagentUpdate,
) {
    let Some(actor) = state.get_session(session_id) else {
        return;
    };

    let current_subagents = actor
        .retained_state()
        .await
        .map(|session| session.subagents)
        .unwrap_or_default();

    let updated_subagents = apply_claude_subagent_update(current_subagents, update);
    actor
        .send(SessionCommand::SetSubagents {
            subagents: updated_subagents,
        })
        .await;
}

fn apply_claude_subagent_update(
    subagents: Vec<SubagentInfo>,
    update: ClaudeSubagentUpdate,
) -> Vec<SubagentInfo> {
    let now = chrono_now();

    match update {
        ClaudeSubagentUpdate::Started {
            agent_id,
            agent_type,
        } => {
            let mut updated = false;
            let mut next_subagents: Vec<SubagentInfo> = subagents
                .into_iter()
                .map(|mut subagent| {
                    if subagent.id == agent_id {
                        subagent.agent_type = agent_type.clone();
                        subagent.provider = Some(Provider::Claude);
                        subagent.status = SubagentStatus::Running;
                        subagent.ended_at = None;
                        subagent.last_activity_at = Some(now.clone());
                        updated = true;
                    }
                    subagent
                })
                .collect();

            if !updated {
                next_subagents.push(SubagentInfo {
                    id: agent_id,
                    agent_type,
                    started_at: now.clone(),
                    ended_at: None,
                    provider: Some(Provider::Claude),
                    label: None,
                    status: SubagentStatus::Running,
                    task_summary: None,
                    result_summary: None,
                    error_summary: None,
                    parent_subagent_id: None,
                    model: None,
                    last_activity_at: Some(now),
                });
            }

            next_subagents
        }
        ClaudeSubagentUpdate::Stopped { agent_id } => {
            let mut updated = false;
            let mut next_subagents: Vec<SubagentInfo> = subagents
                .into_iter()
                .map(|mut subagent| {
                    if subagent.id == agent_id {
                        subagent.provider = Some(Provider::Claude);
                        subagent.status = SubagentStatus::Completed;
                        subagent.ended_at = Some(now.clone());
                        subagent.last_activity_at = Some(now.clone());
                        updated = true;
                    }
                    subagent
                })
                .collect();

            if !updated {
                next_subagents.push(SubagentInfo {
                    id: agent_id,
                    agent_type: "unknown".to_string(),
                    started_at: now.clone(),
                    ended_at: Some(now.clone()),
                    provider: Some(Provider::Claude),
                    label: None,
                    status: SubagentStatus::Completed,
                    task_summary: None,
                    result_summary: None,
                    error_summary: None,
                    parent_subagent_id: None,
                    model: None,
                    last_activity_at: Some(now),
                });
            }

            next_subagents
        }
    }
}

#[cfg(test)]
mod tests {
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus, SessionSummary,
        SubagentInfo, SubagentStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
    };
    use serde_json::json;

    use super::{
        apply_claude_subagent_update, classify_permission_request, extract_plan_from_tool_input,
        extract_question_from_tool_input, is_codex_rollout_payload, ClaudeSubagentUpdate,
    };
    use crate::connectors::claude_hooks::session_materialization::most_recent_claude_session_id;
    use crate::support::session_time::chrono_now;

    fn session_summary(
        id: &str,
        provider: Provider,
        project_path: &str,
        last_activity_at: Option<&str>,
    ) -> SessionSummary {
        let display_title = SessionSummary::display_title_from_parts(
            None,
            None,
            None,
            Some("Project"),
            project_path,
        );
        SessionSummary {
            id: id.to_string(),
            provider,
            project_path: project_path.to_string(),
            transcript_path: None,
            project_name: Some("Project".to_string()),
            model: None,
            custom_name: None,
            summary: None,
            first_prompt: None,
            last_message: None,
            status: SessionStatus::Active,
            work_status: WorkStatus::Waiting,
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::default(),
            has_pending_approval: false,
            codex_integration_mode: Some(CodexIntegrationMode::Passive),
            claude_integration_mode: Some(ClaudeIntegrationMode::Passive),
            approval_policy: None,
            approval_policy_details: None,
            sandbox_mode: None,
            permission_mode: None,
            collaboration_mode: None,
            multi_agent: None,
            personality: None,
            service_tier: None,
            developer_instructions: None,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
            pending_tool_name: None,
            pending_tool_input: None,
            pending_question: None,
            pending_approval_id: None,
            started_at: Some(chrono_now()),
            last_activity_at: last_activity_at.map(str::to_string),
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            effort: None,
            approval_version: Some(0),
            summary_revision: 0,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            unread_count: 0,
            has_turn_diff: false,
            display_title,
            context_line: None,
            list_status: orbitdock_protocol::SessionListStatus::Reply,
            active_worker_count: 0,
            pending_tool_family: None,
            forked_from_session_id: None,
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
        }
    }

    #[test]
    fn permission_requests_map_to_expected_approval_and_attention_state() {
        let question = classify_permission_request("AskUserQuestion");
        let patch = classify_permission_request("Edit");
        let exec = classify_permission_request("Bash");

        assert_eq!(question.0, orbitdock_protocol::ApprovalType::Question);
        assert_eq!(question.1, WorkStatus::Question);
        assert_eq!(question.2, "awaitingQuestion");

        assert_eq!(patch.0, orbitdock_protocol::ApprovalType::Patch);
        assert_eq!(patch.1, WorkStatus::Permission);
        assert_eq!(patch.2, "awaitingPermission");

        assert_eq!(exec.0, orbitdock_protocol::ApprovalType::Exec);
        assert_eq!(exec.1, WorkStatus::Permission);
        assert_eq!(exec.2, "awaitingPermission");
    }

    #[test]
    fn question_extraction_prefers_direct_question_then_nested_questions() {
        let direct = json!({ "question": "Ship it?" });
        let nested = json!({ "questions": [{ "question": "Need approval?" }] });
        let empty = json!({ "questions": [{ "label": "missing" }] });

        assert_eq!(
            extract_question_from_tool_input(Some(&direct)),
            Some("Ship it?".to_string())
        );
        assert_eq!(
            extract_question_from_tool_input(Some(&nested)),
            Some("Need approval?".to_string())
        );
        assert_eq!(extract_question_from_tool_input(Some(&empty)), None);
    }

    #[test]
    fn plan_extraction_prefers_plan_and_trims_whitespace() {
        let direct = json!({ "plan": "  First do the safe thing.  " });
        let fallback = json!({ "current_plan": "Use the fallback plan" });
        let blank = json!({ "plan": "   " });

        assert_eq!(
            extract_plan_from_tool_input(Some(&direct)),
            Some("First do the safe thing.".to_string())
        );
        assert_eq!(
            extract_plan_from_tool_input(Some(&fallback)),
            Some("Use the fallback plan".to_string())
        );
        assert_eq!(extract_plan_from_tool_input(Some(&blank)), None);
    }

    #[test]
    fn codex_rollout_detection_uses_transcript_path_or_model_hint() {
        assert!(is_codex_rollout_payload(
            Some("/tmp/.codex/sessions/abc/rollout.jsonl"),
            None
        ));
        assert!(is_codex_rollout_payload(None, Some("codex-mini-latest")));
        assert!(is_codex_rollout_payload(None, Some("gpt-5")));
        assert!(!is_codex_rollout_payload(
            Some("/tmp/.claude/projects/demo/transcript.jsonl"),
            Some("claude-sonnet")
        ));
    }

    #[test]
    fn most_recent_claude_session_selector_ignores_other_projects_and_current_session() {
        let summaries = [
            session_summary(
                "current",
                Provider::Claude,
                "/repo",
                Some("2026-03-09T01:00:00Z"),
            ),
            session_summary(
                "older",
                Provider::Claude,
                "/repo",
                Some("2026-03-09T02:00:00Z"),
            ),
            session_summary(
                "latest",
                Provider::Claude,
                "/repo",
                Some("2026-03-09T03:00:00Z"),
            ),
            session_summary(
                "codex",
                Provider::Codex,
                "/repo",
                Some("2026-03-09T04:00:00Z"),
            ),
            session_summary(
                "other-project",
                Provider::Claude,
                "/else",
                Some("2026-03-09T05:00:00Z"),
            ),
        ];

        assert_eq!(
            most_recent_claude_session_id("current", "/repo", summaries.iter()),
            Some("latest".to_string())
        );
    }

    #[test]
    fn claude_subagent_start_creates_or_reactivates_running_worker() {
        let subagents = vec![SubagentInfo {
            id: "worker-1".to_string(),
            agent_type: "worker".to_string(),
            started_at: "2026-03-12T09:00:00Z".to_string(),
            ended_at: Some("2026-03-12T09:05:00Z".to_string()),
            provider: Some(Provider::Claude),
            label: Some("Existing".to_string()),
            status: SubagentStatus::Completed,
            task_summary: None,
            result_summary: Some("done".to_string()),
            error_summary: None,
            parent_subagent_id: None,
            model: None,
            last_activity_at: Some("2026-03-12T09:05:00Z".to_string()),
        }];

        let updated = apply_claude_subagent_update(
            subagents,
            ClaudeSubagentUpdate::Started {
                agent_id: "worker-1".to_string(),
                agent_type: "explorer".to_string(),
            },
        );

        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].agent_type, "explorer");
        assert_eq!(updated[0].status, SubagentStatus::Running);
        assert_eq!(updated[0].provider, Some(Provider::Claude));
        assert_eq!(updated[0].ended_at, None);
        assert!(updated[0].last_activity_at.is_some());
    }

    #[test]
    fn claude_subagent_stop_marks_worker_completed_even_if_start_was_missed() {
        let updated = apply_claude_subagent_update(
            vec![],
            ClaudeSubagentUpdate::Stopped {
                agent_id: "worker-2".to_string(),
            },
        );

        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].id, "worker-2");
        assert_eq!(updated[0].status, SubagentStatus::Completed);
        assert_eq!(updated[0].provider, Some(Provider::Claude));
        assert_eq!(updated[0].agent_type, "unknown");
        assert!(updated[0].ended_at.is_some());
    }
}
