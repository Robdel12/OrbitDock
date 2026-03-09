use super::*;
use tracing::{error, info, warn};

#[derive(Debug, Deserialize)]
pub struct RenameSessionRequest {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateSessionConfigRequest {
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
}

pub async fn rename_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RenameSessionRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let actor = state
        .get_session(&session_id)
        .ok_or_else(|| session_not_found_error(&session_id))?;

    let persist_op = Some(
        crate::domain::sessions::session_command::PersistOp::SetCustomName {
            session_id: session_id.clone(),
            name: body.name.clone(),
        },
    );
    let (reply_tx, _reply_rx) = oneshot::channel();
    actor
        .send(SessionCommand::SetCustomNameAndNotify {
            name: body.name,
            persist_op,
            reply: reply_tx,
        })
        .await;

    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn update_session_config(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<UpdateSessionConfigRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let actor = state
        .get_session(&session_id)
        .ok_or_else(|| session_not_found_error(&session_id))?;

    let changes = orbitdock_protocol::StateChanges {
        approval_policy: body.approval_policy.clone().map(Some),
        sandbox_mode: body.sandbox_mode.clone().map(Some),
        permission_mode: body.permission_mode.clone().map(Some),
        ..Default::default()
    };

    let persist_op = Some(
        crate::domain::sessions::session_command::PersistOp::SetSessionConfig {
            session_id: session_id.clone(),
            approval_policy: body.approval_policy,
            sandbox_mode: body.sandbox_mode,
            permission_mode: body.permission_mode.clone(),
        },
    );

    actor
        .send(SessionCommand::ApplyDelta {
            changes,
            persist_op,
        })
        .await;

    if let Some(ref pm) = body.permission_mode {
        if let Some(tx) = state.get_claude_action_tx(&session_id) {
            let _ = tx
                .send(ClaudeAction::SetPermissionMode { mode: pm.clone() })
                .await;
        }
    }

    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn end_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let actor = state.get_session(&session_id);

    let is_passive_rollout = if let Some(ref actor) = actor {
        let snap = actor.snapshot();
        snap.provider == orbitdock_protocol::Provider::Codex
            && (snap.codex_integration_mode
                == Some(orbitdock_protocol::CodexIntegrationMode::Passive)
                || (snap.codex_integration_mode
                    != Some(orbitdock_protocol::CodexIntegrationMode::Direct)
                    && snap.transcript_path.is_some()))
    } else {
        false
    };

    state.shell_service().cancel_session(&session_id);

    if !is_passive_rollout {
        if let Some(tx) = state.get_codex_action_tx(&session_id) {
            let _ = tx.send(CodexAction::EndSession).await;
        } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
            let _ = tx.send(ClaudeAction::EndSession).await;
        }
    }

    let _ = state
        .persist()
        .send(PersistCommand::SessionEnd {
            id: session_id.clone(),
            reason: "user_requested".to_string(),
        })
        .await;

    if is_passive_rollout {
        if let Some(actor) = actor {
            actor.send(SessionCommand::EndLocally).await;
        }
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id,
            reason: "user_requested".to_string(),
        });
    } else if state.remove_session(&session_id).is_some() {
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id,
            reason: "user_requested".to_string(),
        });
    }

    Ok(Json(AcceptedResponse { accepted: true }))
}

#[derive(Debug, Deserialize)]
pub struct CreateSessionRequest {
    pub provider: orbitdock_protocol::Provider,
    pub cwd: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub disallowed_tools: Vec<String>,
    #[serde(default)]
    pub effort: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateSessionResponse {
    pub session_id: String,
    pub session: SessionSummary,
}

pub async fn create_session(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CreateSessionRequest>,
) -> Result<Json<CreateSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

    let id = orbitdock_protocol::new_id();
    let project_name = body.cwd.split('/').next_back().map(String::from);
    let git_branch = crate::domain::git::repo::resolve_git_branch(&body.cwd).await;

    let mut handle = crate::domain::sessions::session::SessionHandle::new(
        id.clone(),
        body.provider,
        body.cwd.clone(),
    );
    handle.set_git_branch(git_branch.clone());

    if let Some(ref m) = body.model {
        handle.set_model(Some(m.clone()));
    }
    if let Some(ref effort_level) = body.effort {
        handle.set_effort(Some(effort_level.clone()));
    }

    if body.provider == Provider::Codex {
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        handle.set_config(body.approval_policy.clone(), body.sandbox_mode.clone());
    } else if body.provider == Provider::Claude {
        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    }

    let summary = handle.summary();

    let persist_tx = state.persist().clone();
    let _ = persist_tx
        .send(PersistCommand::SessionCreate {
            id: id.clone(),
            provider: body.provider,
            project_path: body.cwd.clone(),
            project_name,
            branch: git_branch,
            model: body.model.clone(),
            approval_policy: body.approval_policy.clone(),
            sandbox_mode: body.sandbox_mode.clone(),
            permission_mode: body.permission_mode.clone(),
            forked_from_session_id: None,
        })
        .await;
    if let Some(ref effort_name) = body.effort {
        let _ = persist_tx
            .send(PersistCommand::EffortUpdate {
                session_id: id.clone(),
                effort: Some(effort_name.clone()),
            })
            .await;
    }

