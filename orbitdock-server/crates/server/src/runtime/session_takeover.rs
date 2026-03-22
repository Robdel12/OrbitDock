use std::sync::Arc;
use std::time::Duration;

use tokio::sync::oneshot;
use tracing::info;

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, ServerMessage, SessionListItem,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::connectors::codex_session::CodexSession;
use crate::domain::sessions::session::{SessionConfigPatch, SessionHandle};
use crate::infrastructure::persistence::{
    load_latest_codex_turn_context_settings_from_transcript_path,
    load_messages_from_transcript_path, load_session_permission_mode, PersistCommand,
};
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_lifecycle_policy::{plan_takeover_config, TakeoverConfigInputs};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
    claim_codex_thread_for_direct_session, direct_mode_activation_changes,
};
use crate::support::session_modes::is_takeover_eligible_passive_session;
use crate::support::session_paths::resolve_claude_resume_cwd;

#[derive(Debug, Clone)]
pub(crate) struct TakeoverSessionInputs {
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub allowed_tools: Vec<String>,
    pub disallowed_tools: Vec<String>,
}

pub(crate) enum TakeoverSessionError {
    NotFound(String),
    NotPassive(String),
    TakeHandleFailed,
    ConnectorFailed(String),
}

impl TakeoverSessionError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::NotFound(_) => "not_found",
            Self::NotPassive(_) => "not_passive",
            Self::TakeHandleFailed => "take_failed",
            Self::ConnectorFailed(_) => "connector_failed",
        }
    }

    pub(crate) fn message(&self) -> String {
        match self {
            Self::NotFound(session_id) => format!("Session {session_id} not found"),
            Self::NotPassive(session_id) => {
                format!("Session {session_id} is not a passive session — cannot take over")
            }
            Self::TakeHandleFailed => "Failed to take handle from passive session actor".into(),
            Self::ConnectorFailed(message) => message.clone(),
        }
    }
}

pub(crate) async fn takeover_passive_session(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    inputs: TakeoverSessionInputs,
) -> Result<(), TakeoverSessionError> {
    let actor = state
        .get_session(session_id)
        .ok_or_else(|| TakeoverSessionError::NotFound(session_id.to_string()))?;
    let snapshot = actor.snapshot();

    let is_passive = is_takeover_eligible_passive_session(
        snapshot.provider,
        snapshot.codex_integration_mode,
        snapshot.claude_integration_mode,
        snapshot.transcript_path.is_some(),
    );
    if !is_passive {
        return Err(TakeoverSessionError::NotPassive(session_id.to_string()));
    }

    let (take_tx, take_rx) = oneshot::channel();
    actor
        .send(SessionCommand::TakeHandle { reply: take_tx })
        .await;
    let mut handle = take_rx
        .await
        .map_err(|_| TakeoverSessionError::TakeHandleFailed)?;
    handle.set_list_tx(state.list_tx());

    hydrate_takeover_messages_if_needed(
        &mut handle,
        snapshot.transcript_path.as_deref(),
        session_id,
    )
    .await;

    if snapshot.status == orbitdock_protocol::SessionStatus::Ended {
        let _ = state
            .persist()
            .send(PersistCommand::ReactivateSession {
                id: session_id.to_string(),
            })
            .await;
    }

    let (turn_context_model, turn_context_effort) = load_codex_turn_context(&snapshot).await;
    let requested_permission_mode = inputs.permission_mode.clone();
    let stored_permission_mode =
        load_stored_takeover_permission_mode(state, session_id, snapshot.provider, &inputs).await;
    let takeover_plan = plan_takeover_config(TakeoverConfigInputs {
        provider: snapshot.provider,
        session_model: snapshot.model.clone(),
        session_effort: snapshot.effort.clone(),
        session_approval_policy: snapshot.approval_policy.clone(),
        session_sandbox_mode: snapshot.sandbox_mode.clone(),
        requested_model: inputs.model,
        requested_approval_policy: inputs.approval_policy,
        requested_sandbox_mode: inputs.sandbox_mode,
        requested_permission_mode,
        turn_context_model,
        turn_context_effort,
        stored_permission_mode,
    });

    match snapshot.provider {
        Provider::Codex => {
            complete_codex_takeover(
                state,
                CodexTakeoverRequest {
                    session_id: session_id.to_string(),
                    project_path: snapshot.project_path.clone(),
                    handle,
                    effective_model: takeover_plan.effective_model,
                    effective_effort: takeover_plan.effective_effort,
                    effective_approval: takeover_plan.effective_approval_policy,
                    effective_sandbox: takeover_plan.effective_sandbox_mode,
                    collaboration_mode: inputs.collaboration_mode,
                    multi_agent: inputs.multi_agent,
                    personality: inputs.personality,
                    service_tier: inputs.service_tier,
                    developer_instructions: inputs.developer_instructions,
                },
            )
            .await?;
        }
        Provider::Claude => {
            complete_claude_takeover(
                state,
                ClaudeTakeoverRequest {
                    session_id: session_id.to_string(),
                    project_path: snapshot.project_path.clone(),
                    transcript_path: snapshot.transcript_path.clone(),
                    handle,
                    effective_model: takeover_plan.effective_model,
                    effective_permission: takeover_plan.effective_permission_mode,
                    persist_permission_mode: takeover_plan.requested_permission_mode.is_some(),
                    allowed_tools: inputs.allowed_tools,
                    disallowed_tools: inputs.disallowed_tools,
                },
            )
            .await?;
        }
    }

    if let Some(actor) = state.get_session(session_id) {
        if let Ok(summary) = actor.summary().await {
            state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
                session: SessionListItem::from_summary(&summary),
            });
        }
    }

    Ok(())
}

