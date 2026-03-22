use std::sync::Arc;
use std::time::Duration;

use tracing::{info, warn};

use orbitdock_protocol::{
    CodexConfigMode, CodexConfigSource, CodexSessionOverrides, Provider, ServerMessage,
    SessionListItem, SessionStatus, StateChanges, WorkStatus,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::connectors::codex_session::CodexSession;
use crate::infrastructure::persistence::{load_session_by_id, PersistCommand};
use crate::runtime::codex_config::{resolve_codex_settings, CodexConfigSelection};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::claim_codex_thread_for_direct_session;
use crate::runtime::session_subscriptions::{
    prepare_subscribe_result, request_subscribe, PreparedSubscribeResult,
};
use crate::support::session_time::chrono_now;

pub(crate) async fn reactivate_passive_and_prepare_subscribe(
    state: &Arc<SessionRegistry>,
    actor: &SessionActorHandle,
    session_id: &str,
) -> Result<PreparedSubscribeResult, String> {
    let now = chrono_now();
    actor
        .send(SessionCommand::ApplyDelta {
            changes: StateChanges {
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(now),
                ..Default::default()
            },
            persist_op: Some(PersistOp::SessionUpdate {
                id: session_id.to_string(),
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(chrono_now()),
            }),
        })
        .await;

    let _ = state
        .persist()
        .send(PersistCommand::RolloutSessionUpdate {
            id: session_id.to_string(),
            project_path: None,
            model: None,
            status: Some(SessionStatus::Active),
            work_status: Some(WorkStatus::Waiting),
            attention_reason: Some(Some("awaitingReply".to_string())),
            pending_tool_name: Some(None),
            pending_tool_input: Some(None),
            pending_question: Some(None),
            total_tokens: None,
            last_tool: None,
            last_tool_at: None,
            custom_name: None,
        })
        .await;

    if let Ok(summary) = actor.summary().await {
        state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
            session: SessionListItem::from_summary(&summary),
        });
    }

    let result = request_subscribe(actor, None).await?;
    Ok(prepare_subscribe_result(result))
}

pub(crate) async fn start_lazy_connector_and_prepare_subscribe(
    state: &Arc<SessionRegistry>,
    actor: &SessionActorHandle,
    request: LazyConnectorStartRequest<'_>,
) -> Result<Option<PreparedSubscribeResult>, String> {
    let LazyConnectorStartRequest {
        session_id,
        provider,
        project_path,
        model,
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
    } = request;
    let (take_tx, take_rx) = tokio::sync::oneshot::channel();
    actor
        .send(SessionCommand::TakeHandle { reply: take_tx })
        .await;

    let Ok(mut handle) = take_rx.await else {
        return Ok(None);
    };

    handle.set_list_tx(state.list_tx());
    let persist_tx = state.persist().clone();
    let connector_timeout = Duration::from_secs(10);

    let connector_connected = match provider {
        Provider::Codex => {
            start_lazy_codex_connector(
                state,
                LazyCodexConnectorStart {
                    session_id,
                    project_path,
                    model,
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
                    handle,
                    persist_tx: persist_tx.clone(),
                    connector_timeout,
                },
            )
            .await
        }
        Provider::Claude => {
            start_lazy_claude_connector(
                state,
                session_id,
                project_path,
                model,
                handle,
                persist_tx.clone(),
                connector_timeout,
            )
            .await
        }
    };

    if let Some(new_actor) = state.get_session(session_id) {
        let result = request_subscribe(&new_actor, None).await?;
        return Ok(Some(prepare_subscribe_result(result)));
    }

    if connector_connected {
        return Err(format!(
            "session {} missing after lazy connector startup",
            session_id
        ));
    }

    Ok(None)
}

