use std::sync::Arc;

use tokio::sync::oneshot;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::normalization::work_status_for_approval_decision;

pub(crate) struct ApprovalDispatchResult {
    pub outcome: String,
    pub active_request_id: Option<String>,
    pub approval_version: u64,
}

pub(crate) async fn dispatch_approve_tool(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    request_id: String,
    decision: String,
    message: Option<String>,
    interrupt: Option<bool>,
    updated_input: Option<serde_json::Value>,
) -> Result<ApprovalDispatchResult, &'static str> {
    let fallback_work_status = work_status_for_approval_decision(&decision);
    let mut resolved_work_status = fallback_work_status;

    let (approval_type, proposed_amendment, next_pending_request_id, approval_version) =
        if let Some(actor) = state.get_session(session_id) {
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
            return Err("not_found");
        };

    if state.get_session(session_id).is_some() && approval_type.is_none() {
        return Ok(ApprovalDispatchResult {
            outcome: "stale".to_string(),
            active_request_id: next_pending_request_id,
            approval_version,
        });
    }

    let _ = state
        .persist()
        .send(PersistCommand::ApprovalDecision {
            session_id: session_id.to_string(),
            request_id: request_id.clone(),
            decision: decision.clone(),
        })
        .await;

    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let action = match approval_type {
            Some(orbitdock_protocol::ApprovalType::Patch) => CodexAction::ApprovePatch {
                request_id,
                decision: decision.clone(),
            },
            _ => CodexAction::ApproveExec {
                request_id,
                decision: decision.clone(),
                proposed_amendment,
            },
        };
        let _ = tx.send(action).await;
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
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
            id: session_id.to_string(),
            status: None,
            work_status: Some(resolved_work_status),
            last_activity_at: None,
        })
        .await;

    Ok(ApprovalDispatchResult {
        outcome: "applied".to_string(),
        active_request_id: next_pending_request_id,
        approval_version,
    })
}
