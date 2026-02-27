use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};
use tracing::info;

use crate::claude_session::ClaudeAction;
use crate::codex_session::CodexAction;
use crate::persistence::PersistCommand;
use crate::session_command::SessionCommand;
use crate::state::SessionRegistry;
use crate::websocket::{
    send_json, send_rest_only_error, work_status_for_approval_decision, OutboundMessage,
};
use orbitdock_protocol::ClientMessage;
use orbitdock_protocol::ServerMessage;

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

            let fallback_work_status = work_status_for_approval_decision(&decision);
            let mut resolved_work_status = fallback_work_status;

            // Resolve pending approval server-side and promote next queued request.
            // This keeps queue ownership inside the session actor.
            let (approval_type, proposed_amendment, next_pending_request_id, approval_version) =
                if let Some(actor) = state.get_session(&session_id) {
                    let (reply_tx, reply_rx) = oneshot::channel();
                    actor
                        .send(SessionCommand::ResolvePendingApproval {
                            request_id: request_id.clone(),
                            fallback_work_status,
                            reply: reply_tx,
                        })
                        .await;

                    if let Ok(resolution) = reply_rx.await {
                        resolved_work_status = resolution.work_status;
                        (
                            resolution.approval_type,
                            resolution.proposed_amendment,
                            resolution.next_pending_approval.map(|approval| approval.id),
                            resolution.approval_version,
                        )
                    } else {
                        (None, None, None, 0)
                    }
                } else {
                    (None, None, None, 0)
                };

            if state.get_session(&session_id).is_some() && approval_type.is_none() {
                send_json(
                    client_tx,
                    ServerMessage::ApprovalDecisionResult {
                        session_id: session_id.clone(),
                        request_id: request_id.clone(),
                        outcome: "stale".to_string(),
                        active_request_id: next_pending_request_id.clone(),
                        approval_version,
                    },
                )
                .await;
                return;
            }

            let request_id_for_result = request_id.clone();

            let _ = state
                .persist()
                .send(PersistCommand::ApprovalDecision {
                    session_id: session_id.clone(),
                    request_id: request_id.clone(),
                    decision: decision.clone(),
                })
                .await;

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let action = match approval_type {
                    Some(orbitdock_protocol::ApprovalType::Patch) => {
                        info!(
                            component = "approval",
                            event = "approval.dispatch.patch",
                            connection_id = conn_id,
                            session_id = %session_id,
                            request_id = %request_id,
                            "Dispatching patch approval"
                        );
                        CodexAction::ApprovePatch {
                            request_id,
                            decision: decision.clone(),
                        }
                    }
                    _ => {
                        // Default to exec for exec and unknown types
                        CodexAction::ApproveExec {
                            request_id,
                            decision: decision.clone(),
                            proposed_amendment,
                        }
                    }
                };
                let _ = tx.send(action).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx
                    .send(ClaudeAction::ApproveTool {
                        request_id,
                        decision: decision.clone(),
                        message,
                        interrupt,
                        updated_input,
                    })
                    .await;
            }

            let _ = state
                .persist()
                .send(PersistCommand::SessionUpdate {
                    id: session_id.clone(),
                    status: None,
                    work_status: Some(resolved_work_status),
                    last_activity_at: None,
                })
                .await;

            send_json(
                client_tx,
                ServerMessage::ApprovalDecisionResult {
                    session_id: session_id.clone(),
                    request_id: request_id_for_result,
                    outcome: "applied".to_string(),
                    active_request_id: next_pending_request_id.clone(),
                    approval_version,
                },
            )
            .await;

            if let Some(next_pending_request_id) = next_pending_request_id {
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
