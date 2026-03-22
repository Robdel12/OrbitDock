use std::sync::Arc;
use std::time::Duration;

use tracing::{error, info};

use orbitdock_protocol::{
    CodexConfigMode, CodexConfigSource, CodexSessionOverrides, Provider, ServerMessage,
    SessionListItem, SessionSummary,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::connectors::codex_session::CodexSession;
use crate::infrastructure::persistence::{load_session_permission_mode, PersistCommand};
use crate::runtime::codex_config::{resolve_codex_settings, CodexConfigSelection};
use crate::runtime::restored_sessions::PreparedResumeSession;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::claim_codex_thread_for_direct_session;
use crate::support::session_paths::resolve_claude_resume_cwd;

pub(crate) struct ResumeSessionLaunch {
    pub summary: SessionSummary,
}

pub(crate) enum ResumeSessionError {
    MissingClaudeResumeId,
}

impl ResumeSessionError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::MissingClaudeResumeId => "resume_failed",
        }
    }

    pub(crate) fn message(&self) -> String {
        match self {
            Self::MissingClaudeResumeId => {
                "Cannot resume — no valid Claude SDK session ID was saved".to_string()
            }
        }
    }
}

pub(crate) async fn launch_resumed_session(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    prepared: PreparedResumeSession,
) -> Result<ResumeSessionLaunch, ResumeSessionError> {
    if prepared.transcript_loaded {
        info!(
            component = "session",
            event = "session.resume.transcript_loaded",
            session_id = %session_id,
            message_count = prepared.row_count,
            "Loaded messages from transcript for resume"
        );
    }

    let session_id = session_id.to_string();
    let summary = prepared.summary.clone();
    state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
        session: SessionListItem::from_summary(&summary),
    });

    let persist_tx = state.persist().clone();
    let _ = persist_tx
        .send(PersistCommand::ReactivateSession {
            id: session_id.clone(),
        })
        .await;

    match prepared.provider {
        Provider::Claude => {
            let project = if let Some(ref transcript_path) = prepared.transcript_path {
                resolve_claude_resume_cwd(&prepared.project_path, transcript_path)
            } else {
                prepared.project_path.clone()
            };

            let Some(provider_resume_id) = prepared
                .claude_sdk_session_id
                .clone()
                .and_then(orbitdock_protocol::ProviderSessionId::new)
            else {
                state.add_session(prepared.handle);
                return Err(ResumeSessionError::MissingClaudeResumeId);
            };

            state.register_claude_thread(&session_id, provider_resume_id.as_str());
            spawn_claude_resume(
                state,
                ClaudeResumeParams {
                    session_id: session_id.clone(),
                    project,
                    model: prepared.model,
                    provider_resume_id,
                    handle: prepared.handle,
                    message_count: prepared.row_count,
                    allow_bypass_permissions: prepared.allow_bypass_permissions,
                },
            )
            .await;
        }
        Provider::Codex => {
            spawn_codex_resume(
                state,
                CodexResumeRequest {
                    session_id: session_id.clone(),
                    project_path: prepared.project_path,
                    model: prepared.model,
                    codex_thread_id: prepared.codex_thread_id,
                    approval_policy: prepared.approval_policy,
                    sandbox_mode: prepared.sandbox_mode,
                    collaboration_mode: prepared.collaboration_mode,
                    multi_agent: prepared.multi_agent,
                    personality: prepared.personality,
                    service_tier: prepared.service_tier,
                    developer_instructions: prepared.developer_instructions,
                    codex_config_mode: prepared.codex_config_mode,
                    codex_config_profile: prepared.codex_config_profile,
                    codex_model_provider: prepared.codex_model_provider,
                    codex_config_source: prepared.codex_config_source,
                    codex_config_overrides: prepared.codex_config_overrides,
                    handle: prepared.handle,
                    message_count: prepared.row_count,
                },
            )
            .await;
        }
    }

    Ok(ResumeSessionLaunch { summary })
}

struct ClaudeResumeParams {
    session_id: String,
    project: String,
    model: Option<String>,
    provider_resume_id: orbitdock_protocol::ProviderSessionId,
    handle: crate::domain::sessions::session::SessionHandle,
    message_count: usize,
    allow_bypass_permissions: bool,
}