async fn hydrate_takeover_messages_if_needed(
    handle: &mut SessionHandle,
    transcript_path: Option<&str>,
    session_id: &str,
) {
    if !handle.rows().is_empty() {
        return;
    }

    let Some(transcript_path) = transcript_path else {
        return;
    };

    if let Ok(rows) = load_messages_from_transcript_path(transcript_path, session_id).await {
        for entry in rows {
            handle.add_row(entry);
        }
    }
}

async fn load_codex_turn_context(
    snapshot: &crate::domain::sessions::session::SessionSnapshot,
) -> (Option<String>, Option<String>) {
    if snapshot.provider != Provider::Codex {
        return (None, None);
    }

    let Some(ref transcript_path) = snapshot.transcript_path else {
        return (None, None);
    };

    load_latest_codex_turn_context_settings_from_transcript_path(transcript_path)
        .await
        .unwrap_or((None, None))
}

async fn load_stored_takeover_permission_mode(
    _state: &Arc<SessionRegistry>,
    session_id: &str,
    provider: Provider,
    inputs: &TakeoverSessionInputs,
) -> Option<String> {
    if provider != Provider::Claude || inputs.permission_mode.is_some() {
        return None;
    }

    load_session_permission_mode(session_id)
        .await
        .unwrap_or(None)
}

async fn complete_codex_takeover(
    state: &Arc<SessionRegistry>,
    request: CodexTakeoverRequest,
) -> Result<(), TakeoverSessionError> {
    let CodexTakeoverRequest {
        session_id,
        project_path,
        mut handle,
        effective_model,
        effective_effort,
        effective_approval,
        effective_sandbox,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
    } = request;
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    if let Some(ref model) = effective_model {
        handle.set_model(Some(model.clone()));
    }
    handle.set_config(SessionConfigPatch {
        approval_policy: effective_approval.clone(),
        approval_policy_details: None,
        sandbox_mode: effective_sandbox.clone(),
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        model: effective_model.clone(),
        effort: effective_effort.clone(),
        codex_config_source: None,
        codex_config_overrides: None,
    });
    let control_plane = handle.summary();

    let thread_id = state.codex_thread_for_session(&session_id);
    let session_id = session_id.to_string();
    let model = effective_model.clone();
    let approval = effective_approval.clone();
    let sandbox = effective_sandbox.clone();
    let task_session_id = session_id.clone();
    let mut connector_task = tokio::spawn(async move {
        if let Some(ref thread_id) = thread_id {
            match CodexSession::resume_with_control_plane(
                task_session_id.clone(),
                &project_path,
                thread_id,
                model.as_deref(),
                approval.as_deref(),
                sandbox.as_deref(),
                orbitdock_connector_codex::CodexControlPlane {
                    collaboration_mode: control_plane.collaboration_mode.clone(),
                    multi_agent: control_plane.multi_agent,
                    personality: control_plane.personality.clone(),
                    service_tier: control_plane.service_tier.clone(),
                    developer_instructions: control_plane.developer_instructions.clone(),
                },
            )
            .await
            {
                Ok(codex) => Ok(codex),
                Err(_) => {
                    CodexSession::new_with_control_plane(
                        task_session_id.clone(),
                        &project_path,
                        model.as_deref(),
                        approval.as_deref(),
                        sandbox.as_deref(),
                        orbitdock_connector_codex::CodexControlPlane {
                            collaboration_mode: control_plane.collaboration_mode.clone(),
                            multi_agent: control_plane.multi_agent,
                            personality: control_plane.personality.clone(),
                            service_tier: control_plane.service_tier.clone(),
                            developer_instructions: control_plane.developer_instructions.clone(),
                        },
                    )
                    .await
                }
            }
        } else {
            CodexSession::new_with_control_plane(
                task_session_id.clone(),
                &project_path,
                model.as_deref(),
                approval.as_deref(),
                sandbox.as_deref(),
                orbitdock_connector_codex::CodexControlPlane {
                    collaboration_mode: control_plane.collaboration_mode.clone(),
                    multi_agent: control_plane.multi_agent,
                    personality: control_plane.personality.clone(),
                    service_tier: control_plane.service_tier.clone(),
                    developer_instructions: control_plane.developer_instructions.clone(),
                },
            )
            .await
        }
    });

    match tokio::time::timeout(Duration::from_secs(15), &mut connector_task).await {
        Ok(Ok(Ok(codex))) => {
            let persist_tx = state.persist().clone();
            let new_thread_id = codex.thread_id().to_string();
            claim_codex_thread_for_direct_session(
                state,
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
                let mut changes = direct_mode_activation_changes(Provider::Codex);
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

            info!(
                component = "session",
                event = "session.takeover.http.codex_connected",
                session_id = %session_id,
                "HTTP: Codex takeover connector started"
            );
            Ok(())
        }
        Ok(Ok(Err(error))) => {
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(error.to_string()))
        }
        Ok(Err(join_error)) => {
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(format!(
                "Connector task panicked: {join_error}"
            )))
        }
        Err(_) => {
            connector_task.abort();
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(
                "Codex takeover connector failed or timed out".into(),
            ))
        }
    }
}

