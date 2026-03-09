use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{broadcast, oneshot};
use tracing::{info, warn};

use orbitdock_protocol::{
    Provider, ServerMessage, SessionState, SessionStatus, StateChanges, WorkStatus,
};

use crate::connectors::claude_session::ClaudeSession;
use crate::connectors::codex_session::CodexSession;
use crate::infrastructure::persistence::{
    load_messages_for_session, load_session_by_id, load_subagents_for_session, PersistCommand,
};
use crate::runtime::restored_sessions::{
    hydrate_restored_messages_if_missing, restored_session_to_state,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{PersistOp, SessionCommand, SubscribeResult};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::claim_codex_thread_for_direct_session;
use crate::support::session_modes::{
    needs_lazy_connector, should_reactivate_passive_codex_session,
};
use crate::support::session_time::{chrono_now, parse_unix_z};

pub(crate) struct SessionSubscribeInputs<'a> {
    pub provider: orbitdock_protocol::Provider,
    pub status: orbitdock_protocol::SessionStatus,
    pub codex_integration_mode: Option<orbitdock_protocol::CodexIntegrationMode>,
    pub claude_integration_mode: Option<orbitdock_protocol::ClaudeIntegrationMode>,
    pub transcript_path: Option<&'a str>,
    pub transcript_modified_at_secs: Option<u64>,
    pub last_activity_at: Option<&'a str>,
    pub has_codex_connector: bool,
    pub has_claude_connector: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SessionSubscribePlan {
    pub reactivate_passive: bool,
    pub start_lazy_connector: bool,
}

pub(crate) enum PreparedSubscribeResult {
    Snapshot {
        state: SessionState,
        rx: broadcast::Receiver<ServerMessage>,
    },
    Replay {
        events: Vec<String>,
        rx: broadcast::Receiver<ServerMessage>,
    },
}

pub(crate) fn plan_session_subscribe(inputs: SessionSubscribeInputs<'_>) -> SessionSubscribePlan {
    let reactivate_passive = should_reactivate_passive_codex_session(
        inputs.provider,
        inputs.status,
        inputs.codex_integration_mode,
        inputs.transcript_path.is_some(),
        inputs.transcript_modified_at_secs,
        parse_unix_z(inputs.last_activity_at),
    );
    let start_lazy_connector = needs_lazy_connector(
        inputs.provider,
        inputs.status,
        inputs.codex_integration_mode,
        inputs.claude_integration_mode,
        inputs.has_codex_connector,
        inputs.has_claude_connector,
    );

    SessionSubscribePlan {
        reactivate_passive,
        start_lazy_connector,
    }
}

pub(crate) async fn request_subscribe(
    actor: &SessionActorHandle,
    since_revision: Option<u64>,
) -> Result<SubscribeResult, String> {
    let (sub_tx, sub_rx) = oneshot::channel();
    actor
        .send(SessionCommand::Subscribe {
            since_revision,
            reply: sub_tx,
        })
        .await;

    sub_rx.await.map_err(|error| error.to_string())
}

pub(crate) async fn prepare_subscribe_result(
    actor: &SessionActorHandle,
    session_id: &str,
    result: SubscribeResult,
) -> PreparedSubscribeResult {
    match result {
        SubscribeResult::Replay { events, rx } => PreparedSubscribeResult::Replay { events, rx },
        SubscribeResult::Snapshot { state, rx } => PreparedSubscribeResult::Snapshot {
            state: hydrate_runtime_subscribe_snapshot(actor, *state, session_id).await,
            rx,
        },
    }
}

pub(crate) async fn load_persisted_subscribe_state(
    session_id: &str,
) -> Result<Option<SessionState>, String> {
    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            hydrate_restored_messages_if_missing(&mut restored, session_id).await;
            let mut state = restored_session_to_state(restored);
            hydrate_subagents(&mut state, session_id, "session.subscribe").await;
            Ok(Some(state))
        }
        Ok(None) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

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
        state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
    }

    let result = request_subscribe(actor, None).await?;
    Ok(prepare_subscribe_result(actor, session_id, result).await)
}

pub(crate) async fn start_lazy_connector_and_prepare_subscribe(
    state: &Arc<SessionRegistry>,
    actor: &SessionActorHandle,
    session_id: &str,
    provider: Provider,
    project_path: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
) -> Result<Option<PreparedSubscribeResult>, String> {
    let (take_tx, take_rx) = oneshot::channel();
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
                session_id,
                project_path,
                model,
                approval_policy,
                sandbox_mode,
                handle,
                persist_tx.clone(),
                connector_timeout,
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
        return Ok(Some(
            prepare_subscribe_result(&new_actor, session_id, result).await,
        ));
    }

    if connector_connected {
        return Err(format!(
            "session {} missing after lazy connector startup",
            session_id
        ));
    }

    Ok(None)
}