    if body.provider == Provider::Codex {
        let session_id = id.clone();
        let cwd = body.cwd.clone();
        let model = body.model.clone();
        let approval = body.approval_policy.clone();
        let sandbox = body.sandbox_mode.clone();
        let state2 = state.clone();
        let persist_tx2 = persist_tx.clone();

        tokio::spawn(async move {
            let connector_timeout = std::time::Duration::from_secs(15);
            let task_sid = session_id.clone();
            let task_cwd = cwd.clone();
            let task_model = model.clone();
            let task_approval = approval.clone();
            let task_sandbox = sandbox.clone();

            let mut connector_task = tokio::spawn(async move {
                crate::connectors::codex_session::CodexSession::new(
                    task_sid,
                    &task_cwd,
                    task_model.as_deref(),
                    task_approval.as_deref(),
                    task_sandbox.as_deref(),
                )
                .await
            });

            let codex_start =
                match tokio::time::timeout(connector_timeout, &mut connector_task).await {
                    Ok(Ok(Ok(s))) => Ok(s),
                    Ok(Ok(Err(e))) => Err(e.to_string()),
                    Ok(Err(e)) => Err(format!("Connector task panicked: {}", e)),
                    Err(_) => {
                        connector_task.abort();
                        Err("Connector creation timed out".to_string())
                    }
                };

            match codex_start {
                Ok(codex_session) => {
                    let thread_id = codex_session.thread_id().to_string();
                    crate::domain::sessions::session_utils::claim_codex_thread_for_direct_session(
                        &state2,
                        &persist_tx2,
                        &session_id,
                        &thread_id,
                        "http_create_thread_cleanup",
                    )
                    .await;

                    handle.set_list_tx(state2.list_tx());
                    let (actor_handle, action_tx) =
                        crate::connectors::codex_session::start_event_loop(
                            codex_session,
                            handle,
                            persist_tx2,
                            state2.clone(),
                        );
                    state2.add_session_actor(actor_handle);
                    state2.set_codex_action_tx(&session_id, action_tx);
                    info!(
                        component = "session",
                        event = "session.create.http.codex_connected",
                        session_id = %session_id,
                        "HTTP: Codex connector started"
                    );
                }
                Err(error_message) => {
                    let _ = persist_tx2
                        .send(PersistCommand::SessionEnd {
                            id: session_id.clone(),
                            reason: "connector_failed".to_string(),
                        })
                        .await;
                    state2.broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: session_id.clone(),
                        reason: "connector_failed".into(),
                    });
                    error!(
                        component = "session",
                        event = "session.create.http.codex_failed",
                        session_id = %session_id,
                        error = %error_message,
                        "HTTP: Failed to start Codex session"
                    );
                }
            }
        });
    } else if body.provider == Provider::Claude {
        let session_id = id.clone();
        let cwd = body.cwd.clone();
        let model = body.model.clone();
        let permission_mode = body.permission_mode.clone();
        let allowed_tools = body.allowed_tools.clone();
        let disallowed_tools = body.disallowed_tools.clone();
        let effort = body.effort.clone();
        let state2 = state.clone();
        let persist_tx2 = persist_tx.clone();

        tokio::spawn(async move {
            match crate::connectors::claude_session::ClaudeSession::new(
                session_id.clone(),
                &cwd,
                model.as_deref(),
                None,
                permission_mode.as_deref(),
                &allowed_tools,
                &disallowed_tools,
                effort.as_deref(),
            )
            .await
            {
                Ok(claude_session) => {
                    handle.set_list_tx(state2.list_tx());
                    let (actor_handle, action_tx) =
                        crate::connectors::claude_session::start_event_loop(
                            claude_session,
                            handle,
                            persist_tx2,
                            state2.list_tx(),
                            state2.clone(),
                        );

                    if let Some(ref mode) = permission_mode {
                        let _ = actor_handle
                            .send(SessionCommand::ApplyDelta {
                                changes: orbitdock_protocol::StateChanges {
                                    permission_mode: Some(Some(mode.clone())),
                                    ..Default::default()
                                },
                                persist_op: None,
                            })
                            .await;
                    }

                    state2.add_session_actor(actor_handle);
                    state2.set_claude_action_tx(&session_id, action_tx.clone());
                    info!(
                        component = "session",
                        event = "session.create.http.claude_connected",
                        session_id = %session_id,
                        "HTTP: Claude connector started"
                    );

                    let watchdog_state = state2.clone();
                    let watchdog_sid = session_id.clone();
                    let watchdog_tx = action_tx;
                    let watchdog_persist = state2.persist().clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(45)).await;
                        if watchdog_state
                            .claude_sdk_id_for_session(&watchdog_sid)
                            .is_none()
                        {
                            warn!(
                                component = "session",
                                event = "session.init_timeout",
                                session_id = %watchdog_sid,
                                "Claude session never initialized after 45s — ending ghost"
                            );
                            let _ = watchdog_tx.send(ClaudeAction::EndSession).await;
                            let _ = watchdog_persist
                                .send(PersistCommand::SessionEnd {
                                    id: watchdog_sid.clone(),
                                    reason: "init_timeout".to_string(),
                                })
                                .await;
                            watchdog_state.remove_session(&watchdog_sid);
                            watchdog_state.broadcast_to_list(ServerMessage::SessionEnded {
                                session_id: watchdog_sid,
                                reason: "init_timeout".into(),
                            });
                        }
                    });
                }
                Err(e) => {
                    let _ = persist_tx2
                        .send(PersistCommand::SessionEnd {
                            id: session_id.clone(),
                            reason: "connector_failed".to_string(),
                        })
                        .await;
                    state2.broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: session_id.clone(),
                        reason: "connector_failed".into(),
                    });
                    error!(
                        component = "session",
                        event = "session.create.http.claude_failed",
                        session_id = %session_id,
                        error = %e,
                        "HTTP: Failed to start Claude session"
                    );
                }
            }
        });
    } else {
        state.add_session(handle);
    }

    state.broadcast_to_list(ServerMessage::SessionCreated {
        session: summary.clone(),
    });

    Ok(Json(CreateSessionResponse {
        session_id: id,
        session: summary,
    }))
}