struct CodexTakeoverRequest {
    session_id: String,
    project_path: String,
    handle: SessionHandle,
    effective_model: Option<String>,
    effective_effort: Option<String>,
    effective_approval: Option<String>,
    effective_sandbox: Option<String>,
    collaboration_mode: Option<String>,
    multi_agent: Option<bool>,
    personality: Option<String>,
    service_tier: Option<String>,
    developer_instructions: Option<String>,
}

async fn complete_claude_takeover(
    state: &Arc<SessionRegistry>,
    request: ClaudeTakeoverRequest,
) -> Result<(), TakeoverSessionError> {
    let ClaudeTakeoverRequest {
        session_id,
        project_path,
        transcript_path,
        mut handle,
        effective_model,
        effective_permission,
        persist_permission_mode,
        allowed_tools,
        disallowed_tools,
    } = request;
    handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
    if let Some(ref model) = effective_model {
        handle.set_model(Some(model.clone()));
    }

    let project = if let Some(ref transcript_path) = transcript_path {
        resolve_claude_resume_cwd(&project_path, transcript_path)
    } else {
        project_path
    };
    let takeover_sdk_id = state
        .claude_sdk_id_for_session(&session_id)
        .and_then(orbitdock_protocol::ProviderSessionId::new);
    let session_id = session_id.to_string();
    let model = effective_model.clone();
    let permission_mode = effective_permission.clone();
    let task_session_id = session_id.clone();
    let takeover_sdk_id_for_spawn = takeover_sdk_id.clone();
    let connector_task = tokio::spawn(async move {
        ClaudeSession::new(
            task_session_id.clone(),
            &project,
            model.as_deref(),
            takeover_sdk_id_for_spawn.as_ref(),
            permission_mode.as_deref(),
            &allowed_tools,
            &disallowed_tools,
            None,
            false,
        )
        .await
    });

    match tokio::time::timeout(Duration::from_secs(15), connector_task).await {
        Ok(Ok(Ok(claude_session))) => {
            if let Some(ref sdk_id) = takeover_sdk_id {
                state.register_claude_thread(&session_id, sdk_id.as_str());
            }

            let persist_tx = state.persist().clone();
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
                            persist_op: takeover_permission_persist_op(
                                &session_id,
                                persist_permission_mode,
                                Some(mode.clone()),
                            ),
                        })
                        .await;
                }
            }

            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: direct_mode_activation_changes(Provider::Claude),
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

            info!(
                component = "session",
                event = "session.takeover.http.claude_connected",
                session_id = %session_id,
                "HTTP: Claude takeover connector started"
            );
            Ok(())
        }
        Ok(Ok(Err(error))) => {
            handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(error.to_string()))
        }
        Ok(Err(join_error)) => {
            handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(format!(
                "Connector task panicked: {join_error}"
            )))
        }
        Err(_) => {
            handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
            state.add_session(handle);
            Err(TakeoverSessionError::ConnectorFailed(
                "Claude takeover connector failed or timed out".into(),
            ))
        }
    }
}

struct ClaudeTakeoverRequest {
    session_id: String,
    project_path: String,
    transcript_path: Option<String>,
    handle: SessionHandle,
    effective_model: Option<String>,
    effective_permission: Option<String>,
    persist_permission_mode: bool,
    allowed_tools: Vec<String>,
    disallowed_tools: Vec<String>,
}

fn takeover_permission_persist_op(
    session_id: &str,
    persist_permission_mode: bool,
    permission_mode: Option<String>,
) -> Option<PersistOp> {
    if !persist_permission_mode {
        return None;
    }

    permission_mode.map(|permission_mode| PersistOp::SetSessionConfig {
        session_id: session_id.to_string(),
        approval_policy: None,
        sandbox_mode: None,
        permission_mode: Some(Some(permission_mode)),
        collaboration_mode: None,
        multi_agent: None,
        personality: None,
        service_tier: None,
        developer_instructions: None,
        model: None,
        effort: None,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides_json: None,
    })
}
