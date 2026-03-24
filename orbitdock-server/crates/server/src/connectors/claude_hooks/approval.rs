use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

use crate::domain::sessions::session::SessionSnapshot;
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
    if tool_name == "AskUserQuestion" {
        return (
            orbitdock_protocol::ApprovalType::Question,
            orbitdock_protocol::WorkStatus::Question,
            "awaitingQuestion",
        );
    }

    if orbitdock_connector_claude::is_accept_edits_tool(tool_name) {
        return (
            orbitdock_protocol::ApprovalType::Patch,
            orbitdock_protocol::WorkStatus::Permission,
            "awaitingPermission",
        );
    }

    (
        orbitdock_protocol::ApprovalType::Exec,
        orbitdock_protocol::WorkStatus::Permission,
        "awaitingPermission",
    )
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

pub(crate) struct PermissionRequestSnapshotMatch<'a> {
    pub(crate) request_id: &'a str,
    pub(crate) tool_name: &'a str,
    pub(crate) tool_input: Option<&'a str>,
    pub(crate) question: Option<&'a str>,
    pub(crate) work_status: orbitdock_protocol::WorkStatus,
    pub(crate) permission_mode: Option<&'a str>,
    pub(crate) plan_text: Option<&'a str>,
}

pub(crate) fn permission_request_matches_snapshot(
    snapshot: &SessionSnapshot,
    request: &PermissionRequestSnapshotMatch<'_>,
) -> bool {
    snapshot.pending_approval_id.as_deref() == Some(request.request_id)
        && snapshot.pending_tool_name.as_deref() == Some(request.tool_name)
        && snapshot.pending_tool_input.as_deref() == request.tool_input
        && snapshot.pending_question.as_deref() == request.question
        && snapshot.work_status == request.work_status
        && request
            .permission_mode
            .map(|mode| snapshot.permission_mode.as_deref() == Some(mode))
            .unwrap_or(true)
        && request
            .plan_text
            .map(|plan| snapshot.current_plan.as_deref() == Some(plan))
            .unwrap_or(true)
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
                last_progress_at: None,
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

#[cfg(test)]
mod tests {
    use orbitdock_protocol::{
        Provider, SessionStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
    };

    use super::{permission_request_matches_snapshot, PermissionRequestSnapshotMatch};
    use crate::domain::sessions::session::SessionSnapshot;

    fn snapshot() -> SessionSnapshot {
        SessionSnapshot {
            id: "session-1".to_string(),
            provider: Provider::Claude,
            status: SessionStatus::Active,
            work_status: WorkStatus::Permission,
            steerable: false,
            project_path: "/repo".to_string(),
            project_name: None,
            transcript_path: None,
            custom_name: None,
            summary: None,
            first_prompt: None,
            last_message: None,
            model: None,
            codex_integration_mode: None,
            claude_integration_mode: None,
            approval_policy: None,
            approval_policy_details: None,
            sandbox_mode: None,
            permission_mode: Some("default".to_string()),
            collaboration_mode: None,
            multi_agent: None,
            personality: None,
            service_tier: None,
            developer_instructions: None,
            codex_config_mode: None,
            codex_config_profile: None,
            codex_model_provider: None,
            codex_config_source: None,
            codex_config_overrides: None,
            has_pending_approval: true,
            pending_tool_name: Some("Bash".to_string()),
            pending_tool_input: Some("{\"command\":\"ls\"}".to_string()),
            pending_question: None,
            pending_approval_id: Some("claude-perm-tooluse-1".to_string()),
            message_count: 0,
            token_usage: TokenUsage::default(),
            token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
            started_at: None,
            last_activity_at: None,
            last_progress_at: None,
            revision: 0,
            current_plan: Some("Inspect files".to_string()),
            current_diff: None,
            git_branch: None,
            git_sha: None,
            current_cwd: None,
            effort: None,
            terminal_session_id: None,
            terminal_app: None,
            approval_version: 1,
            repository_root: None,
            is_worktree: false,
            worktree_id: None,
            has_turn_diff: false,
            subscriber_count: 0,
            unread_count: 0,
            mission_id: None,
            issue_identifier: None,
            allow_bypass_permissions: false,
            newest_synced_row_id: None,
        }
    }

    #[test]
    fn duplicate_permission_request_matches_snapshot_state() {
        let snapshot = snapshot();

        assert!(permission_request_matches_snapshot(
            &snapshot,
            &PermissionRequestSnapshotMatch {
                request_id: "claude-perm-tooluse-1",
                tool_name: "Bash",
                tool_input: Some("{\"command\":\"ls\"}"),
                question: None,
                work_status: WorkStatus::Permission,
                permission_mode: Some("default"),
                plan_text: Some("Inspect files"),
            }
        ));
    }

    #[test]
    fn changed_plan_or_permission_mode_breaks_duplicate_match() {
        let snapshot = snapshot();

        assert!(!permission_request_matches_snapshot(
            &snapshot,
            &PermissionRequestSnapshotMatch {
                request_id: "claude-perm-tooluse-1",
                tool_name: "Bash",
                tool_input: Some("{\"command\":\"ls\"}"),
                question: None,
                work_status: WorkStatus::Permission,
                permission_mode: Some("workspace-write"),
                plan_text: Some("Inspect files"),
            }
        ));
        assert!(!permission_request_matches_snapshot(
            &snapshot,
            &PermissionRequestSnapshotMatch {
                request_id: "claude-perm-tooluse-1",
                tool_name: "Bash",
                tool_input: Some("{\"command\":\"ls\"}"),
                question: None,
                work_status: WorkStatus::Permission,
                permission_mode: Some("default"),
                plan_text: Some("Run tests"),
            }
        ));
    }
}