pub(crate) struct LazyConnectorStartRequest<'a> {
    pub session_id: &'a str,
    pub provider: Provider,
    pub project_path: &'a str,
    pub model: Option<&'a str>,
    pub approval_policy: Option<&'a str>,
    pub sandbox_mode: Option<&'a str>,
    pub collaboration_mode: Option<&'a str>,
    pub multi_agent: Option<bool>,
    pub personality: Option<&'a str>,
    pub service_tier: Option<&'a str>,
    pub developer_instructions: Option<&'a str>,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<&'a str>,
    pub codex_model_provider: Option<&'a str>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides: Option<&'a CodexSessionOverrides>,
}

struct LazyCodexConnectorStart<'a> {
    session_id: &'a str,
    project_path: &'a str,
    model: Option<&'a str>,
    approval_policy: Option<&'a str>,
    sandbox_mode: Option<&'a str>,
    collaboration_mode: Option<&'a str>,
    multi_agent: Option<bool>,
    personality: Option<&'a str>,
    service_tier: Option<&'a str>,
    developer_instructions: Option<&'a str>,
    codex_config_mode: Option<CodexConfigMode>,
    codex_config_profile: Option<&'a str>,
    codex_model_provider: Option<&'a str>,
    codex_config_source: Option<CodexConfigSource>,
    codex_config_overrides: Option<&'a CodexSessionOverrides>,
    handle: crate::domain::sessions::session::SessionHandle,
    persist_tx: tokio::sync::mpsc::Sender<PersistCommand>,
    connector_timeout: Duration,
}

