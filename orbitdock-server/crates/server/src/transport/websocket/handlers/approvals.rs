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
