//! WebSocket handling — connection lifecycle, message routing, and send helpers.
//!
//! Handler logic lives in `ws_handlers/`, compaction in `snapshot_compaction`,
//! session utilities in `session_utils`, and normalization in `normalization`.

mod connection;
pub(crate) mod handlers;
mod message_groups;
mod rest_only_policy;
mod router;
mod server_info;
mod transport;

pub use connection::ws_handler;
pub(crate) use router::handle_client_message;
pub(crate) use server_info::server_info_message;
pub(crate) use transport::{
    send_json, send_replay_or_snapshot_fallback, send_rest_only_error, send_snapshot_if_requested,
    spawn_broadcast_forwarder, OutboundMessage,
};

#[cfg(test)]
mod tests {
    use super::{handle_client_message, OutboundMessage};
    use crate::connectors::claude_session::ClaudeAction;
    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::SessionHandle;
    use crate::domain::sessions::transition::Input;
    use crate::infrastructure::persistence::PersistCommand;
    use crate::runtime::session_commands::SessionCommand;
    use crate::runtime::session_registry::SessionRegistry;
    use crate::runtime::session_runtime_helpers::claim_codex_thread_for_direct_session;
    use orbitdock_protocol::{
        ApprovalType, ClientMessage, CodexIntegrationMode, ImageInput, MentionInput, Message,
        MessageType, Provider, ServerMessage, SessionStatus, WorkStatus,
    };
    use std::sync::{Arc, Once};
    use tokio::sync::mpsc;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-server-test-data");
            let _ = std::fs::remove_dir_all(&dir);
            crate::infrastructure::paths::init_data_dir(Some(&dir));
        });
    }

    async fn queue_codex_exec_approval(
        state: &Arc<SessionRegistry>,
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

        handle_client_message(
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

        // The server now sends an ApprovalDecisionResult on success
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
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );

        handle_client_message(
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
        assert_eq!(
            snapshot.pending_approval_id, None,
            "pending approval should be cleared after decision"
        );
        assert_eq!(
            snapshot.work_status,
            WorkStatus::Working,
            "denied decisions should stay working until connector emits turn completion/abort"
        );

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

        handle_client_message(
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
                assert_eq!(
                    active_request_id.as_deref(),
                    Some("req-1"),
                    "stale result should include the active request id"
                );
            }
            other => panic!(
                "expected ApprovalDecisionResult with stale outcome, got {:?}",
                other
            ),
        }

        assert!(
            action_rx.try_recv().is_err(),
            "stale approvals must not dispatch connector approval actions"
        );

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );
    }

    fn new_test_state() -> Arc<SessionRegistry> {
        ensure_test_data_dir();
        let (persist_tx, _persist_rx) = mpsc::channel(128);
        Arc::new(SessionRegistry::new(persist_tx))
    }

    #[tokio::test]
    async fn claim_codex_thread_ends_shadow_runtime_session_and_persists_cleanup() {
        ensure_test_data_dir();
        let (persist_tx, mut persist_rx) = mpsc::channel(16);
        let state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        let mut list_rx = state.subscribe_list();
        let direct_session_id = "od-direct-session".to_string();
        let shadow_thread_id = "019-shadow-thread".to_string();

        let mut direct = SessionHandle::new(
            direct_session_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        direct.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        state.add_session(direct);

        let mut shadow = SessionHandle::new(
            shadow_thread_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        shadow.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
        state.add_session(shadow);

        claim_codex_thread_for_direct_session(
            &state,
            &persist_tx,
            &direct_session_id,
            &shadow_thread_id,
            "test_shadow_cleanup",
        )
        .await;

        assert_eq!(
            state.codex_thread_for_session(&direct_session_id),
            Some(shadow_thread_id.clone())
        );
        assert!(
            state.get_session(&shadow_thread_id).is_none(),
            "shadow runtime session should be removed"
        );

        match list_rx.recv().await.expect("expected list broadcast") {
            ServerMessage::SessionEnded { session_id, reason } => {
                assert_eq!(session_id, shadow_thread_id);
                assert_eq!(reason, "direct_session_thread_claimed");
            }
            other => panic!("expected SessionEnded broadcast, got {:?}", other),
        }

        match persist_rx
            .recv()
            .await
            .expect("expected SetThreadId command")
        {
            PersistCommand::SetThreadId {
                session_id,
                thread_id,
            } => {
                assert_eq!(session_id, direct_session_id);
                assert_eq!(thread_id, "019-shadow-thread");
            }
            other => panic!("expected SetThreadId command, got {:?}", other),
        }
        match persist_rx
            .recv()
            .await
            .expect("expected CleanupThreadShadowSession command")
        {
            PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
                assert_eq!(thread_id, "019-shadow-thread");
                assert_eq!(reason, "test_shadow_cleanup");
            }
            other => panic!("expected CleanupThreadShadowSession, got {:?}", other),
        }
    }

    async fn recv_json(client_rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
        match client_rx.recv().await.expect("expected outbound message") {
            OutboundMessage::Json(msg) => msg,
            OutboundMessage::Raw(_) => panic!("expected JSON message, got raw payload"),
            OutboundMessage::Pong(_) => panic!("expected JSON message, got pong"),
        }
    }

    #[tokio::test]
    async fn subscribe_session_can_stream_without_initial_snapshot() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        state.add_session(handle);

        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        handle_client_message(
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

    #[tokio::test]
    async fn set_client_primary_claim_updates_server_info() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::SetClientPrimaryClaim {
                client_id: "device-1".to_string(),
                device_name: "Robert's iPhone".to_string(),
                is_primary: true,
            },
            &client_tx,
            &state,
            7,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::ServerInfo {
                is_primary,
                client_primary_claims,
            } => {
                assert!(is_primary);
                assert_eq!(client_primary_claims.len(), 1);
                assert_eq!(client_primary_claims[0].client_id, "device-1");
                assert_eq!(client_primary_claims[0].device_name, "Robert's iPhone");
            }
            other => panic!("expected ServerInfo, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn ending_passive_session_keeps_it_available_for_reactivation() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "passive-end-keep".to_string();

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
        }

        handle_client_message(
            ClientMessage::EndSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;
        // Yield so the actor processes queued commands
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("passive session should remain in app state");

        let snap = actor.snapshot();
        assert_eq!(snap.status, SessionStatus::Ended);
        assert_eq!(snap.work_status, WorkStatus::Ended);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn claude_tool_event_bootstraps_session_with_transcript_path() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-tool-bootstrap".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        handle_client_message(
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
            1,
        )
        .await;

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
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

        // Queue two pending approvals to reproduce stale passive hook state.
        for tool_use_id in ["tool-a", "tool-b"] {
            handle_client_message(
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
                1,
            )
            .await;
        }

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let before = actor.snapshot();
        assert!(
            before.pending_approval_id.is_some(),
            "permission requests should queue a pending approval"
        );

        handle_client_message(
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
            1,
        )
        .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let after = actor.snapshot();
        assert_eq!(
            after.pending_approval_id, None,
            "interrupting a failed tool run should clear stale pending approvals"
        );
        assert_eq!(
            after.work_status,
            WorkStatus::Working,
            "session should continue in working state after interrupt handling"
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn claude_pre_tool_use_does_not_resolve_pending_approval() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-pretool-keeps-pending".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        handle_client_message(
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
            1,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let before = actor.snapshot();
        assert_eq!(
            before.pending_approval_id.as_deref(),
            Some("claude-perm-tooluse-perm-a"),
            "permission request should enqueue a pending approval"
        );

        handle_client_message(
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
            1,
        )
        .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let after = actor.snapshot();
        assert_eq!(
            after.pending_approval_id.as_deref(),
            Some("claude-perm-tooluse-perm-a"),
            "pre-tool hooks should not resolve pending approvals; only tool outcome hooks may do that"
        );
    }

    #[tokio::test]
    async fn claude_user_prompt_sets_first_prompt() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-name-on-prompt".to_string();

        handle_client_message(
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
            1,
        )
        .await;

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Working);
    }

    #[tokio::test]
    async fn codex_send_message_ignores_bootstrap_prompt_for_naming() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "codex-name-on-prompt".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        // Bootstrap prompt should be skipped
        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        // Real prompt should set first_prompt
        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "Investigate flaky auth and propose a safe migration plan".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        // Yield to let the actor process the ApplyDelta command
        tokio::task::yield_now().await;

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();

        // first_prompt is set (not custom_name — AI naming sets summary asynchronously)
        assert_eq!(
            snapshot.first_prompt.as_deref(),
            Some("Investigate flaky auth and propose a safe migration plan")
        );
        assert_eq!(snapshot.work_status, WorkStatus::Working);
    }

    #[tokio::test]
    async fn send_message_does_not_mark_working_when_action_channel_is_closed() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-closed-channel".to_string();
        let (action_tx, action_rx) = mpsc::channel(1);

        drop(action_rx);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Waiting);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected codex action");
        match action {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Claude,
                "/Users/tester/repo".to_string(),
            ));
            state.set_claude_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected claude action");
        match action {
            ClaudeAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_and_mentions_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![MentionInput {
                    name: "main.rs".to_string(),
                    path: "/project/src/main.rs".to_string(),
                }],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected codex action");
        match action {
            CodexAction::SteerTurn {
                images, mentions, ..
            } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
                assert_eq!(mentions.len(), 1);
                assert_eq!(mentions[0].name, "main.rs");
                assert_eq!(mentions[0].path, "/project/src/main.rs");
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Claude,
                "/Users/tester/repo".to_string(),
            ));
            state.set_claude_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected claude action");
        match action {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn send_message_without_effort_preserves_existing_effort() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-preserve".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.apply_changes(&orbitdock_protocol::StateChanges {
                effort: Some(Some("xhigh".to_string())),
                ..Default::default()
            });
            state.add_session(handle);
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("xhigh"));
    }

    #[tokio::test]
    async fn send_message_with_model_override_updates_session_model() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-model-override".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_model(Some("openai".to_string()));
            state.add_session(handle);
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
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
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.model.as_deref(), Some("gpt-5.3-codex"));
    }

    #[tokio::test]
    async fn send_message_with_effort_override_updates_codex_session_effort() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-override-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.apply_changes(&orbitdock_protocol::StateChanges {
                effort: Some(Some("xhigh".to_string())),
                ..Default::default()
            });
            state.add_session(handle);
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: Some("high".to_string()),
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected codex action");
        match action {
            CodexAction::SendMessage { effort, .. } => {
                assert_eq!(effort.as_deref(), Some("high"));
            }
            other => panic!("expected Codex send action, got {:?}", other),
        }

        tokio::task::yield_now().await;
        let actor = state
            .get_session(&session_id)
            .expect("session should exist after send");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("high"));
    }

    #[tokio::test]
    async fn send_message_with_effort_override_ignored_for_claude() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-override-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Claude,
                "/Users/tester/repo".to_string(),
            );
            handle.apply_changes(&orbitdock_protocol::StateChanges {
                effort: Some(Some("xhigh".to_string())),
                ..Default::default()
            });
            state.add_session(handle);
            state.set_claude_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: Some("high".to_string()),
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected claude action");
        match action {
            ClaudeAction::SendMessage { effort, .. } => {
                assert_eq!(effort, None);
            }
            other => panic!("expected Claude send action, got {:?}", other),
        }

        tokio::task::yield_now().await;
        let actor = state
            .get_session(&session_id)
            .expect("session should exist after send");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("xhigh"));
    }
}