async fn start_lazy_codex_connector(
    state: &Arc<SessionRegistry>,
    request: LazyCodexConnectorStart<'_>,
) -> bool {
    let LazyCodexConnectorStart {
        session_id,
        project_path,
        model,
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
        handle,
        persist_tx,
        connector_timeout,
    } = request;
    let thread_id = state.codex_thread_for_session(session_id);
    let sid = session_id.to_string();
    let project = project_path.to_string();
    let model = model.map(ToOwned::to_owned);
    let approval = approval_policy.map(ToOwned::to_owned);
    let sandbox = sandbox_mode.map(ToOwned::to_owned);
    let collaboration_mode = collaboration_mode.map(ToOwned::to_owned);
    let personality = personality.map(ToOwned::to_owned);
    let service_tier = service_tier.map(ToOwned::to_owned);
    let developer_instructions = developer_instructions.map(ToOwned::to_owned);
    let codex_config_profile = codex_config_profile.map(ToOwned::to_owned);
    let codex_model_provider = codex_model_provider.map(ToOwned::to_owned);
    let codex_config_overrides = codex_config_overrides.cloned();

    let mut connector_task = tokio::spawn(async move {
        let fallback_overrides = CodexSessionOverrides {
            model: model.clone(),
            model_provider: codex_model_provider.clone(),
            approval_policy: approval.clone(),
            approval_policy_details: None,
            sandbox_mode: sandbox.clone(),
            collaboration_mode: collaboration_mode.clone(),
            multi_agent,
            personality: personality.clone(),
            service_tier: service_tier.clone(),
            developer_instructions: developer_instructions.clone(),
            effort: None,
        };
        let resolved = resolve_codex_settings(
            &project,
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
            .or(approval);
        let effective_sandbox = effective
            .and_then(|value| value.sandbox_mode.clone())
            .or(sandbox);
        if let Some(ref tid) = thread_id {
            match CodexSession::resume_with_config_overrides_and_control_plane(
                sid.clone(),
                &project,
                tid,
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
                Ok(codex) => Ok(codex),
                Err(_) => {
                    CodexSession::new_with_config_overrides_and_control_plane(
                        sid.clone(),
                        &project,
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
                sid.clone(),
                &project,
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

    match tokio::time::timeout(connector_timeout, &mut connector_task).await {
        Ok(Ok(Ok(codex))) => {
            let new_thread_id = codex.thread_id().to_string();
            claim_codex_thread_for_direct_session(
                state,
                &persist_tx,
                session_id,
                &new_thread_id,
                "legacy_codex_thread_row_cleanup",
            )
            .await;
            let (actor_handle, action_tx) = crate::connectors::codex_session::start_event_loop(
                codex,
                handle,
                persist_tx,
                state.clone(),
            );
            state.add_session_actor(actor_handle);
            state.set_codex_action_tx(session_id, action_tx);
            info!(
                component = "runtime",
                event = "session.lazy_connector.codex_connected",
                session_id = %session_id,
                "Lazy Codex connector created"
            );
            true
        }
        Ok(Ok(Err(error))) => {
            warn!(
                component = "runtime",
                event = "session.lazy_connector.codex_failed",
                session_id = %session_id,
                error = %error,
                "Failed to create lazy Codex connector, re-registering passive"
            );
            state.add_session(handle);
            false
        }
        Ok(Err(join_error)) => {
            warn!(
                component = "runtime",
                event = "session.lazy_connector.codex_panicked",
                session_id = %session_id,
                error = %join_error,
                "Codex connector task panicked, re-registering passive"
            );
            state.add_session(handle);
            false
        }
        Err(_) => {
            connector_task.abort();
            warn!(
                component = "runtime",
                event = "session.lazy_connector.codex_timeout",
                session_id = %session_id,
                "Codex connector creation timed out, re-registering passive"
            );
            state.add_session(handle);
            false
        }
    }
}

async fn start_lazy_claude_connector(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    project_path: &str,
    model: Option<&str>,
    handle: crate::domain::sessions::session::SessionHandle,
    persist_tx: tokio::sync::mpsc::Sender<PersistCommand>,
    connector_timeout: Duration,
) -> bool {
    let mut sdk_id = state.claude_sdk_id_for_session(session_id);
    if sdk_id.is_none() {
        if let Ok(Some(restored_session)) = load_session_by_id(session_id).await {
            sdk_id = restored_session.claude_sdk_session_id;
        }
    }

    let provider_id = sdk_id
        .as_deref()
        .and_then(orbitdock_protocol::ProviderSessionId::new);
    if let Some(ref id) = provider_id {
        state.register_claude_thread(session_id, id.as_str());
    }

    let sid = session_id.to_string();
    let project = project_path.to_string();
    let model = model.map(ToOwned::to_owned);
    let connector_task = tokio::spawn(async move {
        ClaudeSession::new(
            sid,
            &project,
            model.as_deref(),
            provider_id.as_ref(),
            None,
            &[],
            &[],
            None,
            false,
        )
        .await
    });

    match tokio::time::timeout(connector_timeout, connector_task).await {
        Ok(Ok(Ok(claude_session))) => {
            let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
                claude_session,
                handle,
                persist_tx,
                state.list_tx(),
                state.clone(),
            );
            state.add_session_actor(actor_handle);
            state.set_claude_action_tx(session_id, action_tx);
            info!(
                component = "runtime",
                event = "session.lazy_connector.claude_connected",
                session_id = %session_id,
                "Lazy Claude connector created"
            );
            true
        }
        Ok(Ok(Err(error))) => {
            warn!(
                component = "runtime",
                event = "session.lazy_connector.claude_failed",
                session_id = %session_id,
                error = %error,
                "Failed to create lazy Claude connector, re-registering passive"
            );
            state.add_session(handle);
            false
        }
        Ok(Err(join_error)) => {
            warn!(
                component = "runtime",
                event = "session.lazy_connector.claude_panicked",
                session_id = %session_id,
                error = %join_error,
                "Claude connector task panicked, re-registering passive"
            );
            state.add_session(handle);
            false
        }
        Err(_) => {
            warn!(
                component = "runtime",
                event = "session.lazy_connector.claude_timeout",
                session_id = %session_id,
                "Claude connector creation timed out, re-registering passive"
            );
            state.add_session(handle);
            false
        }
    }
}
