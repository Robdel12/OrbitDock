//! Claude session management
//!
//! Wraps the ClaudeConnector (bridge subprocess) and handles event forwarding.
//! Mirrors the CodexSession pattern: connector + event loop + action channel.

use std::collections::HashMap;
use std::sync::Arc;

use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::{McpAuthStatus, McpResource, McpResourceTemplate, McpTool, ServerMessage};
use serde_json::Value;
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tracing::{error, info};

use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::SessionCommand;
use crate::session_command_handler::{
    dispatch_connector_event, handle_session_command, is_turn_ending, spawn_interrupt_watchdog,
};
use crate::state::SessionRegistry;

// Re-export so existing server code doesn't break
pub use orbitdock_connector_claude::session::{
    should_remove_shadow_runtime_session, ClaudeAction, ClaudeSession,
};

/// Start the Claude session event forwarding loop.
///
/// The actor owns the `SessionHandle` directly — no `Arc<Mutex>`.
/// Returns `(SessionActorHandle, mpsc::Sender<ClaudeAction>)`.
pub fn start_event_loop(
    mut session: ClaudeSession,
    handle: SessionHandle,
    persist_tx: mpsc::Sender<PersistCommand>,
    list_tx: broadcast::Sender<ServerMessage>,
    state: Arc<SessionRegistry>,
) -> (SessionActorHandle, mpsc::Sender<ClaudeAction>) {
    let (action_tx, mut action_rx) = mpsc::channel::<ClaudeAction>(100);
    let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

    let snapshot = handle.snapshot_arc();
    let id = handle.id().to_string();
    handle.refresh_snapshot();

    let actor_handle = SessionActorHandle::new(id.clone(), command_tx, snapshot);

    let mut event_rx = session.connector.take_event_rx().unwrap();
    let session_id = session.session_id.clone();

    let mut session_handle = handle;
    let persist = persist_tx.clone();
    let mut claude_sdk_session_persisted = false;
    let mut first_prompt_captured = false;
    let actor_for_naming = actor_handle.clone();

    tokio::spawn(async move {
        // Watchdog channel for synthetic events (interrupt timeout)
        let (watchdog_tx, mut watchdog_rx) = mpsc::channel(4);
        let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

        loop {
            tokio::select! {
                Some(event) = event_rx.recv() => {
                    if is_turn_ending(&event) {
                        if let Some(h) = interrupt_watchdog.take() { h.abort(); }
                    }

                    // Register hook session IDs as managed threads so the hook
                    // handler doesn't create duplicate passive sessions. On --resume
                    // the CLI creates a new session_id for hooks.
                    if let ConnectorEvent::HookSessionId(ref hook_sid) = event {
                        if hook_sid != &session_id {
                            info!(
                                component = "claude_connector",
                                event = "claude.hook_session_id.registered",
                                session_id = %session_id,
                                hook_session_id = %hook_sid,
                                "Registering hook session ID as managed thread"
                            );
                            state.register_claude_thread(&session_id, hook_sid);
                            let _ = persist
                                .send(PersistCommand::CleanupClaudeShadowSession {
                                    claude_sdk_session_id: hook_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                })
                                .await;
                            if state.remove_session(hook_sid).is_some() {
                                state.broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: hook_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                });
                            }
                        }
                    }

                    // Persist the Claude SDK session ID on first opportunity
                    if !claude_sdk_session_persisted {
                        if let Some(sdk_sid) = session.connector.claude_session_id().await {
                            claude_sdk_session_persisted = true;
                            info!(
                                component = "claude_connector",
                                event = "claude.session_id.persisted",
                                session_id = %session_id,
                                claude_sdk_session_id = %sdk_sid,
                                "Persisting Claude SDK session ID"
                            );
                            let _ = persist
                                .send(PersistCommand::SetClaudeSdkSessionId {
                                    session_id: session_id.clone(),
                                    claude_sdk_session_id: sdk_sid.clone(),
                                })
                                .await;
                            state.register_claude_thread(&session_id, &sdk_sid);
                            let _ = persist
                                .send(PersistCommand::CleanupClaudeShadowSession {
                                    claude_sdk_session_id: sdk_sid.clone(),
                                    reason: "managed_direct_session".to_string(),
                                })
                                .await;
                            if should_remove_shadow_runtime_session(&session_id, &sdk_sid)
                                && state.remove_session(&sdk_sid).is_some()
                            {
                                state.broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: sdk_sid,
                                    reason: "managed_direct_session".to_string(),
                                });
                            }
                        }
                    }

                    // HookSessionId is fully handled above; skip transition
                    if !matches!(event, ConnectorEvent::HookSessionId(_)) {
                        dispatch_connector_event(
                            &session_id, event, &mut session_handle, &persist,
                        ).await;
                    }
                }

                Some(event) = watchdog_rx.recv() => {
                    dispatch_connector_event(
                        &session_id, event, &mut session_handle, &persist,
                    ).await;
                }

                Some(action) = action_rx.recv() => {
                    // Capture first user message as first_prompt
                    if !first_prompt_captured {
                        if let ClaudeAction::SendMessage { ref content, .. } = action {
                            first_prompt_captured = true;
                            let prompt = content.clone();
                            let _ = persist
                                .send(PersistCommand::ClaudePromptIncrement {
                                    id: session_id.clone(),
                                    first_prompt: Some(prompt.clone()),
                                })
                                .await;

                            let changes = orbitdock_protocol::StateChanges {
                                first_prompt: Some(Some(prompt.clone())),
                                ..Default::default()
                            };
                            let _ = actor_for_naming
                                .send(crate::session_command::SessionCommand::ApplyDelta {
                                    changes,
                                    persist_op: None,
                                })
                                .await;

                            crate::ai_naming::spawn_naming_task(
                                session_id.clone(),
                                prompt,
                                actor_for_naming.clone(),
                                persist.clone(),
                                list_tx.clone(),
                            );
                        }
                    }

                    match &action {
                        ClaudeAction::Interrupt => {
                            match session.connector.interrupt().await {
                                Ok(()) => {
                                    if let Some(h) = interrupt_watchdog.take() { h.abort(); }
                                    interrupt_watchdog = Some(spawn_interrupt_watchdog(
                                        watchdog_tx.clone(),
                                        session_id.clone(),
                                        "claude_connector",
                                    ));
                                }
                                Err(e) => {
                                    error!(
                                        component = "claude_connector",
                                        event = "claude.interrupt.failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Interrupt failed, injecting error event"
                                    );
                                    dispatch_connector_event(
                                        &session_id,
                                        ConnectorEvent::Error(format!("Interrupt failed: {e}")),
                                        &mut session_handle,
                                        &persist,
                                    ).await;
                                }
                            }
                        }
                        ClaudeAction::ListMcpTools => {
                            match session.connector.mcp_status().await {
                                Ok(response) => {
                                    let event = parse_mcp_status_response(response);
                                    dispatch_connector_event(
                                        &session_id,
                                        event,
                                        &mut session_handle,
                                        &persist,
                                    ).await;
                                }
                                Err(e) => {
                                    error!(
                                        component = "claude_connector",
                                        event = "claude.mcp_status.failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "MCP status request failed"
                                    );
                                }
                            }
                        }
                        ClaudeAction::RewindFiles { user_message_id } => {
                            dispatch_connector_event(
                                &session_id,
                                ConnectorEvent::UndoStarted { message: Some("Rewinding files...".to_string()) },
                                &mut session_handle,
                                &persist,
                            ).await;
                            match session.connector.rewind_files(user_message_id, false).await {
                                Ok(response) => {
                                    let can_rewind = response.get("canRewind").and_then(|v| v.as_bool()).unwrap_or(false);
                                    let message = if can_rewind {
                                        let files_changed = response.get("filesChanged")
                                            .and_then(|v| v.as_array())
                                            .map(|arr| arr.len())
                                            .unwrap_or(0);
                                        Some(format!("Rewound {files_changed} file(s)"))
                                    } else {
                                        let err = response.get("error").and_then(|v| v.as_str()).unwrap_or("Unknown error");
                                        Some(format!("Cannot rewind: {err}"))
                                    };
                                    dispatch_connector_event(
                                        &session_id,
                                        ConnectorEvent::UndoCompleted { success: can_rewind, message },
                                        &mut session_handle,
                                        &persist,
                                    ).await;
                                }
                                Err(e) => {
                                    dispatch_connector_event(
                                        &session_id,
                                        ConnectorEvent::UndoCompleted { success: false, message: Some(format!("Rewind failed: {e}")) },
                                        &mut session_handle,
                                        &persist,
                                    ).await;
                                }
                            }
                        }
                        _ => {
                            if let Err(e) = ClaudeSession::handle_action(&session.connector, action).await {
                                error!(
                                    component = "claude_connector",
                                    event = "claude.action.failed",
                                    session_id = %session_id,
                                    error = %e,
                                    "Failed to handle Claude action"
                                );
                            }
                        }
                    }
                }

                Some(cmd) = command_rx.recv() => {
                    handle_session_command(cmd, &mut session_handle, &persist).await;
                }

                else => break,
            }
        }

        if let Some(h) = interrupt_watchdog.take() {
            h.abort();
        }
        state.remove_claude_action_tx(&session_id);

        info!(
            component = "claude_connector",
            event = "claude.event_loop.ended",
            session_id = %session_id,
            "Claude session event loop ended"
        );
    });

    (actor_handle, action_tx)
}

