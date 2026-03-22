use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{error, info};

use orbitdock_protocol::conversation_contracts::RowPageSummary;
use orbitdock_protocol::CodexApprovalPolicy;
use orbitdock_protocol::{Provider, ServerMessage, SessionListItem};

use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_mutations::{
    end_session as end_runtime_session, rename_session as rename_runtime_session,
    update_session_config as update_runtime_session_config, SessionConfigUpdate,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, spawn_broadcast_forwarder, OutboundMessage};

pub(crate) struct CreateSessionRequest {
    pub provider: Provider,
    pub cwd: String,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub approval_policy_details: Option<CodexApprovalPolicy>,
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
            approval_policy: request.approval_policy.clone().or_else(|| {
                request
                    .approval_policy_details
                    .as_ref()
                    .map(|details| details.legacy_summary())
            }),
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
            mission_id: None,
            issue_identifier: None,
            dynamic_tools: Vec::new(),
            allow_bypass_permissions: false,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
        },
    )
    .await;

    let rx = prepared.handle.subscribe();
    spawn_broadcast_forwarder(rx, client_tx.clone(), Some(id.clone()));

    let summary = prepared.summary.clone();
    let snapshot = prepared.snapshot.clone();

    send_json(
        client_tx,
        ServerMessage::ConversationBootstrap {
            session: snapshot,
            conversation: RowPageSummary {
                rows: vec![],
                total_row_count: 0,
                has_more_before: false,
                oldest_sequence: None,
                newest_sequence: None,
            },
        },
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

    state.broadcast_to_list(ServerMessage::SessionCreated {
        session: SessionListItem::from_summary(&summary),
    });
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
    update: SessionConfigUpdate,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    let SessionConfigUpdate {
        approval_policy,
        approval_policy_details,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        model,
        effort,
        ..
    } = update;
    info!(
        component = "session",
        event = "session.config.update_requested",
        connection_id = conn_id,
        session_id = %session_id,
        approval_policy = ?approval_policy,
        approval_policy_details = ?approval_policy_details,
        sandbox_mode = ?sandbox_mode,
        permission_mode = ?permission_mode,
        collaboration_mode = ?collaboration_mode,
        multi_agent = ?multi_agent,
        personality = ?personality,
        service_tier = ?service_tier,
        developer_instructions = ?developer_instructions.as_ref().map(|_| "[set]"),
        model = ?model,
        effort = ?effort,
        "Session config update requested"
    );

    let _ = update_runtime_session_config(
        state,
        &session_id,
        SessionConfigUpdate {
            approval_policy,
            approval_policy_details,
            sandbox_mode,
            permission_mode,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            model,
            effort,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
        },
    )
    .await;
}
