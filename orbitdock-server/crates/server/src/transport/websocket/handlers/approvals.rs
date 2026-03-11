use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::info;

use crate::runtime::approval_dispatch::{dispatch_approve_tool, ApprovalDispatchResult};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;
use orbitdock_protocol::ServerMessage;

async fn send_approval_decision_result(
    client_tx: &mpsc::Sender<OutboundMessage>,
    session_id: String,
    request_id: String,
    result: ApprovalDispatchResult,
) {
    send_json(
        client_tx,
        ServerMessage::ApprovalDecisionResult {
            session_id,
            request_id,
            outcome: result.outcome,
            active_request_id: result.active_request_id,
            approval_version: result.approval_version,
        },
    )
    .await;
}

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::ApproveTool {
            session_id,
            request_id,
            decision,
            message,
            interrupt,
            updated_input,
        } => {
            info!(
                component = "approval",
                event = "approval.decision.received",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                decision = %decision,
                "Approval decision received"
            );

            let request_id_for_result = request_id.clone();
            let result = match dispatch_approve_tool(
                state,
                &session_id,
                request_id,
                decision,
                message,
                interrupt,
                updated_input,
            )
            .await
            {
                Ok(result) => result,
                Err(_) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "not_found".into(),
                            message: format!(
                                "Session {} not found or has no active connector",
                                session_id
                            ),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let promoted_request_id = result.active_request_id.clone();
            send_approval_decision_result(
                client_tx,
                session_id.clone(),
                request_id_for_result,
                result,
            )
            .await;

            if let Some(next_pending_request_id) = promoted_request_id {
                info!(
                    component = "approval",
                    event = "approval.queue.promoted",
                    session_id = %session_id,
                    next_request_id = %next_pending_request_id,
                    "Promoted next queued approval"
                );
            }
        }

        ClientMessage::ListApprovals { session_id, .. } => {
            send_rest_only_error(client_tx, "GET /api/approvals", session_id).await;
        }

        ClientMessage::DeleteApproval { .. } => {
            send_rest_only_error(client_tx, "DELETE /api/approvals/{approval_id}", None).await;
        }

        _ => {
            tracing::warn!(?msg, "approvals::handle called with unexpected variant");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::SessionHandle;
    use crate::domain::sessions::transition::Input;
    use crate::runtime::session_commands::SessionCommand;
    use crate::transport::websocket::test_support::{new_test_state, recv_json};
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ApprovalType, ClientMessage, Provider, ServerMessage, WorkStatus};
    use tokio::sync::mpsc;

    async fn queue_codex_exec_approval(
        state: &std::sync::Arc<crate::runtime::session_registry::SessionRegistry>,
        session_id: &str,
        request_id: &str,
    ) {
        let actor = state
            .get_session(session_id)
            .expect("session should exist to queue approval");
        actor
            .send(SessionCommand::ProcessEvent {
                event: Input::ApprovalRequested {
                    request_id: request_id.to_string(),
                    approval_type: ApprovalType::Exec,
                    tool_name: Some("Bash".to_string()),
                    tool_input: Some(r#"{"command":"echo test"}"#.to_string()),
                    command: Some("echo test".to_string()),
                    file_path: None,
                    diff: None,
                    question: None,
                    permission_reason: None,
                    requested_permissions: None,
                    proposed_amendment: None,
                    permission_suggestions: None,
                },
            })
            .await;
        tokio::task::yield_now().await;
    }

    #[tokio::test]
    async fn approve_tool_promotes_next_queued_request_from_server_state() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-queue-promote".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;
        queue_codex_exec_approval(&state, &session_id, "req-2").await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );

        handle(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-1".to_string(),
                decision: "approved".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx
            .recv()
            .await
            .expect("expected codex approval action")
        {
            CodexAction::ApproveExec { request_id, .. } => {
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApproveExec action, got {:?}", other),
        }

        tokio::task::yield_now().await;

        let snapshot = actor.snapshot();
        assert_eq!(snapshot.pending_approval_id.as_deref(), Some("req-2"));
        assert_eq!(snapshot.work_status, WorkStatus::Permission);

        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                outcome,
                request_id,
                ..
            } => {
                assert_eq!(outcome, "applied");
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApprovalDecisionResult, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn approve_tool_denied_keeps_session_working_until_turn_finishes() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-denied-working".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");

        handle(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-1".to_string(),
                decision: "denied".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx
            .recv()
            .await
            .expect("expected codex approval action")
        {
            CodexAction::ApproveExec {
                request_id,
                decision,
                ..
            } => {
                assert_eq!(request_id, "req-1");
                assert_eq!(decision, "denied");
            }
            other => panic!("expected ApproveExec action, got {:?}", other),
        }

        tokio::task::yield_now().await;

        let snapshot = actor.snapshot();
        assert_eq!(snapshot.pending_approval_id, None);
        assert_eq!(snapshot.work_status, WorkStatus::Working);

        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                outcome,
                request_id,
                ..
            } => {
                assert_eq!(outcome, "applied");
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApprovalDecisionResult, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn approve_tool_rejects_out_of_order_request_ids() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-queue-stale".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;
        queue_codex_exec_approval(&state, &session_id, "req-2").await;

        handle(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-2".to_string(),
                decision: "approved".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                session_id: result_session_id,
                request_id,
                outcome,
                active_request_id,
                ..
            } => {
                assert_eq!(result_session_id, session_id);
                assert_eq!(request_id, "req-2");
                assert_eq!(outcome, "stale");
                assert_eq!(active_request_id.as_deref(), Some("req-1"));
            }
            other => panic!("expected stale ApprovalDecisionResult, got {:?}", other),
        }

        assert!(action_rx.try_recv().is_err());

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );
    }
}