async fn spawn_claude_resume(state: &Arc<SessionRegistry>, params: ClaudeResumeParams) {
    let ClaudeResumeParams {
        session_id,
        project,
        model,
        provider_resume_id,
        mut handle,
        message_count,
        allow_bypass_permissions,
    } = params;
    let persist_tx = state.persist().clone();
    let restored_permission_mode = load_session_permission_mode(&session_id)
        .await
        .unwrap_or(None);
    let state = state.clone();

    tokio::spawn(async move {
        let connector_timeout = Duration::from_secs(15);
        let sid = session_id.clone();
        let resume_id = provider_resume_id.clone();
        let permission_mode = restored_permission_mode.clone();
        let connector_task = tokio::spawn(async move {
            ClaudeSession::new(
                sid.clone(),
                &project,
                model.as_deref(),
                Some(&resume_id),
                permission_mode.as_deref(),
                &[],
                &[],
                None,
                allow_bypass_permissions,
            )
            .await
        });

        match tokio::time::timeout(connector_timeout, connector_task).await {
            Ok(Ok(Ok(claude_session))) => {
                state.register_claude_thread(&session_id, provider_resume_id.as_str());
                handle.set_list_tx(state.list_tx());
                let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
                    claude_session,
                    handle,
                    persist_tx.clone(),
                    state.list_tx(),
                    state.clone(),
                );
                state.add_session_actor(actor_handle);
                state.set_claude_action_tx(&session_id, action_tx);

                if let Some(ref mode) = restored_permission_mode {
                    if let Some(actor) = state.get_session(&session_id) {
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

                let _ = persist_tx
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
                    messages = message_count,
                    "HTTP: Resumed Claude session"
                );
            }
            Ok(Ok(Err(error))) => {
                state.add_session(handle);
                error!(
                    component = "session",
                    event = "session.resume.http.claude_failed",
                    session_id = %session_id,
                    error = %error,
                    "HTTP: Failed to resume Claude connector"
                );
            }
            Ok(Err(join_error)) => {
                state.add_session(handle);
                error!(
                    component = "session",
                    event = "session.resume.http.claude_panicked",
                    session_id = %session_id,
                    error = %join_error,
                    "HTTP: Claude connector panicked"
                );
            }
            Err(_) => {
                state.add_session(handle);
                error!(
                    component = "session",
                    event = "session.resume.http.claude_timeout",
                    session_id = %session_id,
                    "HTTP: Claude connector timed out"
                );
            }
        }
    });
}

