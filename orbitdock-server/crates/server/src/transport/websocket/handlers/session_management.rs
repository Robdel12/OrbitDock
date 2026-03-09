use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{error, info};

use orbitdock_protocol::{Provider, ServerMessage};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_creation::{
    persist_direct_session_create, prepare_direct_session, DirectSessionCreationInputs,
};
use crate::runtime::session_direct_start::{
    start_direct_claude_session, start_direct_codex_session,
};
use crate::runtime::session_mutations::{
    end_session as end_runtime_session, rename_session as rename_runtime_session,
    update_session_config as update_runtime_session_config,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, spawn_broadcast_forwarder, OutboundMessage};

pub(crate) struct CreateSessionRequest {
    pub provider: Provider,
    pub cwd: String,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub allowed_tools: Vec<String>,
    pub disallowed_tools: Vec<String>,
    pub effort: Option<String>,
}

pub(crate) async fn handle_create_session(
    request: CreateSessionRequest,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    info!(
        component = "session",
        event = "session.create.requested",
        connection_id = conn_id,
        provider = %match request.provider {
            Provider::Codex => "codex",
            Provider::Claude => "claude",
        },
        project_path = %request.cwd,
        "Create session requested"
    );

    let id = orbitdock_protocol::new_id();
    let git_branch = crate::domain::git::repo::resolve_git_branch(&request.cwd).await;
    let prepared = prepare_direct_session(DirectSessionCreationInputs {
        id: id.clone(),
        provider: request.provider,
        cwd: request.cwd.clone(),
        git_branch: git_branch.clone(),
        model: request.model.clone(),
        approval_policy: request.approval_policy.clone(),
        sandbox_mode: request.sandbox_mode.clone(),
        effort: request.effort.clone(),
    });
    let handle = prepared.handle;

    let rx = handle.subscribe();
    spawn_broadcast_forwarder(rx, client_tx.clone(), Some(id.clone()));

    let summary = prepared.summary;
    let snapshot = prepared.snapshot;
    let persist_tx = state.persist().clone();
    persist_direct_session_create(
        &persist_tx,
        id.clone(),
        request.provider,
        request.cwd.clone(),
        prepared.project_name,
        git_branch,
        request.model.clone(),
        request.approval_policy.clone(),
        request.sandbox_mode.clone(),
        request.permission_mode.clone(),
        request.effort.clone(),
    )
    .await;

    send_json(
        client_tx,
        ServerMessage::SessionSnapshot { session: snapshot },
    )
    .await;

    if request.provider == Provider::Codex {
        let session_id = id.clone();
        match start_direct_codex_session(
            state,
            handle,
            &session_id,
            &request.cwd,
            request.model.as_deref(),
            request.approval_policy.as_deref(),
            request.sandbox_mode.as_deref(),
        )
        .await
        {
            Ok(()) => {}
            Err(error_message) => {
                let _ = persist_tx
                    .send(PersistCommand::SessionEnd {
                        id: session_id.clone(),
                        reason: "connector_failed".to_string(),
                    })
                    .await;
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id: session_id.clone(),
                    reason: "connector_failed".into(),
                });
                error!(
                    component = "session",
                    event = "session.create.connector_failed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    error = %error_message,
                    "Failed to start Codex session — ended immediately"
                );
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "codex_error".into(),
                        message: error_message,
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }
    } else if request.provider == Provider::Claude {
        let session_id = id.clone();
        match start_direct_claude_session(
            state,
            handle,
            &session_id,
            &request.cwd,
            request.model.as_deref(),
            request.permission_mode.as_deref(),
            &request.allowed_tools,
            &request.disallowed_tools,
            request.effort.as_deref(),
        )
        .await
        {
            Ok(()) => {}
            Err(error_message) => {
                let _ = persist_tx
                    .send(PersistCommand::SessionEnd {
                        id: session_id.clone(),
                        reason: "connector_failed".to_string(),
                    })
                    .await;
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id: session_id.clone(),
                    reason: "connector_failed".into(),
                });
                error!(
                    component = "session",
                    event = "session.create.claude_connector_failed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    error = %error_message,
                    "Failed to start Claude session — ended immediately"
                );
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "claude_error".into(),
                        message: error_message,
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }
    } else {
        state.add_session(handle);
    }

    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
}

pub(crate) async fn handle_end_session(
    session_id: String,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    info!(
        component = "session",
        event = "session.end.requested",
        connection_id = conn_id,
        session_id = %session_id,
        "End session requested"
    );

    let canceled_shells = end_runtime_session(state, &session_id).await;
    if canceled_shells > 0 {
        info!(
            component = "shell",
            event = "shell.cancel.session_end",
            connection_id = conn_id,
            session_id = %session_id,
            canceled_shells,
            "Canceled active shell commands while ending session"
        );
    }
}

pub(crate) async fn handle_rename_session(
    session_id: String,
    name: Option<String>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    info!(
        component = "session",
        event = "session.rename.requested",
        connection_id = conn_id,
        session_id = %session_id,
        has_name = name.is_some(),
        "Rename session requested"
    );

    let _ = rename_runtime_session(state, &session_id, name).await;
}

pub(crate) async fn handle_update_session_config(
    session_id: String,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    permission_mode: Option<String>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    info!(
        component = "session",
        event = "session.config.update_requested",
        connection_id = conn_id,
        session_id = %session_id,
        approval_policy = ?approval_policy,
        sandbox_mode = ?sandbox_mode,
        permission_mode = ?permission_mode,
        "Session config update requested"
    );

    let _ = update_runtime_session_config(
        state,
        &session_id,
        approval_policy,
        sandbox_mode,
        permission_mode,
    )
    .await;
}
