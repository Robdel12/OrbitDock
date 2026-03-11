use std::sync::Arc;
use std::time::UNIX_EPOCH;

use tokio::sync::mpsc;
use tracing::{error, info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::runtime::session_activation::{
    reactivate_passive_and_prepare_subscribe, start_lazy_connector_and_prepare_subscribe,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_subscription_queries::load_persisted_subscribe_state;
use crate::runtime::session_subscriptions::{
    plan_session_subscribe, prepare_subscribe_result, request_subscribe, PreparedSubscribeResult,
    SessionSubscribeInputs,
};
use crate::transport::websocket::{
    send_json, send_replay_or_snapshot_fallback, send_snapshot_if_requested,
    spawn_broadcast_forwarder, OutboundMessage,
};

async fn forward_subscribe_result(
    client_tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
    include_snapshot: bool,
    conn_id: u64,
    result: PreparedSubscribeResult,
) {
    match result {
        PreparedSubscribeResult::Snapshot { state, rx } => {
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.to_string()));
            send_snapshot_if_requested(client_tx, session_id, *state, include_snapshot, conn_id)
                .await;
        }
        PreparedSubscribeResult::Replay { events, rx } => {
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.to_string()));
            send_replay_or_snapshot_fallback(client_tx, session_id, events, conn_id).await;
        }
    }
}

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::SubscribeList => {
            let rx = state.subscribe_list();
            spawn_broadcast_forwarder(rx, client_tx.clone(), None);

            let sessions = state.get_session_summaries();
            send_json(client_tx, ServerMessage::SessionsList { sessions }).await;
        }

        ClientMessage::SubscribeSession {
            session_id,
            since_revision,
            include_snapshot,
        } => {
            if let Some(actor) = state.get_session(&session_id) {
                let snap = actor.snapshot();

                let subscribe_plan = plan_session_subscribe(SessionSubscribeInputs {
                    provider: snap.provider,
                    status: snap.status,
                    codex_integration_mode: snap.codex_integration_mode,
                    claude_integration_mode: snap.claude_integration_mode,
                    transcript_path: snap.transcript_path.as_deref(),
                    transcript_modified_at_secs: snap
                        .transcript_path
                        .as_deref()
                        .and_then(|path| std::fs::metadata(path).ok())
                        .and_then(|meta| meta.modified().ok())
                        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                        .map(|duration| duration.as_secs()),
                    last_activity_at: snap.last_activity_at.as_deref(),
                    has_codex_connector: state.has_codex_connector(&session_id),
                    has_claude_connector: state.has_claude_connector(&session_id),
                });

                if subscribe_plan.reactivate_passive {
                    match reactivate_passive_and_prepare_subscribe(state, &actor, &session_id).await
                    {
                        Ok(result) => {
                            forward_subscribe_result(
                                client_tx,
                                &session_id,
                                include_snapshot,
                                conn_id,
                                result,
                            )
                            .await;
                        }
                        Err(error) => {
                            warn!(
                                component = "session",
                                event = "session.subscribe.reactivate_failed",
                                session_id = %session_id,
                                error = %error,
                                "Passive session reactivation failed"
                            );
                        }
                    }
                    return;
                }

                if subscribe_plan.start_lazy_connector {
                    info!(
                        component = "session",
                        event = "session.lazy_connector.starting",
                        connection_id = conn_id,
                        session_id = %session_id,
                        provider = ?snap.provider,
                        "Creating connector lazily on first subscribe"
                    );

                    match start_lazy_connector_and_prepare_subscribe(
                        state,
                        &actor,
                        crate::runtime::session_activation::LazyConnectorStartRequest {
                            session_id: &session_id,
                            provider: snap.provider,
                            project_path: &snap.project_path,
                            model: snap.model.as_deref(),
                            approval_policy: snap.approval_policy.as_deref(),
                            sandbox_mode: snap.sandbox_mode.as_deref(),
                            collaboration_mode: snap.collaboration_mode.as_deref(),
                            multi_agent: snap.multi_agent,
                            personality: snap.personality.as_deref(),
                            service_tier: snap.service_tier.as_deref(),
                            developer_instructions: snap.developer_instructions.as_deref(),
                        },
                    )
                    .await
                    {
                        Ok(Some(result)) => {
                            forward_subscribe_result(
                                client_tx,
                                &session_id,
                                include_snapshot,
                                conn_id,
                                result,
                            )
                            .await;
                            return;
                        }
                        Ok(None) => {
                            warn!(
                                component = "session",
                                event = "session.lazy_connector.take_failed",
                                session_id = %session_id,
                                "Failed to take handle from passive actor, falling through to normal subscribe"
                            );
                        }
                        Err(error) => {
                            warn!(
                                component = "session",
                                event = "session.lazy_connector.subscribe_failed",
                                session_id = %session_id,
                                error = %error,
                                "Lazy connector subscribe failed"
                            );
                            return;
                        }
                    }
                }

                match request_subscribe(&actor, since_revision).await {
                    Ok(result) => {
                        let prepared = prepare_subscribe_result(&actor, &session_id, result).await;
                        forward_subscribe_result(
                            client_tx,
                            &session_id,
                            include_snapshot,
                            conn_id,
                            prepared,
                        )
                        .await;
                    }
                    Err(error) => {
                        warn!(
                            component = "session",
                            event = "session.subscribe.request_failed",
                            session_id = %session_id,
                            error = %error,
                            "Runtime subscribe request failed"
                        );
                    }
                }
            } else {
                match load_persisted_subscribe_state(&session_id).await {
                    Ok(Some(snapshot)) => {
                        send_snapshot_if_requested(
                            client_tx,
                            &session_id,
                            snapshot,
                            include_snapshot,
                            conn_id,
                        )
                        .await;
                    }
                    Ok(None) => {
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "not_found".into(),
                                message: format!("Session {} not found", session_id),
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                    Err(error) => {
                        error!(
                            component = "websocket",
                            event = "session.subscribe.db_error",
                            session_id = %session_id,
                            error = %error,
                            "Failed to load session from database"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "db_error".into(),
                                message: error,
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            }
        }

        ClientMessage::UnsubscribeSession { session_id: _ } => {}

        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::domain::sessions::session::SessionHandle;
    use crate::runtime::session_commands::SessionCommand;
    use crate::transport::websocket::test_support::{new_test_state, recv_json};
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ClientMessage, Message, MessageType, Provider, ServerMessage};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn subscribe_session_can_stream_without_initial_snapshot() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle_state = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        state.add_session(handle_state);

        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        handle(
            ClientMessage::SubscribeSession {
                session_id: session_id.clone(),
                since_revision: None,
                include_snapshot: false,
            },
            &client_tx,
            &state,
            1001,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should be available after subscribe");
        let message = Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            sequence: None,
            message_type: MessageType::Assistant,
            content: "streamed update".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        };

        actor
            .send(SessionCommand::AddMessageAndBroadcast { message })
            .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::MessageAppended {
                session_id: sid,
                message,
            } => {
                assert_eq!(sid, session_id);
                assert_eq!(message.content, "streamed update");
            }
            other => panic!(
                "expected first streamed event to be MessageAppended, got {:?}",
                other
            ),
        }
    }
}
