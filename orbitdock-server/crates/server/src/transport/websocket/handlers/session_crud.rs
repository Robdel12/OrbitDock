use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_mutations::SessionConfigUpdate;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::handlers::session_forks::{
    handle_fork_session, handle_fork_to_existing_worktree, handle_fork_to_worktree,
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
            sandbox_mode,
            permission_mode,
            collaboration_mode,
            multi_agent,
            personality,
            service_tier,
            developer_instructions,
        } => {
            handle_update_session_config(
                session_id,
                SessionConfigUpdate {
                    approval_policy,
                    sandbox_mode,
                    permission_mode,
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions,
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
                source_session_id,
                nth_user_message,
                model,
                approval_policy,
                sandbox_mode,
                cwd,
                permission_mode,
                allowed_tools,
                disallowed_tools,
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

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::domain::sessions::session::SessionHandle;
    use crate::transport::websocket::test_support::new_test_state;
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{
        ClientMessage, CodexIntegrationMode, Provider, SessionStatus, WorkStatus,
    };
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn ending_passive_session_keeps_it_available_for_reactivation() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "passive-end-keep".to_string();

        let mut handle_state = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        );
        handle_state.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
        state.add_session(handle_state);

        handle(
            ClientMessage::EndSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("passive session should remain in app state");

        let snap = actor.snapshot();
        assert_eq!(snap.status, SessionStatus::Ended);
        assert_eq!(snap.work_status, WorkStatus::Ended);
    }
}
