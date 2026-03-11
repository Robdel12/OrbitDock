use std::sync::Arc;
use std::time::Duration;

use tracing::{info, warn};

use crate::connectors::claude_session::{ClaudeAction, ClaudeSession};
use crate::connectors::codex_session::CodexSession;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::claim_codex_thread_for_direct_session;
use orbitdock_connector_codex::CodexControlPlane;

pub(crate) async fn start_direct_codex_session(
    state: &Arc<SessionRegistry>,
    mut handle: SessionHandle,
    session_id: &str,
    cwd: &str,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    collaboration_mode: Option<&str>,
    multi_agent: Option<bool>,
    personality: Option<&str>,
    service_tier: Option<&str>,
    developer_instructions: Option<&str>,
) -> Result<(), String> {
    let session_id = session_id.to_string();
    let cwd = cwd.to_string();
    let model = model.map(ToOwned::to_owned);
    let approval_policy = approval_policy.map(ToOwned::to_owned);
    let sandbox_mode = sandbox_mode.map(ToOwned::to_owned);
    let collaboration_mode = collaboration_mode.map(ToOwned::to_owned);
    let multi_agent = multi_agent;
    let personality = personality.map(ToOwned::to_owned);
    let service_tier = service_tier.map(ToOwned::to_owned);
    let developer_instructions = developer_instructions.map(ToOwned::to_owned);
    let persist_tx = state.persist().clone();
    let connector_timeout = Duration::from_secs(15);
    let task_session_id = session_id.clone();

    let mut connector_task = tokio::spawn(async move {
        CodexSession::new_with_control_plane(
            task_session_id,
            &cwd,
            model.as_deref(),
            approval_policy.as_deref(),
            sandbox_mode.as_deref(),
            CodexControlPlane {
                collaboration_mode,
                multi_agent,
                personality,
                service_tier,
                developer_instructions,
            },
        )
        .await
    });

    let codex_session = match tokio::time::timeout(connector_timeout, &mut connector_task).await {
        Ok(Ok(Ok(session))) => session,
        Ok(Ok(Err(error))) => return Err(error.to_string()),
        Ok(Err(join_error)) => return Err(format!("Connector task panicked: {join_error}")),
        Err(_) => {
            connector_task.abort();
            return Err("Connector creation timed out".to_string());
        }
    };

    let thread_id = codex_session.thread_id().to_string();
    claim_codex_thread_for_direct_session(
        state,
        &persist_tx,
        &session_id,
        &thread_id,
        "legacy_codex_thread_row_cleanup",
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
        event = "session.create.connector_started",
        session_id = %session_id,
        "Codex connector started"
    );

    Ok(())
}

pub(crate) async fn start_direct_claude_session(
    state: &Arc<SessionRegistry>,
    request: StartDirectClaudeRequest<'_>,
) -> Result<(), String> {
    let StartDirectClaudeRequest {
        mut handle,
        session_id,
        cwd,
        model,
        permission_mode,
        allowed_tools,
        disallowed_tools,
        effort,
    } = request;
    let session_id = session_id.to_string();
    let claude_session = ClaudeSession::new(
        session_id.clone(),
        cwd,
        model,
        None,
        permission_mode,
        allowed_tools,
        disallowed_tools,
        effort,
    )
    .await
    .map_err(|error| error.to_string())?;

    handle.set_list_tx(state.list_tx());
    let persist_tx = state.persist().clone();
    let (actor_handle, action_tx) = crate::connectors::claude_session::start_event_loop(
        claude_session,
        handle,
        persist_tx.clone(),
        state.list_tx(),
        state.clone(),
    );

    if let Some(mode) = permission_mode {
        let _ = actor_handle
            .send(SessionCommand::ApplyDelta {
                changes: orbitdock_protocol::StateChanges {
                    permission_mode: Some(Some(mode.to_string())),
                    ..Default::default()
                },
                persist_op: None,
            })
            .await;
    }

    state.add_session_actor(actor_handle);
    state.set_claude_action_tx(&session_id, action_tx.clone());

    info!(
        component = "session",
        event = "session.create.claude_connector_started",
        session_id = %session_id,
        "Claude connector started"
    );

    spawn_claude_init_watchdog(state, persist_tx, action_tx, session_id);
    Ok(())
}

pub(crate) struct StartDirectClaudeRequest<'a> {
    pub handle: SessionHandle,
    pub session_id: &'a str,
    pub cwd: &'a str,
    pub model: Option<&'a str>,
    pub permission_mode: Option<&'a str>,
    pub allowed_tools: &'a [String],
    pub disallowed_tools: &'a [String],
    pub effort: Option<&'a str>,
}

fn spawn_claude_init_watchdog(
    state: &Arc<SessionRegistry>,
    persist_tx: tokio::sync::mpsc::Sender<PersistCommand>,
    action_tx: tokio::sync::mpsc::Sender<ClaudeAction>,
    session_id: String,
) {
    let watchdog_state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(45)).await;

        let has_sdk_id = watchdog_state
            .claude_sdk_id_for_session(&session_id)
            .is_some();
        if has_sdk_id {
            return;
        }

        warn!(
            component = "session",
            event = "session.init_timeout",
            session_id = %session_id,
            "Claude session never initialized after 45s — ending ghost"
        );

        let _ = action_tx.send(ClaudeAction::EndSession).await;
        let _ = persist_tx
            .send(PersistCommand::SessionEnd {
                id: session_id.clone(),
                reason: "init_timeout".to_string(),
            })
            .await;
        watchdog_state.remove_session(&session_id);
        watchdog_state.broadcast_to_list(orbitdock_protocol::ServerMessage::SessionEnded {
            session_id,
            reason: "init_timeout".into(),
        });
    });
}
