use std::sync::Arc;

use tokio::sync::mpsc;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_rest_only_error, OutboundMessage};
use orbitdock_protocol::ClientMessage;

/// Handles Claude Code hook events forwarded over WebSocket.
///
/// Most variants delegate directly to `hook_handler::handle_hook_message`,
/// which processes the event against the session registry. The
/// `GetSubagentTools` variant is a REST-only endpoint and returns an error
/// directing the client to the HTTP API.
pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
) {
    match msg {
        ClientMessage::ClaudeSessionStart { .. }
        | ClientMessage::ClaudeSessionEnd { .. }
        | ClientMessage::ClaudeStatusEvent { .. }
        | ClientMessage::ClaudeToolEvent { .. }
        | ClientMessage::ClaudeSubagentEvent { .. } => {
            crate::connectors::hook_handler::handle_hook_message(msg, state).await;
        }

        ClientMessage::GetSubagentTools {
            session_id,
            subagent_id,
        } => {
            let _ = subagent_id;
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/subagents/{subagent_id}/tools",
                Some(session_id),
            )
            .await;
        }

        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::transport::websocket::test_support::new_test_state;
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ClientMessage, Provider, WorkStatus};
    use tokio::sync::mpsc;

    #[tokio::test(flavor = "current_thread")]
    async fn claude_tool_event_bootstraps_session_with_transcript_path() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-tool-bootstrap".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        handle(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd: cwd.clone(),
                hook_event_name: "PreToolUse".to_string(),
                tool_name: "Read".to_string(),
                tool_input: None,
                tool_response: None,
                tool_use_id: None,
                permission_suggestions: None,
                error: None,
                is_interrupt: None,
                permission_mode: None,
            },
            &client_tx,
            &state,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();

        assert_eq!(snapshot.provider, Provider::Claude);
        assert_eq!(snapshot.work_status, WorkStatus::Working);
        let transcript_path = snapshot
            .transcript_path
            .clone()
            .expect("transcript path should be derived");
        assert!(
            transcript_path.ends_with(
                "/.claude/projects/-Users-tester-Developer-sample/claude-tool-bootstrap.jsonl"
            ),
            "unexpected transcript path: {}",
            transcript_path
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn claude_post_tool_failure_interrupt_clears_pending_approval_queue() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-clear-pending-on-failure".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        for tool_use_id in ["tool-a", "tool-b"] {
            handle(
                ClientMessage::ClaudeToolEvent {
                    session_id: session_id.clone(),
                    cwd: cwd.clone(),
                    hook_event_name: "PermissionRequest".to_string(),
                    tool_name: "Bash".to_string(),
                    tool_input: Some(serde_json::json!({"command":"echo test"})),
                    tool_response: None,
                    tool_use_id: Some(tool_use_id.to_string()),
                    permission_suggestions: None,
                    error: None,
                    is_interrupt: None,
                    permission_mode: None,
                },
                &client_tx,
                &state,
            )
            .await;
        }

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let before = actor.snapshot();
        assert!(before.pending_approval_id.is_some());

        handle(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd,
                hook_event_name: "PostToolUseFailure".to_string(),
                tool_name: "Bash".to_string(),
                tool_input: Some(serde_json::json!({"command":"echo test"})),
                tool_response: None,
                tool_use_id: Some("tool-b".to_string()),
                permission_suggestions: None,
                error: Some("interrupted".to_string()),
                is_interrupt: Some(true),
                permission_mode: None,
            },
            &client_tx,
            &state,
        )
        .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let after = actor.snapshot();
        assert_eq!(after.pending_approval_id, None);
        assert_eq!(after.work_status, WorkStatus::Working);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn claude_pre_tool_use_does_not_resolve_pending_approval() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-pretool-keeps-pending".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        handle(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd: cwd.clone(),
                hook_event_name: "PermissionRequest".to_string(),
                tool_name: "Edit".to_string(),
                tool_input: Some(serde_json::json!({"file_path":"/tmp/demo.txt"})),
                tool_response: None,
                tool_use_id: Some("perm-a".to_string()),
                permission_suggestions: None,
                error: None,
                is_interrupt: None,
                permission_mode: None,
            },
            &client_tx,
            &state,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let before = actor.snapshot();
        assert_eq!(
            before.pending_approval_id.as_deref(),
            Some("claude-perm-tooluse-perm-a")
        );

        handle(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd,
                hook_event_name: "PreToolUse".to_string(),
                tool_name: "Bash".to_string(),
                tool_input: Some(serde_json::json!({"command":"echo unrelated"})),
                tool_response: None,
                tool_use_id: Some("tool-other".to_string()),
                permission_suggestions: None,
                error: None,
                is_interrupt: None,
                permission_mode: None,
            },
            &client_tx,
            &state,
        )
        .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let after = actor.snapshot();
        assert_eq!(
            after.pending_approval_id.as_deref(),
            Some("claude-perm-tooluse-perm-a")
        );
    }

    #[tokio::test]
    async fn claude_user_prompt_sets_first_prompt() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-name-on-prompt".to_string();

        handle(
            ClientMessage::ClaudeStatusEvent {
                session_id: session_id.clone(),
                cwd: Some("/Users/tester/repo".to_string()),
                transcript_path: Some(
                    "/Users/tester/.claude/projects/-Users-tester-repo/claude-name-on-prompt.jsonl"
                        .to_string(),
                ),
                hook_event_name: "UserPromptSubmit".to_string(),
                notification_type: None,
                tool_name: None,
                stop_hook_active: None,
                prompt: Some(
                    "Investigate flaky auth and propose a safe migration plan".to_string(),
                ),
                message: None,
                title: None,
                trigger: None,
                custom_instructions: None,
                permission_mode: None,
                last_assistant_message: None,
                teammate_name: None,
                team_name: None,
                task_id: None,
                task_subject: None,
                task_description: None,
                config_source: None,
                config_file_path: None,
            },
            &client_tx,
            &state,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Working);
    }
}
