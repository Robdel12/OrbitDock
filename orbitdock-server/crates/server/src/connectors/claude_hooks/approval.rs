use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;

pub(crate) fn claude_permission_request_id(
    actor: Option<&SessionActorHandle>,
    tool_name: &str,
    tool_use_id: Option<&str>,
) -> String {
    if let Some(tool_use_id) = normalized_non_empty(tool_use_id) {
        return format!("claude-perm-tooluse-{tool_use_id}");
    }

    if let Some(existing_id) = actor
        .and_then(|actor| normalized_non_empty(actor.snapshot().pending_approval_id.as_deref()))
    {
        return existing_id;
    }

    format!(
        "claude-perm-{}-{}",
        tool_name,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    )
}

pub(crate) fn classify_permission_request(
    tool_name: &str,
) -> (
    orbitdock_protocol::ApprovalType,
    orbitdock_protocol::WorkStatus,
    &'static str,
) {
    match tool_name {
        "AskUserQuestion" => (
            orbitdock_protocol::ApprovalType::Question,
            orbitdock_protocol::WorkStatus::Question,
            "awaitingQuestion",
        ),
        "Edit" | "Write" | "NotebookEdit" => (
            orbitdock_protocol::ApprovalType::Patch,
            orbitdock_protocol::WorkStatus::Permission,
            "awaitingPermission",
        ),
        _ => (
            orbitdock_protocol::ApprovalType::Exec,
            orbitdock_protocol::WorkStatus::Permission,
            "awaitingPermission",
        ),
    }
}

pub(crate) fn extract_question_from_tool_input(tool_input: Option<&Value>) -> Option<String> {
    let input = tool_input?;
    if let Some(q) = input.get("question").and_then(|value| value.as_str()) {
        return Some(q.to_string());
    }

    input
        .get("questions")
        .and_then(|value| value.as_array())
        .and_then(|items| items.first())
        .and_then(|question| question.get("question"))
        .and_then(|value| value.as_str())
        .map(String::from)
}

pub(crate) fn extract_plan_from_tool_input(tool_input: Option<&Value>) -> Option<String> {
    let input = tool_input?;
    input
        .get("plan")
        .and_then(|value| value.as_str())
        .or_else(|| input.get("current_plan").and_then(|value| value.as_str()))
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToString::to_string)
}

pub(crate) async fn resolve_pending_approvals_after_tool_outcome(
    actor: &SessionActorHandle,
    persist_tx: &mpsc::Sender<PersistCommand>,
    session_id: &str,
    decision: &str,
    fallback_work_status: orbitdock_protocol::WorkStatus,
) {
    loop {
        let Some(request_id) =
            normalized_non_empty(actor.snapshot().pending_approval_id.as_deref())
        else {
            break;
        };

        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::ResolvePendingApproval {
                request_id: request_id.clone(),
                fallback_work_status,
                reply: reply_tx,
            })
            .await;

        let Ok(resolution) = reply_rx.await else {
            break;
        };

        if resolution.approval_type.is_none() {
            break;
        }

        let _ = persist_tx
            .send(PersistCommand::ApprovalDecision {
                session_id: session_id.to_string(),
                request_id,
                decision: decision.to_string(),
            })
            .await;

        let _ = persist_tx
            .send(PersistCommand::SessionUpdate {
                id: session_id.to_string(),
                status: None,
                work_status: Some(resolution.work_status),
                last_activity_at: None,
            })
            .await;

        if resolution.next_pending_approval.is_none() {
            break;
        }
    }
}

fn normalized_non_empty(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}
