//! WebSocket handling — connection lifecycle, message routing, and send helpers.
//!
//! Handler logic lives in `ws_handlers/`, compaction in `snapshot_compaction`,
//! session utilities in `session_utils`, and normalization in `normalization`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::IntoResponse,
};
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage, SessionState};

use crate::snapshot_compaction::{
    compact_snapshot_for_transport, replay_has_oversize_event, sanitize_replay_event_for_transport,
    sanitize_server_message_for_transport, WS_MAX_TEXT_MESSAGE_BYTES,
};
use crate::state::SessionRegistry;

static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

/// Messages that can be sent through the WebSocket
#[allow(clippy::large_enum_variant)]
pub(crate) enum OutboundMessage {
    /// JSON-serialized ServerMessage
    Json(ServerMessage),
    /// Pre-serialized JSON string (for replay)
    Raw(String),
    /// Raw pong response
    Pong(Bytes),
}

/// WebSocket upgrade handler
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<SessionRegistry>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a WebSocket connection
async fn handle_socket(socket: WebSocket, state: Arc<SessionRegistry>) {
    let conn_id = NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed);
    state.ws_connect();
    info!(
        component = "websocket",
        event = "ws.connection.opened",
        connection_id = conn_id,
        "WebSocket connection opened"
    );

    let (mut ws_tx, mut ws_rx) = socket.split();

    // Channel for sending messages to this client (supports both JSON and raw frames)
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<OutboundMessage>(100);

    // Spawn task to forward messages to WebSocket
    let send_task = tokio::spawn(async move {
        while let Some(msg) = outbound_rx.recv().await {
            let result = match msg {
                OutboundMessage::Json(server_msg) => {
                    let compacted = sanitize_server_message_for_transport(server_msg);
                    match serde_json::to_string(&compacted) {
                        Ok(json) => {
                            if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                                warn!(
                                    component = "websocket",
                                    event = "ws.send.message_dropped_oversize",
                                    connection_id = conn_id,
                                    bytes = json.len(),
                                    max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                                    "Dropped oversized server message after compaction"
                                );
                                continue;
                            }
                            ws_tx.send(Message::Text(json.into())).await
                        }
                        Err(e) => {
                            error!(
                                component = "websocket",
                                event = "ws.send.serialize_failed",
                                connection_id = conn_id,
                                error = %e,
                                "Failed to serialize server message"
                            );
                            continue;
                        }
                    }
                }
                OutboundMessage::Raw(json) => {
                    if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                        warn!(
                            component = "websocket",
                            event = "ws.send.raw_dropped_oversize",
                            connection_id = conn_id,
                            bytes = json.len(),
                            max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                            "Dropped oversized replay payload"
                        );
                        continue;
                    }
                    ws_tx.send(Message::Text(json.into())).await
                }
                OutboundMessage::Pong(data) => ws_tx.send(Message::Pong(data)).await,
            };

            if result.is_err() {
                debug!(
                    component = "websocket",
                    event = "ws.send.disconnected",
                    connection_id = conn_id,
                    "WebSocket send failed, client disconnected"
                );
                break;
            }
        }
    });

    // Wrapper to send JSON messages (used by handle_client_message)
    let client_tx = outbound_tx.clone();

    // Announce server role immediately so clients can derive control-plane routing.
    send_json(&outbound_tx, server_info_message(&state)).await;

    // Handle incoming messages
    while let Some(result) = ws_rx.next().await {
        let msg = match result {
            Ok(Message::Text(text)) => text,
            Ok(Message::Ping(data)) => {
                // Respond to ping with pong
                let _ = outbound_tx.send(OutboundMessage::Pong(data)).await;
                continue;
            }
            Ok(Message::Close(_)) => {
                info!(
                    component = "websocket",
                    event = "ws.connection.close_frame",
                    connection_id = conn_id,
                    "Client sent close frame"
                );
                break;
            }
            Ok(_) => continue,
            Err(e) => {
                warn!(
                    component = "websocket",
                    event = "ws.connection.error",
                    connection_id = conn_id,
                    error = %e,
                    "WebSocket error"
                );
                break;
            }
        };

        // Parse client message
        let client_msg: ClientMessage = match serde_json::from_str(&msg) {
            Ok(m) => m,
            Err(e) => {
                warn!(
                    component = "websocket",
                    event = "ws.message.parse_failed",
                    connection_id = conn_id,
                    error = %e,
                    payload_bytes = msg.len(),
                    payload_preview = %truncate_for_log(&msg, 240),
                    "Failed to parse client message"
                );
                send_json(
                    &client_tx,
                    ServerMessage::Error {
                        code: "parse_error".into(),
                        message: e.to_string(),
                        session_id: None,
                    },
                )
                .await;
                continue;
            }
        };

        handle_client_message(client_msg, &client_tx, &state, conn_id).await;
    }

    state.ws_disconnect();
    info!(
        component = "websocket",
        event = "ws.connection.closed",
        connection_id = conn_id,
        "WebSocket connection closed"
    );
    if state.clear_client_primary_claim(conn_id) {
        state.broadcast_to_list(server_info_message(&state));
    }
    send_task.abort();
}

