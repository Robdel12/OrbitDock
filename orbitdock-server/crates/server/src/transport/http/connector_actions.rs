use std::collections::HashMap;
use std::sync::Arc;

use axum::{http::StatusCode, Json};
use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_protocol::{
    McpAuthStatus, McpResource, McpResourceTemplate, McpTool, RemoteSkillSummary, ServerMessage,
    SkillErrorInfo, SkillsListEntry,
};
use tokio::sync::{broadcast, oneshot};

use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_commands::{SessionCommand, SubscribeResult};
use crate::runtime::session_registry::SessionRegistry;

use super::errors::{ApiErrorResponse, ApiInnerResult};

#[derive(Debug)]
enum CodexActionError {
    SessionNotFound,
    ConnectorNotAvailable,
    ChannelClosed,
    Timeout,
}

const CODEX_ACTION_WAIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);

pub(crate) fn messaging_dispatch_error_response(
    error: crate::runtime::message_dispatch::DispatchMessageError,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        crate::runtime::message_dispatch::DispatchMessageError::NotFound => (
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!(
                    "Session {} not found or has no active connector",
                    session_id
                ),
            }),
        ),
    }
}

pub(crate) fn dispatch_error_response(
    code: &'static str,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match code {
        "not_found" => session_not_found_error(session_id),
        "invalid_answer_payload" => (
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_answer_payload",
                error: "Question approvals require a non-empty answer or answers map".to_string(),
            }),
        ),
        "rollback_failed" => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(ApiErrorResponse {
                code: "rollback_failed",
                error: "Could not find user message for rollback".to_string(),
            }),
        ),
        _ => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code,
                error: format!("Operation failed for session {}", session_id),
            }),
        ),
    }
}

pub(crate) fn session_not_found_error(session_id: &str) -> (StatusCode, Json<ApiErrorResponse>) {
    (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
            code: "not_found",
            error: format!(
                "Session {} not found or has no active connector",
                session_id
            ),
        }),
    )
}

pub(crate) async fn subscribe_session_events(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> ApiInnerResult<broadcast::Receiver<ServerMessage>> {
    let actor = state.get_session(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::SessionNotFound, session_id)
    })?;

    let (reply_tx, reply_rx) = oneshot::channel();
    actor
        .send(SessionCommand::Subscribe {
            since_revision: None,
            reply: reply_tx,
        })
        .await;

    match reply_rx.await {
        Ok(SubscribeResult::Snapshot { rx, .. }) | Ok(SubscribeResult::Replay { rx, .. }) => Ok(rx),
        Err(_) => Err(codex_action_error_response(
            CodexActionError::ChannelClosed,
            session_id,
        )),
    }
}

pub(crate) async fn dispatch_codex_action(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    action: CodexAction,
) -> ApiInnerResult<()> {
    let tx = state.get_codex_action_tx(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::ConnectorNotAvailable, session_id)
    })?;

    tx.send(action)
        .await
        .map_err(|_| codex_action_error_response(CodexActionError::ChannelClosed, session_id))
}

pub(crate) async fn dispatch_claude_action(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    action: ClaudeAction,
) -> ApiInnerResult<()> {
    let tx = state.get_claude_action_tx(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::ConnectorNotAvailable, session_id)
    })?;

    tx.send(action)
        .await
        .map_err(|_| codex_action_error_response(CodexActionError::ChannelClosed, session_id))
}

pub(crate) async fn wait_for_codex_skills_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<(Vec<SkillsListEntry>, Vec<SkillErrorInfo>)> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::SkillsList {
                    session_id: sid,
                    skills,
                    errors,
                }) if sid == session_id => return Ok((skills, errors)),
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

pub(crate) async fn wait_for_remote_skills_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<Vec<RemoteSkillSummary>> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::RemoteSkillsList {
                    session_id: sid,
                    skills,
                }) if sid == session_id => return Ok(skills),
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

type McpToolsEvent = (
    HashMap<String, McpTool>,
    HashMap<String, Vec<McpResource>>,
    HashMap<String, Vec<McpResourceTemplate>>,
    HashMap<String, McpAuthStatus>,
);

pub(crate) async fn wait_for_mcp_tools_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<McpToolsEvent> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::McpToolsList {
                    session_id: sid,
                    tools,
                    resources,
                    resource_templates,
                    auth_statuses,
                }) if sid == session_id => {
                    return Ok((tools, resources, resource_templates, auth_statuses));
                }
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

fn codex_action_error_response(
    error: CodexActionError,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        CodexActionError::SessionNotFound => (
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {session_id} not found"),
            }),
        ),
        CodexActionError::ConnectorNotAvailable => (
            StatusCode::CONFLICT,
            Json(ApiErrorResponse {
                code: "session_not_found",
                error: format!("Session {session_id} not found or has no active connector"),
            }),
        ),
        CodexActionError::ChannelClosed => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "channel_closed",
                error: format!("Session {session_id} connector channel is closed"),
            }),
        ),
        CodexActionError::Timeout => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(ApiErrorResponse {
                code: "timeout",
                error: format!("Timed out waiting for session {session_id} response"),
            }),
        ),
    }
}