#[derive(Debug, Serialize)]
pub struct ResumeSessionResponse {
    pub session_id: String,
    pub session: SessionSummary,
}

pub async fn resume_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<ResumeSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus,
    };

    if let Some(handle) = state.get_session(&session_id) {
        let snap = handle.snapshot();
        if snap.status == SessionStatus::Active {
            return Err((
                StatusCode::CONFLICT,
                Json(ApiErrorResponse {
                    code: "already_active",
                    error: format!("Session {} is already active", session_id),
                }),
            ));
        }
        state.remove_session(&session_id);
    }

    let mut restored =
        match crate::infrastructure::persistence::load_session_by_id(&session_id).await {
            Ok(Some(rs)) => rs,
            Ok(None) => return Err(session_not_found_error(&session_id)),
            Err(e) => {
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiErrorResponse {
                        code: "db_error",
                        error: e.to_string(),
                    }),
                ))
            }
        };

    let is_claude = restored.provider == "claude";
    let provider = if is_claude {
        Provider::Claude
    } else {
        Provider::Codex
    };

    if restored.messages.is_empty() {
        if let Some(ref tp) = restored.transcript_path {
            if let Ok(msgs) =
                crate::infrastructure::persistence::load_messages_from_transcript_path(
                    tp,
                    &session_id,
                )
                .await
            {
                if !msgs.is_empty() {
                    restored.messages = msgs;
                }
            }
        }
    }

    let mut handle = crate::domain::sessions::session::SessionHandle::restore(
        restored.id.clone(),
        provider,
        restored.project_path.clone(),
        restored.transcript_path.clone(),
        restored.project_name,
        restored.model.clone(),
        restored.custom_name,
        restored.summary,
        SessionStatus::Active,
        orbitdock_protocol::WorkStatus::Waiting,
        restored.approval_policy.clone(),
        restored.sandbox_mode.clone(),
        restored.permission_mode.clone(),
        orbitdock_protocol::TokenUsage {
            input_tokens: restored.input_tokens.max(0) as u64,
            output_tokens: restored.output_tokens.max(0) as u64,
            cached_tokens: restored.cached_tokens.max(0) as u64,
            context_window: restored.context_window.max(0) as u64,
        },
        restored.token_usage_snapshot_kind,
        restored.started_at,
        restored.last_activity_at,
        restored.messages,
        restored.current_diff,
        restored.current_plan,
        restored
            .turn_diffs
            .into_iter()
            .map(
                |(
                    turn_id,
                    diff,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    snapshot_kind,
                )| {
                    let has_tokens = input_tokens > 0 || output_tokens > 0 || context_window > 0;
                    orbitdock_protocol::TurnDiff {
                        turn_id,
                        diff,
                        token_usage: if has_tokens {
                            Some(orbitdock_protocol::TokenUsage {
                                input_tokens: input_tokens as u64,
                                output_tokens: output_tokens as u64,
                                cached_tokens: cached_tokens as u64,
                                context_window: context_window as u64,
                            })
                        } else {
                            None
                        },
                        snapshot_kind: Some(snapshot_kind),
                    }
                },
            )
            .collect(),
        restored.git_branch,
        restored.git_sha,
        restored.current_cwd,
        restored.first_prompt,
        restored.last_message,
        restored.pending_tool_name,
        restored.pending_tool_input,
        restored.pending_question,
        restored.pending_approval_id,
        restored.effort,
        restored.terminal_session_id,
        restored.terminal_app,
        restored.approval_version,
        restored.unread_count,
    );

    if is_claude {
        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    } else {
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    }

    let summary = handle.summary();

    state.broadcast_to_list(ServerMessage::SessionCreated {
        session: summary.clone(),
    });

    let persist_tx = state.persist().clone();
    let _ = persist_tx
        .send(PersistCommand::ReactivateSession {
            id: session_id.clone(),
        })
        .await;

    let session_id_for_response = session_id.clone();
    if is_claude {
        let project = if let Some(ref tp) = restored.transcript_path {
            crate::domain::sessions::session_utils::resolve_claude_resume_cwd(
                &restored.project_path,
                tp,
            )
        } else {
            restored.project_path.clone()
        };

        let provider_resume_id = restored
            .claude_sdk_session_id
            .clone()
            .and_then(orbitdock_protocol::ProviderSessionId::new);

        if provider_resume_id.is_none() {
            state.add_session(handle);
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(ApiErrorResponse {
                    code: "resume_failed",
                    error: "Cannot resume — no valid Claude SDK session ID was saved".to_string(),
                }),
            ));
        }
        let provider_resume_id = provider_resume_id.unwrap();
        state.register_claude_thread(&session_id, provider_resume_id.as_str());

        let sid = session_id.clone();
        let m = restored.model.clone();
        let restored_permission_mode =
            crate::infrastructure::persistence::load_session_permission_mode(&session_id)
                .await
                .unwrap_or(None);
        let pm = restored_permission_mode.clone();
        let resume_id = provider_resume_id.clone();
        let state2 = state.clone();
        let persist_tx2 = persist_tx.clone();

        tokio::spawn(async move {
            let connector_timeout = std::time::Duration::from_secs(15);
            let connector_task = tokio::spawn(async move {
                crate::connectors::claude_session::ClaudeSession::new(
                    sid.clone(),
                    &project,
                    m.as_deref(),
                    Some(&resume_id),
                    pm.as_deref(),
                    &[],
                    &[],
                    None,
                )
                .await
            });

            match tokio::time::timeout(connector_timeout, connector_task).await {
                Ok(Ok(Ok(claude_session))) => {
                    state2.register_claude_thread(&session_id, provider_resume_id.as_str());
                    handle.set_list_tx(state2.list_tx());
                    let (actor_handle, action_tx) =
                        crate::connectors::claude_session::start_event_loop(
                            claude_session,
                            handle,
                            persist_tx2.clone(),
                            state2.list_tx(),
                            state2.clone(),
                        );
                    state2.add_session_actor(actor_handle);
                    state2.set_claude_action_tx(&session_id, action_tx);

                    if let Some(ref mode) = restored_permission_mode {
                        if let Some(actor) = state2.get_session(&session_id) {
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes: orbitdock_protocol::StateChanges {
                                        permission_mode: Some(Some(mode.clone())),
                                        ..Default::default()
                                    },
                                    persist_op: None,
                                })
                                .await;
                        }
                    }

                    let _ = persist_tx2
                        .send(PersistCommand::SetIntegrationMode {
                            session_id: session_id.clone(),
                            codex_mode: None,
                            claude_mode: Some("direct".into()),
                        })
                        .await;

                    info!(
                        component = "session",
                        event = "session.resume.http.claude_connected",
                        session_id = %session_id,
                        "HTTP: Resumed Claude session"
                    );
                }
                Ok(Ok(Err(e))) => {
                    state2.add_session(handle);
                    error!(
                        component = "session",
                        event = "session.resume.http.claude_failed",
                        session_id = %session_id,
                        error = %e,
                        "HTTP: Failed to resume Claude connector"
                    );
                }
                Ok(Err(e)) => {
                    state2.add_session(handle);
                    error!(
                        component = "session",
                        event = "session.resume.http.claude_panicked",
                        session_id = %session_id,
                        error = %e,
                        "HTTP: Claude connector panicked"
                    );
                }
                Err(_) => {
                    state2.add_session(handle);
                    error!(
                        component = "session",
                        event = "session.resume.http.claude_timeout",
                        session_id = %session_id,
                        "HTTP: Claude connector timed out"
                    );
                }
            }
        });
    } else {
        let sid = session_id.clone();
        let project_path = restored.project_path.clone();
        let model = restored.model.clone();
        let approval = restored.approval_policy.clone();
        let sandbox = restored.sandbox_mode.clone();
        let state2 = state.clone();
        let persist_tx2 = persist_tx.clone();

        tokio::spawn(async move {
            let connector_timeout = std::time::Duration::from_secs(15);
            let task_sid = sid.clone();
            let task_pp = project_path.clone();
            let task_m = model.clone();
            let task_a = approval.clone();
            let task_s = sandbox.clone();

            let mut connector_task = tokio::spawn(async move {
                crate::connectors::codex_session::CodexSession::new(
                    task_sid,
                    &task_pp,
                    task_m.as_deref(),
                    task_a.as_deref(),
                    task_s.as_deref(),
                )
                .await
            });

            let codex_start =
                match tokio::time::timeout(connector_timeout, &mut connector_task).await {
                    Ok(Ok(Ok(s))) => Ok(s),
                    Ok(Ok(Err(e))) => Err(e.to_string()),
                    Ok(Err(e)) => Err(format!("Connector task panicked: {}", e)),
                    Err(_) => {
                        connector_task.abort();
                        Err("Connector creation timed out".to_string())
                    }
                };

            match codex_start {
                Ok(codex_session) => {
                    let thread_id = codex_session.thread_id().to_string();
                    crate::domain::sessions::session_utils::claim_codex_thread_for_direct_session(
                        &state2,
                        &persist_tx2,
                        &sid,
                        &thread_id,
                        "http_resume_thread_cleanup",
                    )
                    .await;

                    handle.set_list_tx(state2.list_tx());
                    let (actor_handle, action_tx) =
                        crate::connectors::codex_session::start_event_loop(
                            codex_session,
                            handle,
                            persist_tx2,
                            state2.clone(),
                        );
                    state2.add_session_actor(actor_handle);
                    state2.set_codex_action_tx(&sid, action_tx);
                    info!(
                        component = "session",
                        event = "session.resume.http.codex_connected",
                        session_id = %sid,
                        "HTTP: Resumed Codex session"
                    );
                }
                Err(e) => {
                    state2.add_session(handle);
                    error!(
                        component = "session",
                        event = "session.resume.http.codex_failed",
                        session_id = %sid,
                        error = %e,
                        "HTTP: Failed to resume Codex connector"
                    );
                }
            }
        });
    }

    Ok(Json(ResumeSessionResponse {
        session_id: session_id_for_response,
        session: summary,
    }))
}