fn truncate_for_log(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

/// Send a ServerMessage through the outbound channel
pub(crate) async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
    let _ = tx.send(OutboundMessage::Json(msg)).await;
}

pub(crate) async fn send_rest_only_error(
    tx: &mpsc::Sender<OutboundMessage>,
    endpoint: &str,
    session_id: Option<String>,
) {
    send_json(
        tx,
        ServerMessage::Error {
            code: "http_only_endpoint".into(),
            message: format!("Use REST endpoint {endpoint} for this request"),
            session_id,
        },
    )
    .await;
}

pub(crate) fn server_info_message(state: &SessionRegistry) -> ServerMessage {
    ServerMessage::ServerInfo {
        is_primary: state.is_primary(),
        client_primary_claims: state.active_client_primary_claims(),
    }
}

pub(crate) async fn send_replay_or_snapshot_fallback(
    tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
    events: Vec<String>,
    conn_id: u64,
) {
    let sanitized_events: Vec<String> = events
        .into_iter()
        .map(|event| {
            sanitize_replay_event_for_transport(&event).unwrap_or_else(|| {
                warn!(
                    component = "websocket",
                    event = "ws.subscribe.replay_sanitize_failed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "Failed to sanitize replay event, using original payload"
                );
                event
            })
        })
        .collect();

    if let Some(max_bytes) = replay_has_oversize_event(&sanitized_events) {
        warn!(
            component = "websocket",
            event = "ws.subscribe.replay_fallback_snapshot",
            connection_id = conn_id,
            session_id = %session_id,
            replay_count = sanitized_events.len(),
            largest_event_bytes = max_bytes,
            max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
            "Replay payload exceeded transport limit, requesting client re-bootstrap"
        );
        send_json(
            tx,
            ServerMessage::Error {
                code: "replay_oversized".to_string(),
                message:
                    "Replay payload exceeded transport limit; re-bootstrap the conversation"
                        .to_string(),
                session_id: Some(session_id.to_string()),
            },
        )
        .await;
        return;
    }

    for json in sanitized_events {
        send_raw(tx, json).await;
    }
}

pub(crate) async fn send_snapshot_if_requested(
    tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
    snapshot: SessionState,
    include_snapshot: bool,
    conn_id: u64,
) {
    if include_snapshot {
        send_json(
            tx,
            ServerMessage::SessionSnapshot {
                session: compact_snapshot_for_transport(snapshot),
            },
        )
        .await;
        return;
    }

    info!(
        component = "websocket",
        event = "ws.subscribe.snapshot_suppressed",
        connection_id = conn_id,
        session_id = %session_id,
        "Session snapshot suppressed (client requested replay-only subscribe)"
    );
}

/// Send a pre-serialized JSON string through the outbound channel (for replay)
pub(crate) async fn send_raw(tx: &mpsc::Sender<OutboundMessage>, json: String) {
    let _ = tx.send(OutboundMessage::Raw(json)).await;
}

