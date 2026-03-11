use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{error, info};

use orbitdock_protocol::{Provider, ServerMessage};

use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
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
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
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
    let prepared = prepare_persist_direct_session(
        state,
        id.clone(),
        DirectSessionRequest {
            provider: request.provider,
            cwd: request.cwd.clone(),
            model: request.model.clone(),
            approval_policy: request.approval_policy.clone(),
            sandbox_mode: request.sandbox_mode.clone(),
            permission_mode: request.permission_mode.clone(),
            allowed_tools: request.allowed_tools.clone(),
            disallowed_tools: request.disallowed_tools.clone(),
            effort: request.effort.clone(),
            collaboration_mode: request.collaboration_mode.clone(),
            multi_agent: request.multi_agent,
            personality: request.personality.clone(),
            service_tier: request.service_tier.clone(),
            developer_instructions: request.developer_instructions.clone(),
        },
    )
    .await;

    let rx = prepared.handle.subscribe();
    spawn_broadcast_forwarder(rx, client_tx.clone(), Some(id.clone()));

    let summary = prepared.summary.clone();
    let snapshot = prepared.snapshot.clone();

    send_json(
        client_tx,
        ServerMessage::SessionSnapshot { session: snapshot },
    )
    .await;

    if let Err(error_message) = launch_prepared_direct_session(state, prepared).await {
        let code = match request.provider {
            Provider::Codex => "codex_error",
            Provider::Claude => "claude_error",
        };
        error!(
            component = "session",
            event = "session.create.connector_failed",
            connection_id = conn_id,
            session_id = %id,
            error = %error_message,
            "Failed to start direct session connector"
        );
        send_json(
            client_tx,
            ServerMessage::Error {
                code: code.into(),
                message: error_message,
                session_id: Some(id.clone()),
            },
        )
        .await;
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
    collaboration_mode: Option<String>,
    multi_agent: Option<bool>,
    personality: Option<String>,
    service_tier: Option<String>,
    developer_instructions: Option<String>,
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
        collaboration_mode = ?collaboration_mode,
        multi_agent = ?multi_agent,
        personality = ?personality,
        service_tier = ?service_tier,
        developer_instructions = ?developer_instructions.as_ref().map(|_| "[set]"),
        "Session config update requested"
    );

    let _ = update_runtime_session_config(
        state,
        &session_id,
        approval_policy,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
    )
    .await;
}

#[cfg(test)]
mod tests {
    use tokio::sync::mpsc;

    use orbitdock_protocol::{Provider, ServerMessage};

    use crate::transport::websocket::test_support::{new_test_state, recv_json};

    use super::{handle_create_session, CreateSessionRequest};

    #[tokio::test]
    async fn create_session_emits_session_snapshot_immediately() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel(8);
        let cwd = "/tmp/orbitdock-create-session".to_string();

        handle_create_session(
            CreateSessionRequest {
                provider: Provider::Claude,
                cwd: cwd.clone(),
                model: None,
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                allowed_tools: vec![],
                disallowed_tools: vec![],
                effort: None,
                collaboration_mode: None,
                multi_agent: None,
                personality: None,
                service_tier: None,
                developer_instructions: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::SessionSnapshot { session } => {
                assert_eq!(session.provider, Provider::Claude);
                assert_eq!(session.project_path, cwd);
            }
            other => panic!("expected SessionSnapshot first, got {other:?}"),
        }
    }
}