#[derive(Debug, Deserialize)]
pub struct TakeoverSessionRequest {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub disallowed_tools: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct TakeoverSessionResponse {
    pub session_id: String,
    pub accepted: bool,
}

pub async fn takeover_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<TakeoverSessionRequest>,
) -> Result<Json<TakeoverSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

    let actor = match state.get_session(&session_id) {
        Some(a) => a,
        None => return Err(session_not_found_error(&session_id)),
    };

    let snap = actor.snapshot();

    let is_passive = match snap.provider {
        Provider::Codex => {
            snap.codex_integration_mode == Some(CodexIntegrationMode::Passive)
                || (snap.codex_integration_mode.is_none() && snap.transcript_path.is_some())
        }
        Provider::Claude => snap.claude_integration_mode != Some(ClaudeIntegrationMode::Direct),
    };

    if !is_passive {
        return Err((
            StatusCode::CONFLICT,
            Json(ApiErrorResponse {
                code: "not_passive",
                error: format!(
                    "Session {} is not a passive session — cannot take over",
                    session_id
                ),
            }),
        ));
    }

    let (take_tx, take_rx) = tokio::sync::oneshot::channel();
    actor
        .send(SessionCommand::TakeHandle { reply: take_tx })
        .await;

    let mut handle = match take_rx.await {
        Ok(h) => h,
        Err(_) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "take_failed",
                    error: "Failed to take handle from passive session actor".to_string(),
                }),
            ))
        }
    };

    handle.set_list_tx(state.list_tx());

    if handle.messages().is_empty() {
        if let Some(ref tp) = snap.transcript_path {
            if let Ok(msgs) =
                crate::infrastructure::persistence::load_messages_from_transcript_path(
                    tp,
                    &session_id,
                )
                .await
            {
                if !msgs.is_empty() {
                    for msg in msgs {
                        handle.add_message(msg);
                    }
                }
            }
        }
    }

    if snap.status == orbitdock_protocol::SessionStatus::Ended {
        let _ = state
            .persist()
            .send(PersistCommand::ReactivateSession {
                id: session_id.clone(),
            })
            .await;
    }

    let persist_tx = state.persist().clone();
    let (turn_context_model, turn_context_effort) = if snap.provider == Provider::Codex {
        if let Some(ref transcript_path) = snap.transcript_path {
            crate::infrastructure::persistence::load_latest_codex_turn_context_settings_from_transcript_path(
                transcript_path,
            )
            .await
            .unwrap_or((None, None))
        } else {
            (None, None)
        }
    } else {
        (None, None)
    };

    let effective_model = body
        .model
        .or(turn_context_model)
        .or_else(|| snap.model.clone());
    let effective_effort = snap.effort.clone().or(turn_context_effort);
    let effective_approval = body.approval_policy.or(snap.approval_policy.clone());
    let effective_sandbox = body.sandbox_mode.or(snap.sandbox_mode.clone());
    let requested_permission_mode = body.permission_mode.clone();
    let stored_permission_mode =
        if snap.provider == Provider::Claude && requested_permission_mode.is_none() {
            crate::infrastructure::persistence::load_session_permission_mode(&session_id)
                .await
                .unwrap_or(None)
        } else {
            None
        };
    let effective_permission = requested_permission_mode.clone().or(stored_permission_mode);
    let connector_timeout = std::time::Duration::from_secs(15);

    if snap.provider == Provider::Codex {
        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        if let Some(ref m) = effective_model {
            handle.set_model(Some(m.clone()));
        }
        handle.set_config(effective_approval.clone(), effective_sandbox.clone());

        let thread_id = state.codex_thread_for_session(&session_id);
        let sid = session_id.clone();
        let project = snap.project_path.clone();
        let m = effective_model.clone();
        let ap = effective_approval.clone();
        let sb = effective_sandbox.clone();

        let mut connector_task = tokio::spawn(async move {
            if let Some(ref tid) = thread_id {
                match crate::connectors::codex_session::CodexSession::resume(
                    sid.clone(),
                    &project,
                    tid,
                    m.as_deref(),
                    ap.as_deref(),
                    sb.as_deref(),
                )
                .await
                {
                    Ok(codex) => Ok(codex),
                    Err(_) => {
                        crate::connectors::codex_session::CodexSession::new(
                            sid.clone(),
                            &project,
                            m.as_deref(),
                            ap.as_deref(),
                            sb.as_deref(),
                        )
                        .await
                    }
                }
            } else {
                crate::connectors::codex_session::CodexSession::new(
                    sid.clone(),
                    &project,
                    m.as_deref(),
                    ap.as_deref(),
                    sb.as_deref(),
                )
                .await
            }
        });

        match tokio::time::timeout(connector_timeout, &mut connector_task).await {
            Ok(Ok(Ok(codex))) => {
                let new_thread_id = codex.thread_id().to_string();
                crate::domain::sessions::session_utils::claim_codex_thread_for_direct_session(
                    &state,
                    &persist_tx,
                    &session_id,
                    &new_thread_id,
                    "http_takeover_thread_cleanup",
                )
                .await;

                let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
                    codex,
                    handle,
                    persist_tx.clone(),
                    state.clone(),
                );
                state.add_session_actor(actor_handle);
                state.set_codex_action_tx(&session_id, action_tx);

                if let Some(ref model_name) = effective_model {
                    let _ = persist_tx
                        .send(PersistCommand::ModelUpdate {
                            session_id: session_id.clone(),
                            model: model_name.clone(),
                        })
                        .await;
                }
                if let Some(ref effort_name) = effective_effort {
                    let _ = persist_tx
                        .send(PersistCommand::EffortUpdate {
                            session_id: session_id.clone(),
                            effort: Some(effort_name.clone()),
                        })
                        .await;
                }

                if let Some(actor) = state.get_session(&session_id) {
                    let mut changes =
                        crate::domain::sessions::session_utils::direct_mode_activation_changes(
                            Provider::Codex,
                        );
                    if let Some(ref effort_name) = effective_effort {
                        changes.effort = Some(Some(effort_name.clone()));
                    }
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes,
                            persist_op: None,
                        })
                        .await;
                }

                let _ = persist_tx
                    .send(PersistCommand::SetIntegrationMode {
                        session_id: session_id.clone(),
                        codex_mode: Some("direct".into()),
                        claude_mode: None,
                    })
                    .await;
            }
            _ => {
                connector_task.abort();
                handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
                state.add_session(handle);
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiErrorResponse {
                        code: "connector_failed",
                        error: "Codex takeover connector failed or timed out".to_string(),
                    }),
                ));
            }
        }
    } else {
        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
        if let Some(ref m) = effective_model {
            handle.set_model(Some(m.clone()));
        }

        let sid = session_id.clone();
        let project = if let Some(ref tp) = snap.transcript_path {
            crate::domain::sessions::session_utils::resolve_claude_resume_cwd(
                &snap.project_path,
                tp,
            )
        } else {
            snap.project_path.clone()
        };
        let m = effective_model.clone();
        let pm = effective_permission.clone();
        let at = body.allowed_tools.clone();
        let dt = body.disallowed_tools.clone();

        let takeover_sdk_id = state
            .claude_sdk_id_for_session(&session_id)
            .and_then(orbitdock_protocol::ProviderSessionId::new);

        let takeover_sdk_id_for_spawn = takeover_sdk_id.clone();
        let connector_task = tokio::spawn(async move {
            crate::connectors::claude_session::ClaudeSession::new(
                sid.clone(),
                &project,
                m.as_deref(),
                takeover_sdk_id_for_spawn.as_ref(),
                pm.as_deref(),
                &at,
                &dt,
                None,
            )
            .await
        });

        match tokio::time::timeout(connector_timeout, connector_task).await {
            Ok(Ok(Ok(claude_session))) => {
                if let Some(ref sdk_id) = takeover_sdk_id {
                    state.register_claude_thread(&session_id, sdk_id.as_str());
                }

                let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
                    claude_session,
                    handle,
                    persist_tx.clone(),
                    state.list_tx(),
                    state.clone(),
                );
                state.add_session_actor(actor_handle);
                state.set_claude_action_tx(&session_id, action_tx);

                if let Some(ref mode) = effective_permission {
                    if let Some(actor) = state.get_session(&session_id) {
                        actor
                            .send(SessionCommand::ApplyDelta {
                                changes: orbitdock_protocol::StateChanges {
                                    permission_mode: Some(Some(mode.clone())),
                                    ..Default::default()
                                },
                                persist_op: if requested_permission_mode.is_some() {
                                    Some(crate::domain::sessions::session_command::PersistOp::SetSessionConfig {
                                        session_id: session_id.clone(),
                                        approval_policy: None,
                                        sandbox_mode: None,
                                        permission_mode: Some(mode.clone()),
                                    })
                                } else {
                                    None
                                },
                            })
                            .await;
                    }
                }

                if let Some(actor) = state.get_session(&session_id) {
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: crate::domain::sessions::session_utils::direct_mode_activation_changes(
                                Provider::Claude,
                            ),
                            persist_op: None,
                        })
                        .await;
                }

                let _ = persist_tx
                    .send(PersistCommand::SetIntegrationMode {
                        session_id: session_id.clone(),
                        codex_mode: None,
                        claude_mode: Some("direct".into()),
                    })
                    .await;
            }
            _ => {
                handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
                state.add_session(handle);
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiErrorResponse {
                        code: "connector_failed",
                        error: "Claude takeover connector failed or timed out".to_string(),
                    }),
                ));
            }
        }
    }

    if let Some(actor) = state.get_session(&session_id) {
        let (sum_tx, sum_rx) = tokio::sync::oneshot::channel();
        actor
            .send(SessionCommand::GetSummary { reply: sum_tx })
            .await;
        if let Ok(summary) = sum_rx.await {
            state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
        }
    }

    Ok(Json(TakeoverSessionResponse {
        session_id,
        accepted: true,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ForkSessionRequest {
    #[serde(default)]
    pub nth_user_message: Option<u32>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub disallowed_tools: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ForkSessionResponse {
    pub source_session_id: String,
    pub new_session_id: String,
    pub session: SessionSummary,
}

pub async fn fork_session(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkSessionRequest>,
) -> Result<Json<ForkSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};

    let source_snapshot = match state.get_session(&source_session_id) {
        Some(s) => s.snapshot(),
        None => return Err(session_not_found_error(&source_session_id)),
    };

    let source_provider = source_snapshot.provider;
    let source_cwd = source_snapshot.project_path.clone();
    let source_model = body.model.clone().or_else(|| source_snapshot.model.clone());
    let source_approval = source_snapshot.approval_policy.clone();
    let source_sandbox = source_snapshot.sandbox_mode.clone();
    let effective_approval = body.approval_policy.clone().or(source_approval);
    let effective_sandbox = body.sandbox_mode.clone().or(source_sandbox);
    let effective_cwd = body.cwd.clone().unwrap_or_else(|| source_cwd.clone());
    let project_name = effective_cwd.split('/').next_back().map(String::from);
    let fork_branch = crate::domain::git::repo::resolve_git_branch(&effective_cwd).await;

    match source_provider {
        Provider::Claude => {
            let new_id = orbitdock_protocol::new_id();
            match crate::connectors::claude_session::ClaudeSession::new(
                new_id.clone(),
                &effective_cwd,
                source_model.as_deref(),
                None,
                body.permission_mode.as_deref(),
                &body.allowed_tools,
                &body.disallowed_tools,
                None,
            )
            .await
            {
                Ok(claude_session) => {
                    let mut handle = crate::domain::sessions::session::SessionHandle::new(
                        new_id.clone(),
                        Provider::Claude,
                        effective_cwd.clone(),
                    );
                    handle.set_git_branch(fork_branch.clone());
                    handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
                    handle.set_forked_from(source_session_id.clone());
                    if let Some(ref m) = source_model {
                        handle.set_model(Some(m.clone()));
                    }

                    let summary = handle.summary();

                    let persist_tx = state.persist().clone();
                    let _ = persist_tx
                        .send(PersistCommand::SessionCreate {
                            id: new_id.clone(),
                            provider: Provider::Claude,
                            project_path: effective_cwd,
                            project_name,
                            branch: fork_branch,
                            model: source_model,
                            approval_policy: None,
                            sandbox_mode: None,
                            permission_mode: body.permission_mode.clone(),
                            forked_from_session_id: Some(source_session_id.clone()),
                        })
                        .await;

                    handle.set_list_tx(state.list_tx());
                    let (actor_handle, action_tx) =
                        crate::connectors::claude_session::start_event_loop(
                            claude_session,
                            handle,
                            persist_tx,
                            state.list_tx(),
                            state.clone(),
                        );
                    state.add_session_actor(actor_handle);
                    state.set_claude_action_tx(&new_id, action_tx);

                    state.broadcast_to_list(ServerMessage::SessionCreated {
                        session: summary.clone(),
                    });

                    Ok(Json(ForkSessionResponse {
                        source_session_id,
                        new_session_id: new_id,
                        session: summary,
                    }))
                }
                Err(e) => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiErrorResponse {
                        code: "fork_failed",
                        error: e.to_string(),
                    }),
                )),
            }
        }

        Provider::Codex => {
            let source_action_tx = match state.get_codex_action_tx(&source_session_id) {
                Some(tx) => tx,
                None => {
                    return Err((
                        StatusCode::UNPROCESSABLE_ENTITY,
                        Json(ApiErrorResponse {
                            code: "not_found",
                            error: format!(
                                "Source session {} has no active Codex connector",
                                source_session_id
                            ),
                        }),
                    ))
                }
            };

            let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
            let cwd_for_fork = body.cwd.clone().or_else(|| Some(source_cwd.clone()));

            if source_action_tx
                .send(crate::connectors::codex_session::CodexAction::ForkSession {
                    source_session_id: source_session_id.clone(),
                    nth_user_message: body.nth_user_message,
                    model: body.model.clone(),
                    approval_policy: effective_approval.clone(),
                    sandbox_mode: effective_sandbox.clone(),
                    cwd: cwd_for_fork.clone(),
                    reply_tx,
                })
                .await
                .is_err()
            {
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(ApiErrorResponse {
                        code: "channel_closed",
                        error: "Source session's action channel is closed".to_string(),
                    }),
                ));
            }

            let fork_result = match reply_rx.await {
                Ok(result) => result,
                Err(_) => {
                    return Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiErrorResponse {
                            code: "fork_failed",
                            error: "Fork operation was cancelled".to_string(),
                        }),
                    ))
                }
            };

            let (new_connector, new_thread_id) = match fork_result {
                Ok(result) => result,
                Err(e) => {
                    return Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ApiErrorResponse {
                            code: "fork_failed",
                            error: e.to_string(),
                        }),
                    ))
                }
            };

            let new_id = orbitdock_protocol::new_id();
            let fork_cwd = cwd_for_fork.unwrap_or_else(|| ".".to_string());
            let fork_project_name = fork_cwd.split('/').next_back().map(String::from);
            let fork_branch2 = crate::domain::git::repo::resolve_git_branch(&fork_cwd).await;

            let mut handle = crate::domain::sessions::session::SessionHandle::new(
                new_id.clone(),
                Provider::Codex,
                fork_cwd.clone(),
            );
            handle.set_git_branch(fork_branch2.clone());
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
            handle.set_config(effective_approval.clone(), effective_sandbox.clone());
            handle.set_forked_from(source_session_id.clone());

            let source_fork_messages = if let Some(source_actor) =
                state.get_session(&source_session_id)
            {
                let (state_tx, state_rx) = tokio::sync::oneshot::channel();
                source_actor
                    .send(SessionCommand::GetRetainedState { reply: state_tx })
                    .await;

                match state_rx.await {
                    Ok(source_state) => {
                        let full_source_messages =
                            crate::domain::sessions::session_utils::hydrate_full_message_history(
                                &source_session_id,
                                source_state.messages,
                                source_state.total_message_count,
                            )
                            .await;
                        crate::transport::websocket::handlers::session_crud::remap_messages_for_fork(
                            crate::transport::websocket::handlers::session_crud::truncate_messages_before_nth_user_message(
                                &full_source_messages,
                                body.nth_user_message,
                            ),
                            &new_id,
                        )
                    }
                    Err(_) => Vec::new(),
                }
            } else {
                Vec::new()
            };

            let rollout_messages = if let Some(rollout_path) = new_connector.rollout_path().await {
                crate::infrastructure::persistence::load_messages_from_transcript_path(
                    &rollout_path,
                    &new_id,
                )
                .await
                .unwrap_or_default()
            } else {
                Vec::new()
            };

            let forked_messages = if source_fork_messages.len() >= rollout_messages.len() {
                source_fork_messages
            } else {
                rollout_messages
            };

            if !forked_messages.is_empty() {
                handle.replace_messages(forked_messages.clone());
            }

            let summary = handle.summary();
            let persist_tx = state.persist().clone();

            let _ = persist_tx
                .send(PersistCommand::SessionCreate {
                    id: new_id.clone(),
                    provider: Provider::Codex,
                    project_path: fork_cwd,
                    project_name: fork_project_name,
                    branch: fork_branch2,
                    model: body.model,
                    approval_policy: effective_approval,
                    sandbox_mode: effective_sandbox,
                    permission_mode: None,
                    forked_from_session_id: Some(source_session_id.clone()),
                })
                .await;

            for msg in forked_messages {
                let _ = persist_tx
                    .send(PersistCommand::MessageAppend {
                        session_id: new_id.clone(),
                        message: msg,
                    })
                    .await;
            }

            crate::domain::sessions::session_utils::claim_codex_thread_for_direct_session(
                &state,
                &persist_tx,
                &new_id,
                &new_thread_id,
                "http_fork_thread_cleanup",
            )
            .await;

            let codex_session = crate::connectors::codex_session::CodexSession {
                session_id: new_id.clone(),
                connector: new_connector,
            };
            handle.set_list_tx(state.list_tx());
            let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
                codex_session,
                handle,
                persist_tx,
                state.clone(),
            );
            state.add_session_actor(actor_handle);
            state.set_codex_action_tx(&new_id, action_tx);

            state.broadcast_to_list(ServerMessage::SessionCreated {
                session: summary.clone(),
            });

            Ok(Json(ForkSessionResponse {
                source_session_id,
                new_session_id: new_id,
                session: summary,
            }))
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct ForkToWorktreeRequest {
    pub branch_name: String,
    #[serde(default)]
    pub base_branch: Option<String>,
    #[serde(default)]
    pub nth_user_message: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct ForkToWorktreeResponse {
    pub source_session_id: String,
    pub new_session_id: String,
    pub session: SessionSummary,
    pub worktree: orbitdock_protocol::WorktreeSummary,
}

pub async fn fork_session_to_worktree(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkToWorktreeRequest>,
) -> Result<Json<ForkToWorktreeResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let trimmed_branch = body.branch_name.trim().to_string();
    if trimmed_branch.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_input",
                error: "Branch name is required".to_string(),
            }),
        ));
    }

    let source_snapshot = match state.get_session(&source_session_id) {
        Some(s) => s.snapshot(),
        None => return Err(session_not_found_error(&source_session_id)),
    };

    let repo_root = if let Some(root) = source_snapshot
        .repository_root
        .clone()
        .map(|r| r.trim().to_string())
        .filter(|r| !r.is_empty())
    {
        root
    } else if let Some(git_info) =
        crate::domain::git::repo::resolve_git_info(&source_snapshot.project_path).await
    {
        git_info.common_dir_root
    } else {
        source_snapshot.project_path.clone()
    };

    let worktree_summary = match crate::domain::worktrees::service::create_tracked_worktree(
        &state,
        &repo_root,
        &trimmed_branch,
        body.base_branch.as_deref(),
        orbitdock_protocol::WorktreeOrigin::User,
    )
    .await
    {
        Ok(summary) => summary,
        Err(err) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "worktree_create_failed",
                    error: err,
                }),
            ))
        }
    };

    let fork_worktree_path = worktree_summary.worktree_path.clone();

    state.broadcast_to_list(ServerMessage::WorktreeCreated {
        request_id: String::new(),
        repo_root: worktree_summary.repo_root.clone(),
        worktree_revision: revision_now(),
        worktree: worktree_summary.clone(),
    });

    let fork_result = fork_session(
        Path(source_session_id.clone()),
        State(state),
        Json(ForkSessionRequest {
            nth_user_message: body.nth_user_message,
            model: None,
            approval_policy: None,
            sandbox_mode: None,
            cwd: Some(fork_worktree_path),
            permission_mode: None,
            allowed_tools: Vec::new(),
            disallowed_tools: Vec::new(),
        }),
    )
    .await?;

    Ok(Json(ForkToWorktreeResponse {
        source_session_id: fork_result.source_session_id.clone(),
        new_session_id: fork_result.new_session_id.clone(),
        session: fork_result.session.clone(),
        worktree: worktree_summary,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ForkToExistingWorktreeRequest {
    pub worktree_id: String,
    #[serde(default)]
    pub nth_user_message: Option<u32>,
}

pub async fn fork_session_to_existing_worktree(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkToExistingWorktreeRequest>,
) -> Result<Json<ForkSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let source_snapshot = match state.get_session(&source_session_id) {
        Some(s) => s.snapshot(),
        None => return Err(session_not_found_error(&source_session_id)),
    };

    let source_repo_root = if let Some(root) = source_snapshot
        .repository_root
        .clone()
        .map(|r| r.trim().trim_end_matches('/').to_string())
        .filter(|r| !r.is_empty())
    {
        root
    } else if let Some(git_info) =
        crate::domain::git::repo::resolve_git_info(&source_snapshot.project_path).await
    {
        git_info.common_dir_root.trim_end_matches('/').to_string()
    } else {
        source_snapshot
            .project_path
            .trim()
            .trim_end_matches('/')
            .to_string()
    };

    let target_worktree = match crate::infrastructure::persistence::load_worktree_by_id(
        state.db_path(),
        &body.worktree_id,
    ) {
        Some(row) => row,
        None => {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiErrorResponse {
                    code: "worktree_not_found",
                    error: format!("Worktree {} not found", body.worktree_id),
                }),
            ))
        }
    };

    if target_worktree.status == "removed" {
        return Err((
            StatusCode::GONE,
            Json(ApiErrorResponse {
                code: "worktree_not_found",
                error: "Selected worktree has been removed".to_string(),
            }),
        ));
    }

    let target_repo_root = target_worktree
        .repo_root
        .trim()
        .trim_end_matches('/')
        .to_string();
    if target_repo_root != source_repo_root {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "worktree_repo_mismatch",
                error: "Selected worktree belongs to a different repository".to_string(),
            }),
        ));
    }

    if !crate::domain::git::repo::worktree_exists_on_disk(&target_worktree.worktree_path).await {
        return Err((
            StatusCode::GONE,
            Json(ApiErrorResponse {
                code: "worktree_missing",
                error: "Selected worktree no longer exists on disk".to_string(),
            }),
        ));
    }

    fork_session(
        Path(source_session_id),
        State(state),
        Json(ForkSessionRequest {
            nth_user_message: body.nth_user_message,
            model: None,
            approval_policy: None,
            sandbox_mode: None,
            cwd: Some(target_worktree.worktree_path),
            permission_mode: None,
            allowed_tools: Vec::new(),
            disallowed_tools: Vec::new(),
        }),
    )
    .await
}
