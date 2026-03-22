use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_mutations::SessionConfigUpdate;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::handlers::session_forks::{
    handle_fork_session, handle_fork_to_existing_worktree, handle_fork_to_worktree,
    ForkSessionRequest,
};
use crate::transport::websocket::handlers::session_management::{
    handle_create_session, handle_end_session, handle_rename_session, handle_update_session_config,
    CreateSessionRequest,
};
use crate::transport::websocket::OutboundMessage;

fn resolve_developer_instructions(
    developer_instructions: Option<String>,
    system_prompt: Option<String>,
    append_system_prompt: Option<String>,
) -> Option<String> {
    if developer_instructions.is_some() {
        return developer_instructions;
    }

    match (
        system_prompt.filter(|value| !value.trim().is_empty()),
        append_system_prompt.filter(|value| !value.trim().is_empty()),
    ) {
        (Some(base), Some(append)) => Some(format!("{base}\n\n{append}")),
        (Some(base), None) => Some(base),
        (None, Some(append)) => Some(append),
        (None, None) => None,
    }
}

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::CreateSession {
            provider,
            cwd,
            model,
            approval_policy,
            approval_policy_details,
            sandbox_mode,
            permission_mode,
            allowed_tools,
            disallowed_tools,
            effort,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
            system_prompt,
            append_system_prompt,
        } => {
            handle_create_session(
                CreateSessionRequest {
                    provider,
                    cwd,
                    model,
                    approval_policy,
                    approval_policy_details,
                    sandbox_mode,
                    permission_mode,
                    allowed_tools,
                    disallowed_tools,
                    effort,
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions: resolve_developer_instructions(
                        developer_instructions,
                        system_prompt,
                        append_system_prompt,
                    ),
                },
                client_tx,
                state,
                conn_id,
            )
            .await;
        }
        ClientMessage::EndSession { session_id } => {
            handle_end_session(session_id, state, conn_id).await;
        }
        ClientMessage::RenameSession { session_id, name } => {
            handle_rename_session(session_id, name, state, conn_id).await;
        }
        ClientMessage::UpdateSessionConfig {
            session_id,
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
        } => {
            handle_update_session_config(
                session_id,
                SessionConfigUpdate {
                    approval_policy: Some(approval_policy),
                    approval_policy_details: Some(approval_policy_details),
                    sandbox_mode: Some(sandbox_mode),
                    permission_mode: Some(permission_mode),
                    collaboration_mode: Some(collaboration_mode),
                    multi_agent: Some(multi_agent),
                    personality: Some(personality),
                    service_tier: Some(service_tier),
                    developer_instructions: Some(developer_instructions),
                    model: Some(model),
                    effort: Some(effort),
                    codex_config_mode: None,
                    codex_config_profile: None,
                    codex_model_provider: None,
                },
                state,
                conn_id,
            )
            .await;
        }
        ClientMessage::ForkSessionToWorktree {
            source_session_id,
            branch_name,
            base_branch,
            nth_user_message,
        } => {
            handle_fork_to_worktree(
                source_session_id,
                branch_name,
                base_branch,
                nth_user_message,
                client_tx,
                state,
                conn_id,
            )
            .await;
        }
        ClientMessage::ForkSessionToExistingWorktree {
            source_session_id,
            worktree_id,
            nth_user_message,
        } => {
            handle_fork_to_existing_worktree(
                source_session_id,
                worktree_id,
                nth_user_message,
                client_tx,
                state,
                conn_id,
            )
            .await;
        }
        ClientMessage::ForkSession {
            source_session_id,
            nth_user_message,
            model,
            approval_policy,
            sandbox_mode,
            cwd,
            permission_mode,
            allowed_tools,
            disallowed_tools,
            ..
        } => {
            handle_fork_session(
                ForkSessionRequest {
                    source_session_id,
                    nth_user_message,
                    model,
                    approval_policy,
                    sandbox_mode,
                    cwd,
                    permission_mode,
                    allowed_tools,
                    disallowed_tools,
                },
                client_tx,
                state,
                conn_id,
            )
            .await;
        }
        _ => {
            tracing::warn!(?msg, "session_crud::handle called with unexpected variant");
        }
    }
}