/// Parse the mcp_status control response into a McpToolsList event.
///
/// The response from the CLI contains `mcpServers` — an array of objects with
/// `name`, `status`, `tools`, `resources`, `resourceTemplates`, and `authStatus`.
fn parse_mcp_status_response(response: Value) -> ConnectorEvent {
    let mut tools: HashMap<String, McpTool> = HashMap::new();
    let mut resources: HashMap<String, Vec<McpResource>> = HashMap::new();
    let mut resource_templates: HashMap<String, Vec<McpResourceTemplate>> = HashMap::new();
    let mut auth_statuses: HashMap<String, McpAuthStatus> = HashMap::new();

    let empty_obj = Value::Object(Default::default());

    let servers = response
        .get("mcpServers")
        .or_else(|| response.get("mcp_servers"))
        .and_then(Value::as_array);

    if let Some(servers) = servers {
        for server in servers {
            let name = server
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string();

            // Parse tools
            if let Some(server_tools) = server.get("tools").and_then(Value::as_array) {
                for tool in server_tools {
                    let tool_name = tool
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_string();
                    let description = tool
                        .get("description")
                        .and_then(Value::as_str)
                        .map(String::from);
                    let input_schema = tool
                        .get("inputSchema")
                        .or_else(|| tool.get("input_schema"))
                        .cloned()
                        .unwrap_or_else(|| empty_obj.clone());
                    tools.insert(
                        format!("{name}:{tool_name}"),
                        McpTool {
                            name: tool_name,
                            title: None,
                            description,
                            input_schema,
                            output_schema: None,
                            annotations: None,
                        },
                    );
                }
            }

            // Parse resources
            if let Some(server_resources) = server.get("resources").and_then(Value::as_array) {
                let parsed: Vec<McpResource> = server_resources
                    .iter()
                    .filter_map(|r| {
                        Some(McpResource {
                            uri: r.get("uri").and_then(Value::as_str)?.to_string(),
                            name: r
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            title: r.get("title").and_then(Value::as_str).map(String::from),
                            description: r
                                .get("description")
                                .and_then(Value::as_str)
                                .map(String::from),
                            mime_type: r.get("mimeType").and_then(Value::as_str).map(String::from),
                            size: None,
                            annotations: None,
                        })
                    })
                    .collect();
                if !parsed.is_empty() {
                    resources.insert(name.clone(), parsed);
                }
            }

            // Parse resource templates
            if let Some(server_templates) =
                server.get("resourceTemplates").and_then(Value::as_array)
            {
                let parsed: Vec<McpResourceTemplate> = server_templates
                    .iter()
                    .filter_map(|t| {
                        Some(McpResourceTemplate {
                            uri_template: t.get("uriTemplate").and_then(Value::as_str)?.to_string(),
                            name: t
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            title: None,
                            description: t
                                .get("description")
                                .and_then(Value::as_str)
                                .map(String::from),
                            mime_type: t.get("mimeType").and_then(Value::as_str).map(String::from),
                            annotations: None,
                        })
                    })
                    .collect();
                if !parsed.is_empty() {
                    resource_templates.insert(name.clone(), parsed);
                }
            }

            // Parse auth status
            if let Some(auth) = server.get("authStatus").and_then(Value::as_str) {
                let status = match auth {
                    "not_logged_in" | "notLoggedIn" => McpAuthStatus::NotLoggedIn,
                    "bearer_token" | "bearerToken" => McpAuthStatus::BearerToken,
                    "oauth" => McpAuthStatus::OAuth,
                    _ => McpAuthStatus::Unsupported,
                };
                auth_statuses.insert(name.clone(), status);
            }
        }
    }

    ConnectorEvent::McpToolsList {
        tools,
        resources,
        resource_templates,
        auth_statuses,
    }
}