async fn hydrate_runtime_subscribe_snapshot(
    actor: &SessionActorHandle,
    mut state: SessionState,
    session_id: &str,
) -> SessionState {
    loop {
        if !state.messages.is_empty() {
            break;
        }

        let Some(path) = state.transcript_path.clone() else {
            break;
        };
        match actor
            .load_transcript_and_sync(path, session_id.to_string())
            .await
        {
            Ok(Some(loaded)) => {
                state = loaded;
                continue;
            }
            Ok(None) | Err(_) => break,
        }
    }

    if state.messages.is_empty() {
        if let Ok(messages) = load_messages_for_session(session_id).await {
            if !messages.is_empty() {
                state.messages = messages;
            }
        }
    }

    state.total_message_count = Some(state.messages.len() as u64);
    state.has_more_before = Some(false);
    state.oldest_sequence = state.messages.first().and_then(|message| message.sequence);
    state.newest_sequence = state.messages.last().and_then(|message| message.sequence);

    hydrate_subagents(&mut state, session_id, "session.subscribe").await;
    state
}

async fn start_lazy_codex_connector(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    project_path: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    handle: crate::domain::sessions::session::SessionHandle,
    persist_tx: tokio::sync::mpsc::Sender<PersistCommand>,
    connector_timeout: Duration,
) -> bool {
    let thread_id = state.codex_thread_for_session(session_id);
    let sid = session_id.to_string();
    let project = project_path.to_string();
    let model = model.map(ToOwned::to_owned);
    let approval = approval_policy.map(ToOwned::to_owned);
    let sandbox = sandbox_mode.map(ToOwned::to_owned);

    let mut connector_task = tokio::spawn(async move {
        if let Some(ref tid) = thread_id {
            match CodexSession::resume(
                sid.clone(),
                &project,
                tid,
                model.as_deref(),
                approval.as_deref(),
                sandbox.as_deref(),
            )
            .await
            {
                Ok(codex) => Ok(codex),
                Err(_) => {
                    CodexSession::new(
                        sid.clone(),
                        &project,
                        model.as_deref(),
                        approval.as_deref(),
                        sandbox.as_deref(),
                    )
                    .await
                }
            }
        } else {
            CodexSession::new(
                sid.clone(),
                &project,
                model.as_deref(),
                approval.as_deref(),
                sandbox.as_deref(),
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

async fn hydrate_subagents(state: &mut SessionState, session_id: &str, event: &'static str) {
    if !state.subagents.is_empty() {
        return;
    }

    match load_subagents_for_session(session_id).await {
        Ok(subagents) => {
            state.subagents = subagents;
        }
        Err(error) => {
            warn!(
                component = "runtime",
                event,
                session_id = %session_id,
                error = %error,
                "Failed to load session subagents"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{plan_session_subscribe, SessionSubscribeInputs};
    use orbitdock_protocol::{
        ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionStatus,
    };

    #[test]
    fn subscribe_plan_prefers_reactivation_for_passive_codex_with_new_transcript_activity() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Codex,
            status: SessionStatus::Ended,
            codex_integration_mode: Some(CodexIntegrationMode::Passive),
            claude_integration_mode: None,
            transcript_path: Some("/tmp/rollout.jsonl"),
            transcript_modified_at_secs: Some(200),
            last_activity_at: Some("100Z"),
            has_codex_connector: false,
            has_claude_connector: false,
        });

        assert!(plan.reactivate_passive);
        assert!(!plan.start_lazy_connector);
    }

    #[test]
    fn subscribe_plan_requests_lazy_connector_for_active_direct_claude_without_runtime() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Claude,
            status: SessionStatus::Active,
            codex_integration_mode: None,
            claude_integration_mode: Some(ClaudeIntegrationMode::Direct),
            transcript_path: None,
            transcript_modified_at_secs: None,
            last_activity_at: None,
            has_codex_connector: false,
            has_claude_connector: false,
        });

        assert!(!plan.reactivate_passive);
        assert!(plan.start_lazy_connector);
    }

    #[test]
    fn subscribe_plan_stays_plain_for_active_sessions_with_live_connector() {
        let plan = plan_session_subscribe(SessionSubscribeInputs {
            provider: Provider::Codex,
            status: SessionStatus::Active,
            codex_integration_mode: Some(CodexIntegrationMode::Direct),
            claude_integration_mode: None,
            transcript_path: Some("/tmp/rollout.jsonl"),
            transcript_modified_at_secs: Some(200),
            last_activity_at: Some("100Z"),
            has_codex_connector: true,
            has_claude_connector: false,
        });

        assert!(!plan.reactivate_passive);
        assert!(!plan.start_lazy_connector);
    }
}