/// Spawn a task that drains a broadcast receiver and forwards messages to an outbound channel.
/// When the outbound channel closes (client disconnects), the task exits and the
/// broadcast::Receiver is dropped — automatic cleanup, no manual unsubscribe needed.
///
/// If `session_id` is provided and the subscriber lags behind the broadcast buffer,
/// a `lagged` error is sent to the client so it can re-bootstrap the conversation.
pub(crate) fn spawn_broadcast_forwarder(
    mut rx: tokio::sync::broadcast::Receiver<ServerMessage>,
    outbound_tx: mpsc::Sender<OutboundMessage>,
    session_id: Option<String>,
) {
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(msg) => {
                    if outbound_tx.send(OutboundMessage::Json(msg)).await.is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    warn!(
                        component = "websocket",
                        event = "ws.broadcast.lagged",
                        session_id = ?session_id,
                        skipped = n,
                        "Broadcast subscriber lagged, skipped {n} messages"
                    );
                    // Notify the client so it can re-bootstrap over the paged HTTP path.
                    let _ = outbound_tx
                        .send(OutboundMessage::Json(ServerMessage::Error {
                            code: "lagged".to_string(),
                            message: format!("Subscriber lagged, skipped {n} messages"),
                            session_id: session_id.clone(),
                        }))
                        .await;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

/// Dispatch a single client WebSocket message.
///
/// Each handler group lives in its own module under , so each
/// `.await` site produces an independently-sized future. This keeps the
/// parent future small enough for the default 2 MiB thread stack in debug
/// builds.
fn handle_client_message<'a>(
    msg: ClientMessage,
    client_tx: &'a mpsc::Sender<OutboundMessage>,
    state: &'a Arc<SessionRegistry>,
    conn_id: u64,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
    Box::pin(async move {
        debug!(
            component = "websocket",
            event = "ws.message.received",
            connection_id = conn_id,
            message = ?msg,
            "Received client message"
        );

        match msg {
            // ── Subscribe ────────────────────────────────────────────
            ClientMessage::SubscribeList
            | ClientMessage::SubscribeSession { .. }
            | ClientMessage::UnsubscribeSession { .. } => {
                crate::ws_handlers::subscribe::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Session CRUD ─────────────────────────────────────────
            ClientMessage::CreateSession { .. }
            | ClientMessage::EndSession { .. }
            | ClientMessage::RenameSession { .. }
            | ClientMessage::UpdateSessionConfig { .. }
            | ClientMessage::ForkSession { .. }
            | ClientMessage::ForkSessionToWorktree { .. }
            | ClientMessage::ForkSessionToExistingWorktree { .. } => {
                crate::ws_handlers::session_crud::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Session lifecycle (resume / takeover) ────────────────
            ClientMessage::ResumeSession { .. } | ClientMessage::TakeoverSession { .. } => {
                crate::ws_handlers::session_lifecycle::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Messaging ────────────────────────────────────────────
            ClientMessage::SendMessage { .. }
            | ClientMessage::SteerTurn { .. }
            | ClientMessage::AnswerQuestion { .. }
            | ClientMessage::InterruptSession { .. }
            | ClientMessage::CompactContext { .. }
            | ClientMessage::UndoLastTurn { .. }
            | ClientMessage::RollbackTurns { .. }
            | ClientMessage::StopTask { .. }
            | ClientMessage::RewindFiles { .. } => {
                crate::ws_handlers::messaging::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Approvals ────────────────────────────────────────────
            ClientMessage::ApproveTool { .. }
            | ClientMessage::ListApprovals { .. }
            | ClientMessage::DeleteApproval { .. } => {
                crate::ws_handlers::approvals::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Config (WS-only: SetClientPrimaryClaim) ────────────
            ClientMessage::SetClientPrimaryClaim { .. } => {
                crate::ws_handlers::config::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Claude hooks ─────────────────────────────────────────
            ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. }
            | ClientMessage::GetSubagentTools { .. } => {
                crate::ws_handlers::claude_hooks::handle(msg, client_tx, state).await;
            }

            // ── Shell execution ──────────────────────────────────────
            ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => {
                crate::ws_handlers::shell::handle(msg, client_tx, state, conn_id).await;
            }

            // ── REST-only stubs ──────────────────────────────────────
            ClientMessage::BrowseDirectory { .. }
            | ClientMessage::ListRecentProjects { .. }
            | ClientMessage::CheckOpenAiKey { .. }
            | ClientMessage::FetchCodexUsage { .. }
            | ClientMessage::FetchClaudeUsage { .. }
            | ClientMessage::SetServerRole { .. }
            | ClientMessage::SetOpenAiKey { .. }
            | ClientMessage::ListModels
            | ClientMessage::ListClaudeModels
            | ClientMessage::CodexAccountRead { .. }
            | ClientMessage::CodexLoginChatgptStart
            | ClientMessage::CodexLoginChatgptCancel { .. }
            | ClientMessage::CodexAccountLogout
            | ClientMessage::ListSkills { .. }
            | ClientMessage::ListRemoteSkills { .. }
            | ClientMessage::DownloadRemoteSkill { .. }
            | ClientMessage::ListMcpTools { .. }
            | ClientMessage::RefreshMcpServers { .. }
            | ClientMessage::ListWorktrees { .. }
            | ClientMessage::CreateWorktree { .. }
            | ClientMessage::RemoveWorktree { .. }
            | ClientMessage::DiscoverWorktrees { .. }
            | ClientMessage::CreateReviewComment { .. }
            | ClientMessage::UpdateReviewComment { .. }
            | ClientMessage::DeleteReviewComment { .. }
            | ClientMessage::ListReviewComments { .. } => {
                crate::ws_handlers::rest_only::handle(msg, client_tx).await;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{handle_client_message, send_replay_or_snapshot_fallback, OutboundMessage};
    use crate::claude_session::ClaudeAction;
    use crate::codex_session::CodexAction;
    use crate::normalization::work_status_for_approval_decision;
    use crate::persistence::PersistCommand;
    use crate::session::SessionHandle;
    use crate::session_command::SessionCommand;
    use crate::session_naming::name_from_first_prompt;
    use crate::session_utils::{
        claim_codex_thread_for_direct_session, claude_transcript_path_from_cwd,
        direct_mode_activation_changes,
    };
    use crate::snapshot_compaction::{
        compact_message_for_transport, compact_snapshot_to_transport_limit,
        replay_has_oversize_event, sanitize_replay_event_for_transport,
        sanitize_server_message_for_transport, snapshot_transport_size_bytes,
        SNAPSHOT_MAX_CONTENT_CHARS, SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES, WS_MAX_TEXT_MESSAGE_BYTES,
    };
    use crate::state::SessionRegistry;
    use crate::transition::Input;
    use orbitdock_protocol::{
        new_id, ApprovalType, ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode,
        ImageInput, MentionInput, Message, MessageType, Provider, ServerMessage, SessionStatus,
        TurnDiff, WorkStatus,
    };
    use std::sync::{Arc, Once};
    use tokio::sync::mpsc;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-websocket-tests");
            crate::paths::init_data_dir(Some(&dir));
        });
    }

    #[test]
    fn approval_decisions_that_continue_tooling_stay_working() {
        assert_eq!(
            work_status_for_approval_decision("approved"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("approved_for_session"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("approved_always"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("  approved  "),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("denied"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("deny"),
            WorkStatus::Working
        );
    }

    #[test]
    fn approval_decisions_that_stop_return_to_waiting() {
        assert_eq!(
            work_status_for_approval_decision("abort"),
            WorkStatus::Waiting
        );
        assert_eq!(
            work_status_for_approval_decision("unknown_value"),
            WorkStatus::Waiting
        );
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

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_codex() {
        let changes = direct_mode_activation_changes(Provider::Codex);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.codex_integration_mode,
            Some(Some(CodexIntegrationMode::Direct))
        );
        assert_eq!(changes.claude_integration_mode, None);
    }

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_claude() {
        let changes = direct_mode_activation_changes(Provider::Claude);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.claude_integration_mode,
            Some(Some(ClaudeIntegrationMode::Direct))
        );
        assert_eq!(changes.codex_integration_mode, None);
    }

    #[test]
    fn derives_readable_name_from_first_prompt() {
        let prompt =
            "  Please investigate auth race conditions and propose a safe migration plan.  ";
        let name = name_from_first_prompt(prompt).expect("expected name");
        assert_eq!(
            name,
            "Please investigate auth race conditions and propose a safe migration pla…"
        );
    }

    #[test]
    fn derives_transcript_path_from_cwd() {
        let path =
            claude_transcript_path_from_cwd("/Users/robertdeluca/Developer/vizzly-cli", "abc-123");
        let value = path.expect("expected transcript path");
        assert!(
            value.ends_with(
                "/.claude/projects/-Users-robertdeluca-Developer-vizzly-cli/abc-123.jsonl"
            ),
            "unexpected transcript path: {}",
            value
        );
    }

    #[test]
    fn snapshot_compaction_fits_websocket_transport_limit() {
        let mut snapshot = SessionHandle::new(
            "oversized".to_string(),
            Provider::Codex,
            "/tmp/oversized".into(),
        )
        .state();

        snapshot.messages = (0..80)
            .map(|index| Message {
                id: format!("m-{index}"),
                session_id: snapshot.id.clone(),
                sequence: Some(index as u64),
                message_type: MessageType::Assistant,
                content: "A".repeat(60_000),
                tool_name: Some("bash".to_string()),
                tool_input: Some("B".repeat(20_000)),
                tool_output: Some("C".repeat(20_000)),
                is_error: false,
                is_in_progress: false,
                timestamp: "2026-01-01T00:00:00Z".to_string(),
                duration_ms: Some(123),
                images: vec![],
            })
            .collect();

        snapshot.current_diff = Some("D".repeat(120_000));
        snapshot.current_plan = Some("E".repeat(120_000));
        snapshot.pending_tool_input = Some("F".repeat(120_000));
        snapshot.pending_question = Some("G".repeat(120_000));
        snapshot.turn_diffs = (0..120)
            .map(|idx| TurnDiff {
                turn_id: format!("turn-{idx}"),
                diff: "H".repeat(120_000),
                token_usage: None,
                snapshot_kind: None,
            })
            .collect();

        let compacted = compact_snapshot_to_transport_limit(snapshot);
        let compacted_size =
            snapshot_transport_size_bytes(&compacted).expect("compacted snapshot serialized");

        assert!(
            compacted_size <= WS_MAX_TEXT_MESSAGE_BYTES,
            "expected compacted snapshot <= {} bytes, got {}",
            WS_MAX_TEXT_MESSAGE_BYTES,
            compacted_size
        );
        assert!(
            compacted_size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            "expected compacted snapshot <= {} bytes target, got {}",
            SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            compacted_size
        );
    }

    #[test]
    fn detects_oversized_replay_payloads() {
        let small = vec!["{}".to_string(), "{\"type\":\"ping\"}".to_string()];
        assert_eq!(replay_has_oversize_event(&small), None);

        let large = vec!["{}".to_string(), "X".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 1)];
        assert_eq!(
            replay_has_oversize_event(&large),
            Some(WS_MAX_TEXT_MESSAGE_BYTES + 1)
        );
    }

    #[test]
    fn snapshot_compaction_dedupes_duplicate_turn_ids() {
        let mut snapshot = SessionHandle::new(
            "dupe-turns".to_string(),
            Provider::Codex,
            "/tmp/dupe-turns".into(),
        )
        .state();
        snapshot.turn_diffs = vec![
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "old".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-21".to_string(),
                diff: "next".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "new".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
        ];

        let compacted = compact_snapshot_to_transport_limit(snapshot);
        assert_eq!(compacted.turn_diffs.len(), 2);
        assert_eq!(compacted.turn_diffs[0].turn_id, "turn-21");
        assert_eq!(compacted.turn_diffs[1].turn_id, "turn-20");
        assert_eq!(compacted.turn_diffs[1].diff, "new");
    }

    #[test]
    fn compact_message_transport_preserves_data_uri_images() {
        let mut message = Message {
            id: "m-image".to_string(),
            session_id: "s".to_string(),
            sequence: None,
            message_type: MessageType::User,
            content: "send this".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "url".to_string(),
                value: format!("data:image/png;base64,{}", "A".repeat(5_000)),
            }],
        };

        compact_message_for_transport(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);

        assert_eq!(message.images.len(), 1);
        assert_eq!(message.images[0].input_type, "url");
        assert!(message.images[0]
            .value
            .starts_with("data:image/png;base64,"));
    }

    #[test]
    fn compact_message_transport_converts_path_images_to_data_uri() {
        let image_path = std::env::temp_dir().join(format!("orbitdock-image-{}.png", new_id()));
        std::fs::write(&image_path, b"hello-image").expect("write test image");

        let mut message = Message {
            id: "m-path".to_string(),
            session_id: "s".to_string(),
            sequence: None,
            message_type: MessageType::User,
            content: "send path".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "path".to_string(),
                value: image_path.to_string_lossy().to_string(),
            }],
        };

        compact_message_for_transport(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);
        let _ = std::fs::remove_file(image_path);

        assert_eq!(message.images.len(), 1);
        assert_eq!(message.images[0].input_type, "url");
        assert_eq!(
            message.images[0].value,
            "data:image/png;base64,aGVsbG8taW1hZ2U="
        );
    }

    #[test]
    fn sanitize_message_appended_trims_oversized_images_instead_of_dropping_message() {
        let oversized_image = ImageInput {
            input_type: "url".to_string(),
            value: format!(
                "data:image/png;base64,{}",
                "A".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 512)
            ),
        };

        let message = Message {
            id: "m-large".to_string(),
            session_id: "s".to_string(),
            sequence: None,
            message_type: MessageType::User,
            content: "large image".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![oversized_image],
        };

        let sanitized = sanitize_server_message_for_transport(ServerMessage::MessageAppended {
            session_id: "s".to_string(),
            message,
        });

        let json = serde_json::to_string(&sanitized).expect("serialize sanitized message");
        assert!(
            json.len() <= WS_MAX_TEXT_MESSAGE_BYTES,
            "expected sanitized message <= {} bytes, got {}",
            WS_MAX_TEXT_MESSAGE_BYTES,
            json.len()
        );

        match sanitized {
            ServerMessage::MessageAppended { message, .. } => {
                assert!(
                    message.images.is_empty(),
                    "oversized image should be trimmed from outbound transport"
                );
            }
            other => panic!("expected MessageAppended, got {:?}", other),
        }
    }

    #[test]
    fn replay_sanitize_preserves_revision_and_normalizes_path_images() {
        let image_path =
            std::env::temp_dir().join(format!("orbitdock-replay-image-{}.png", new_id()));
        std::fs::write(&image_path, b"replay-image").expect("write test image");

        let replay_json = serde_json::json!({
            "type": "message_appended",
            "revision": 42,
            "session_id": "s",
            "message": {
                "id": "m",
                "session_id": "s",
                "message_type": "user",
                "content": "hello",
                "is_error": false,
                "timestamp": "2026-01-01T00:00:00Z",
                "images": [{
                    "input_type": "path",
                    "value": image_path.to_string_lossy().to_string(),
                }]
            }
        });

        let sanitized = sanitize_replay_event_for_transport(&replay_json.to_string())
            .expect("sanitize replay payload");
        let _ = std::fs::remove_file(image_path);

        let decoded: serde_json::Value =
            serde_json::from_str(&sanitized).expect("decode sanitized replay");
        assert_eq!(
            decoded.get("revision").and_then(|value| value.as_u64()),
            Some(42)
        );
        assert_eq!(
            decoded
                .get("message")
                .and_then(|value| value.get("images"))
                .and_then(|value| value.as_array())
                .and_then(|images| images.first())
                .and_then(|image| image.get("input_type"))
                .and_then(|value| value.as_str()),
            Some("url")
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
    async fn oversized_replay_requests_rebootstrap_error_instead_of_snapshot() {
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(4);

        send_replay_or_snapshot_fallback(
            &client_tx,
            "session-oversized",
            vec!["X".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 1)],
            42,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "replay_oversized");
                assert!(message.contains("re-bootstrap"));
                assert_eq!(session_id.as_deref(), Some("session-oversized"));
            }
            other => panic!("expected replay_oversized error, got {:?}", other),
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
    async fn check_open_ai_key_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::CheckOpenAiKey {
                request_id: "req-check-key".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/server/openai-key"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn list_recent_projects_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::ListRecentProjects {
                request_id: "req-recent-projects".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/recent-projects"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn browse_directory_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::BrowseDirectory {
                path: Some("/tmp".to_string()),
                request_id: "req-browse-dir".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/browse"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn browse_directory_missing_path_over_websocket_still_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::BrowseDirectory {
                path: Some("/definitely/missing/path".to_string()),
                request_id: "req-browse-missing".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/browse"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn set_open_ai_key_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::SetOpenAiKey {
                key: "sk-test".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error { code, message, .. } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("POST /api/server/openai-key"));
            }
            other => panic!("expected rest_only Error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn set_server_role_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::SetServerRole { is_primary: false },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error { code, message, .. } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("PUT /api/server/role"));
            }
            other => panic!("expected rest_only Error, got {:?}", other),
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
    async fn codex_usage_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::FetchCodexUsage {
                request_id: "req-codex".to_string(),
            },
            &client_tx,
            &state,
            11,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/usage/codex"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn claude_usage_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::FetchClaudeUsage {
                request_id: "req-claude".to_string(),
            },
            &client_tx,
            &state,
            15,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/usage/claude"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
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