async fn spawn_codex_resume(state: &Arc<SessionRegistry>, request: CodexResumeRequest) {
    let CodexResumeRequest {
        session_id,
        project_path,
        model,
        codex_thread_id,
        approval_policy,
        sandbox_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        codex_config_mode,
        codex_config_profile,
        codex_model_provider,
        codex_config_source,
        codex_config_overrides,
        mut handle,
        message_count,
    } = request;
    let session_id = session_id.to_string();
    let persist_tx = state.persist().clone();
    let state = state.clone();

    tokio::spawn(async move {
        let connector_timeout = Duration::from_secs(15);
        let task_session_id = session_id.clone();
        let mut connector_task = tokio::spawn(async move {
            let fallback_overrides = CodexSessionOverrides {
                model: model.clone(),
                model_provider: codex_model_provider.clone(),
                approval_policy: approval_policy.clone(),
                approval_policy_details: None,
                sandbox_mode: sandbox_mode.clone(),
                collaboration_mode: collaboration_mode.clone(),
                multi_agent,
                personality: personality.clone(),
                service_tier: service_tier.clone(),
                developer_instructions: developer_instructions.clone(),
                effort: None,
            };
            let resolved = resolve_codex_settings(
                &project_path,
                CodexConfigSelection {
                    config_source: codex_config_source.unwrap_or(CodexConfigSource::User),
                    config_mode: codex_config_mode.unwrap_or(CodexConfigMode::Inherit),
                    config_profile: codex_config_profile.clone(),
                    model_provider: codex_model_provider.clone(),
                    overrides: codex_config_overrides.unwrap_or(fallback_overrides),
                },
            )
            .await
            .ok();
            let effective = resolved
                .as_ref()
                .map(|resolved| &resolved.effective_settings);
            let control_plane = orbitdock_connector_codex::CodexControlPlane {
                collaboration_mode: effective
                    .and_then(|value| value.collaboration_mode.clone())
                    .or(collaboration_mode),
                multi_agent: effective
                    .and_then(|value| value.multi_agent)
                    .or(multi_agent),
                personality: effective
                    .and_then(|value| value.personality.clone())
                    .or(personality),
                service_tier: effective
                    .and_then(|value| value.service_tier.clone())
                    .or(service_tier),
                developer_instructions: effective
                    .and_then(|value| value.developer_instructions.clone())
                    .or(developer_instructions),
            };
            let effective_model = effective.and_then(|value| value.model.clone()).or(model);
            let effective_approval = effective
                .and_then(|value| value.approval_policy.clone())
                .or(approval_policy);
            let effective_sandbox = effective
                .and_then(|value| value.sandbox_mode.clone())
                .or(sandbox_mode);
            if let Some(thread_id) = codex_thread_id.as_deref() {
                match CodexSession::resume_with_config_overrides_and_control_plane(
                    task_session_id.clone(),
                    &project_path,
                    thread_id,
                    effective_model.as_deref(),
                    effective_approval.as_deref(),
                    effective_sandbox.as_deref(),
                    orbitdock_connector_codex::CodexConfigOverrides {
                        model_provider: effective.and_then(|value| value.model_provider.clone()),
                        config_profile: effective.and_then(|value| value.config_profile.clone()),
                    },
                    control_plane.clone(),
                )
                .await
                {
                    Ok(session) => Ok(session),
                    Err(_) => {
                        CodexSession::new_with_config_overrides_and_control_plane(
                            task_session_id,
                            &project_path,
                            effective_model.as_deref(),
                            effective_approval.as_deref(),
                            effective_sandbox.as_deref(),
                            orbitdock_connector_codex::CodexConfigOverrides {
                                model_provider: effective
                                    .and_then(|value| value.model_provider.clone()),
                                config_profile: effective
                                    .and_then(|value| value.config_profile.clone()),
                            },
                            control_plane,
                        )
                        .await
                    }
                }
            } else {
                CodexSession::new_with_config_overrides_and_control_plane(
                    task_session_id,
                    &project_path,
                    effective_model.as_deref(),
                    effective_approval.as_deref(),
                    effective_sandbox.as_deref(),
                    orbitdock_connector_codex::CodexConfigOverrides {
                        model_provider: effective.and_then(|value| value.model_provider.clone()),
                        config_profile: effective.and_then(|value| value.config_profile.clone()),
                    },
                    control_plane,
                )
                .await
            }
        });

        let codex_start = match tokio::time::timeout(connector_timeout, &mut connector_task).await {
            Ok(Ok(Ok(session))) => Ok(session),
            Ok(Ok(Err(error))) => Err(error.to_string()),
            Ok(Err(join_error)) => Err(format!("Connector task panicked: {join_error}")),
            Err(_) => {
                connector_task.abort();
                Err("Connector creation timed out".to_string())
            }
        };

        match codex_start {
            Ok(codex_session) => {
                let thread_id = codex_session.thread_id().to_string();
                claim_codex_thread_for_direct_session(
                    &state,
                    &persist_tx,
                    &session_id,
                    &thread_id,
                    "http_resume_thread_cleanup",
                )
                .await;

                handle.set_list_tx(state.list_tx());
                let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
                    codex_session,
                    handle,
                    persist_tx,
                    state.clone(),
                );
                state.add_session_actor(actor_handle);
                state.set_codex_action_tx(&session_id, action_tx);
                info!(
                    component = "session",
                    event = "session.resume.http.codex_connected",
                    session_id = %session_id,
                    messages = message_count,
                    "HTTP: Resumed Codex session"
                );
            }
            Err(error) => {
                state.add_session(handle);
                error!(
                    component = "session",
                    event = "session.resume.http.codex_failed",
                    session_id = %session_id,
                    error = %error,
                    "HTTP: Failed to resume Codex connector"
                );
            }
        }
    });
}

struct CodexResumeRequest {
    session_id: String,
    project_path: String,
    model: Option<String>,
    codex_thread_id: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    collaboration_mode: Option<String>,
    multi_agent: Option<bool>,
    personality: Option<String>,
    service_tier: Option<String>,
    developer_instructions: Option<String>,
    codex_config_mode: Option<CodexConfigMode>,
    codex_config_profile: Option<String>,
    codex_model_provider: Option<String>,
    codex_config_source: Option<CodexConfigSource>,
    codex_config_overrides: Option<CodexSessionOverrides>,
    handle: crate::domain::sessions::session::SessionHandle,
    message_count: usize,
}
