use std::collections::HashMap;
use std::sync::Arc;

mod approvals;
mod codex_auth;
mod files;
mod permissions;
mod review_comments;
mod router;
mod server_info;
mod session_actions;
mod session_lifecycle;
mod sessions;
mod worktrees;

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use orbitdock_connector_codex::discover_models;
use orbitdock_protocol::{
    ApprovalHistoryItem, ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption,
    CodexUsageSnapshot, ImageInput, McpAuthStatus, McpResource, McpResourceTemplate, McpTool,
    MentionInput, Message, RemoteSkillSummary, ServerMessage, SessionState, SessionSummary,
    SkillErrorInfo, SkillInput, SkillsListEntry, UsageErrorInfo,
};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, oneshot};
use tracing::{error, info};

use crate::codex_session::CodexAction;
use crate::persistence::{
    delete_approval, list_approvals, load_cached_claude_models, load_messages_for_session,
    PersistCommand,
};
use crate::session_command::{SessionCommand, SubscribeResult};
use crate::session_history::{
    load_conversation_bootstrap, load_conversation_page, load_full_session_state, SessionLoadError,
};
use crate::state::SessionRegistry;
use orbitdock_connector_claude::session::ClaudeAction;

pub use approvals::{
    answer_question, approve_tool, delete_approval_endpoint, list_approvals_endpoint,
};
pub use codex_auth::{codex_login_cancel, codex_login_start, codex_logout, read_codex_account};
pub use files::{
    browse_directory, git_init_endpoint, list_recent_projects, list_subagent_tools_endpoint,
};
pub use permissions::{add_permission_rule, get_permission_rules, remove_permission_rule};
pub use review_comments::{
    create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
    update_review_comment,
};
pub use router::build_router;
pub use server_info::{
    check_open_ai_key, not_control_plane_endpoint_error, set_client_primary_claim, set_open_ai_key,
    set_server_role,
};
pub use session_actions::{
    compact_context, get_session_image_attachment, interrupt_session, post_session_message,
    post_steer_turn, rewind_files, rollback_turns, stop_task, undo_last_turn,
    upload_session_image_attachment, AcceptedResponse,
};
pub use session_lifecycle::{
    create_session, end_session, fork_session, fork_session_to_existing_worktree,
    fork_session_to_worktree, rename_session, resume_session, takeover_session,
    update_session_config,
};
pub use sessions::{
    get_conversation_bootstrap, get_conversation_history, get_session, list_sessions,
    mark_session_read,
};
pub use worktrees::{create_worktree, discover_worktrees, list_worktrees, remove_worktree};

#[derive(Debug, Serialize)]
pub struct CodexUsageResponse {
    pub usage: Option<CodexUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeUsageResponse {
    pub usage: Option<ClaudeUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct CodexModelsResponse {
    pub models: Vec<CodexModelOption>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeModelsResponse {
    pub models: Vec<ClaudeModelOption>,
}

#[derive(Debug, Serialize)]
pub struct SkillsResponse {
    pub session_id: String,
    pub skills: Vec<SkillsListEntry>,
    pub errors: Vec<SkillErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct RemoteSkillsResponse {
    pub session_id: String,
    pub skills: Vec<RemoteSkillSummary>,
}

#[derive(Debug, Serialize)]
pub struct McpToolsResponse {
    pub session_id: String,
    pub tools: HashMap<String, McpTool>,
    pub resources: HashMap<String, Vec<McpResource>>,
    pub resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
    pub auth_statuses: HashMap<String, McpAuthStatus>,
}

// ── Async action types ────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct DownloadRemoteSkillRequest {
    pub hazelnut_id: String,
}

#[derive(Debug, Deserialize)]
pub struct RefreshMcpServerRequest {
    pub server_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct McpToggleRequest {
    pub server_name: String,
    pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct McpServerNameRequest {
    pub server_name: String,
}

#[derive(Debug, Deserialize)]
pub struct McpSetServersRequest {
    pub servers: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct ApplyFlagSettingsRequest {
    pub settings: serde_json::Value,
}

#[derive(Debug, Deserialize, Default)]
pub struct SkillsQuery {
    #[serde(default)]
    pub cwd: Vec<String>,
    #[serde(default)]
    pub force_reload: Option<bool>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ApiErrorResponse {
    code: &'static str,
    error: String,
}

pub(crate) fn revision_now() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

#[derive(Debug)]
enum CodexActionError {
    SessionNotFound,
    ConnectorNotAvailable,
    ChannelClosed,
    Timeout,
}

type ApiResult<T> = Result<Json<T>, (StatusCode, Json<ApiErrorResponse>)>;
type ApiInnerResult<T> = Result<T, (StatusCode, Json<ApiErrorResponse>)>;
const CODEX_ACTION_WAIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);
const DEFAULT_CONVERSATION_PAGE_SIZE: usize = 50;
const MAX_CONVERSATION_PAGE_SIZE: usize = 200;

fn next_http_message_id(prefix: &str) -> String {
    format!("{prefix}-{}", orbitdock_protocol::new_id())
}

fn messaging_dispatch_error_response(
    error: crate::ws_handlers::messaging::DispatchMessageError,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        crate::ws_handlers::messaging::DispatchMessageError::NotFound => (
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

pub async fn fetch_codex_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<CodexUsageResponse> {
    if !state.is_primary() {
        return Json(CodexUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::usage_probe::fetch_codex_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(CodexUsageResponse { usage, error_info })
}

pub async fn fetch_claude_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<ClaudeUsageResponse> {
    if !state.is_primary() {
        return Json(ClaudeUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::usage_probe::fetch_claude_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(ClaudeUsageResponse { usage, error_info })
}
pub async fn list_codex_models() -> ApiResult<CodexModelsResponse> {
    match discover_models().await {
        Ok(models) => Ok(Json(CodexModelsResponse { models })),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "model_list_failed",
                error: format!("Failed to list models: {err}"),
            }),
        )),
    }
}

pub async fn list_claude_models() -> Json<ClaudeModelsResponse> {
    Json(ClaudeModelsResponse {
        models: load_cached_claude_models(),
    })
}
pub async fn list_skills_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Query(query): Query<SkillsQuery>,
) -> ApiResult<SkillsResponse> {
    let mut rx = subscribe_session_events(&state, &session_id).await?;

    dispatch_codex_action(
        &state,
        &session_id,
        CodexAction::ListSkills {
            cwds: query.cwd,
            force_reload: query.force_reload.unwrap_or(false),
        },
    )
    .await?;

    let (skills, errors) = wait_for_codex_skills_event(&session_id, &mut rx).await?;
    Ok(Json(SkillsResponse {
        session_id,
        skills,
        errors,
    }))
}

pub async fn list_remote_skills_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<RemoteSkillsResponse> {
    let mut rx = subscribe_session_events(&state, &session_id).await?;

    dispatch_codex_action(&state, &session_id, CodexAction::ListRemoteSkills).await?;

    let skills = wait_for_remote_skills_event(&session_id, &mut rx).await?;
    Ok(Json(RemoteSkillsResponse { session_id, skills }))
}

pub async fn list_mcp_tools_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<McpToolsResponse> {
    let mut rx = subscribe_session_events(&state, &session_id).await?;

    // Try Codex first, fall back to Claude
    if dispatch_codex_action(&state, &session_id, CodexAction::ListMcpTools)
        .await
        .is_err()
    {
        dispatch_claude_action(&state, &session_id, ClaudeAction::ListMcpTools).await?;
    }

    let (tools, resources, resource_templates, auth_statuses) =
        wait_for_mcp_tools_event(&session_id, &mut rx).await?;

    Ok(Json(McpToolsResponse {
        session_id,
        tools,
        resources,
        resource_templates,
        auth_statuses,
    }))
}

// ── Group C: Async fire-and-forget (202 Accepted) ─────────────

pub async fn download_remote_skill(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<DownloadRemoteSkillRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_codex_action(
        &state,
        &session_id,
        CodexAction::DownloadRemoteSkill {
            hazelnut_id: body.hazelnut_id,
        },
    )
    .await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn refresh_mcp_servers(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    body: Option<Json<RefreshMcpServerRequest>>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    let server_name = body.and_then(|b| b.server_name.clone());

    // Try Codex first, fall back to Claude
    if dispatch_codex_action(&state, &session_id, CodexAction::RefreshMcpServers)
        .await
        .is_err()
    {
        let action = match server_name {
            Some(name) => ClaudeAction::RefreshMcpServer { server_name: name },
            None => ClaudeAction::ListMcpTools, // No specific server — refresh all via status query
        };
        dispatch_claude_action(&state, &session_id, action).await?;
    }

    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn toggle_mcp_server(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<McpToggleRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_claude_action(
        &state,
        &session_id,
        ClaudeAction::McpToggle {
            server_name: body.server_name,
            enabled: body.enabled,
        },
    )
    .await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn mcp_authenticate(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<McpServerNameRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_claude_action(
        &state,
        &session_id,
        ClaudeAction::McpAuthenticate {
            server_name: body.server_name,
        },
    )
    .await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn mcp_clear_auth(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<McpServerNameRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_claude_action(
        &state,
        &session_id,
        ClaudeAction::McpClearAuth {
            server_name: body.server_name,
        },
    )
    .await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn mcp_set_servers(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<McpSetServersRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_claude_action(
        &state,
        &session_id,
        ClaudeAction::McpSetServers {
            servers: body.servers,
        },
    )
    .await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn apply_flag_settings(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ApplyFlagSettingsRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_claude_action(
        &state,
        &session_id,
        ClaudeAction::ApplyFlagSettings {
            settings: body.settings,
        },
    )
    .await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

// ── Private helpers ───────────────────────────────────────────

fn clamp_conversation_limit(limit: Option<usize>) -> usize {
    limit
        .unwrap_or(DEFAULT_CONVERSATION_PAGE_SIZE)
        .clamp(1, MAX_CONVERSATION_PAGE_SIZE)
}

async fn subscribe_session_events(
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

async fn dispatch_codex_action(
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

async fn dispatch_claude_action(
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

async fn wait_for_codex_skills_event(
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

async fn wait_for_remote_skills_event(
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

async fn wait_for_mcp_tools_event(
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

// ── New REST endpoints (Phase 0: HTTP-first migration) ───────

#[derive(Debug, Deserialize)]
pub struct ExecuteShellRequest {
    pub command: String,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ExecuteShellResponse {
    pub request_id: String,
    pub accepted: bool,
}

#[derive(Debug, Deserialize)]
pub struct CancelShellRequest {
    pub request_id: String,
}

fn session_not_found_error(session_id: &str) -> (StatusCode, Json<ApiErrorResponse>) {
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

fn dispatch_error_response(
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

pub async fn execute_shell_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ExecuteShellRequest>,
) -> Result<Json<ExecuteShellResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let resolved_cwd = if let Some(ref explicit) = body.cwd {
        explicit.clone()
    } else if let Some(actor) = state.get_session(&session_id) {
        let snap = actor.snapshot();
        snap.current_cwd
            .clone()
            .unwrap_or_else(|| snap.project_path.clone())
    } else {
        return Err(session_not_found_error(&session_id));
    };

    let request_id = orbitdock_protocol::new_id();
    let actor = state
        .get_session(&session_id)
        .ok_or_else(|| session_not_found_error(&session_id))?;

    // Broadcast shell started
    actor
        .send(SessionCommand::Broadcast {
            msg: ServerMessage::ShellStarted {
                session_id: session_id.clone(),
                request_id: request_id.clone(),
                command: body.command.clone(),
            },
        })
        .await;

    // Create shell message
    let ts_millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let shell_msg = orbitdock_protocol::Message {
        id: request_id.clone(),
        session_id: session_id.clone(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Shell,
        content: body.command.clone(),
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: crate::session_utils::iso_timestamp(ts_millis),
        duration_ms: None,
        images: vec![],
    };

    actor
        .send(SessionCommand::ProcessEvent {
            event: crate::transition::Input::MessageCreated(shell_msg),
        })
        .await;

    // Start shell execution
    let shell_execution = state
        .shell_service()
        .start(
            request_id.clone(),
            session_id.clone(),
            body.command,
            resolved_cwd,
            body.timeout_secs.unwrap_or(120),
        )
        .map_err(|_| {
            (
                StatusCode::CONFLICT,
                Json(ApiErrorResponse {
                    code: "shell_duplicate_request_id",
                    error: format!("Shell request {} is already active", request_id),
                }),
            )
        })?;

    // Spawn background task to stream output (same pattern as WS handler)
    let state_ref = state.clone();
    let sid = session_id.clone();
    let rid = request_id.clone();
    tokio::spawn(async move {
        let mut chunk_rx = shell_execution.chunk_rx;
        let completion_rx = shell_execution.completion_rx;
        let mut streamed_output = String::new();
        let mut last_stream_emit = std::time::Instant::now();
        const SHELL_STREAM_THROTTLE_MS: u128 = 120;

        while let Some(chunk) = chunk_rx.recv().await {
            if !chunk.stdout.is_empty() {
                streamed_output.push_str(&chunk.stdout);
            }
            if !chunk.stderr.is_empty() {
                streamed_output.push_str(&chunk.stderr);
            }
            let now = std::time::Instant::now();
            if now.duration_since(last_stream_emit).as_millis() < SHELL_STREAM_THROTTLE_MS {
                continue;
            }
            last_stream_emit = now;
            if let Some(actor) = state_ref.get_session(&sid) {
                actor
                    .send(SessionCommand::ProcessEvent {
                        event: crate::transition::Input::MessageUpdated {
                            message_id: rid.clone(),
                            content: None,
                            tool_output: Some(streamed_output.clone()),
                            is_error: None,
                            is_in_progress: Some(true),
                            duration_ms: None,
                        },
                    })
                    .await;
            }
        }

        let result = match completion_rx.await {
            Ok(result) => result,
            Err(recv_err) => crate::shell::ShellResult {
                stdout: String::new(),
                stderr: format!("Shell execution completion channel failed: {recv_err}"),
                exit_code: None,
                duration_ms: 0,
                outcome: crate::shell::ShellOutcome::Failed,
            },
        };

        let is_error = match result.outcome {
            crate::shell::ShellOutcome::Completed => result.exit_code != Some(0),
            crate::shell::ShellOutcome::Failed | crate::shell::ShellOutcome::TimedOut => true,
            crate::shell::ShellOutcome::Canceled => false,
        };
        let combined_output = if result.stderr.is_empty() {
            result.stdout.clone()
        } else if result.stdout.is_empty() {
            result.stderr.clone()
        } else {
            format!("{}\n{}", result.stdout, result.stderr)
        };
        let final_output = if combined_output.is_empty() {
            streamed_output
        } else {
            combined_output
        };
        let outcome = match result.outcome {
            crate::shell::ShellOutcome::Completed => {
                orbitdock_protocol::ShellExecutionOutcome::Completed
            }
            crate::shell::ShellOutcome::Failed => orbitdock_protocol::ShellExecutionOutcome::Failed,
            crate::shell::ShellOutcome::TimedOut => {
                orbitdock_protocol::ShellExecutionOutcome::TimedOut
            }
            crate::shell::ShellOutcome::Canceled => {
                orbitdock_protocol::ShellExecutionOutcome::Canceled
            }
        };

        if let Some(actor) = state_ref.get_session(&sid) {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::transition::Input::MessageUpdated {
                        message_id: rid.clone(),
                        content: None,
                        tool_output: Some(final_output),
                        is_error: Some(is_error),
                        is_in_progress: Some(false),
                        duration_ms: Some(result.duration_ms),
                    },
                })
                .await;
            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::ShellOutput {
                        session_id: sid,
                        request_id: rid,
                        stdout: result.stdout,
                        stderr: result.stderr,
                        exit_code: result.exit_code,
                        duration_ms: result.duration_ms,
                        outcome,
                    },
                })
                .await;
        }
    });

    Ok(Json(ExecuteShellResponse {
        request_id,
        accepted: true,
    }))
}

pub async fn cancel_shell_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CancelShellRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    if state.get_session(&session_id).is_none() {
        return Err(session_not_found_error(&session_id));
    }

    match state.shell_service().cancel(&session_id, &body.request_id) {
        crate::shell::ShellCancelStatus::Canceled => Ok(Json(AcceptedResponse { accepted: true })),
        crate::shell::ShellCancelStatus::NotFound => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "shell_not_found",
                error: format!(
                    "No active shell request {} found for session {}",
                    body.request_id, session_id
                ),
            }),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_session::CodexAction;
    use crate::persistence::{flush_batch_for_test, PersistCommand};
    use crate::session::SessionHandle;
    use axum::body::{to_bytes, Bytes};
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use orbitdock_protocol::{
        McpResource, McpResourceTemplate, Message, MessageType, Provider, RemoteSkillSummary,
        ReviewCommentStatus, ReviewCommentTag, SkillMetadata, SkillScope,
    };
    use serde_json::json;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::Once;
    use tokio::sync::mpsc;

    use crate::http_api::review_comments::{
        CreateReviewCommentRequest, ReviewCommentsQuery, UpdateReviewCommentRequest,
    };
    use crate::http_api::session_actions::{
        SendSessionMessageRequest, SteerTurnRequest, UploadImageAttachmentQuery,
    };

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-http-api-tests");
            crate::paths::init_data_dir(Some(&dir));
        });
    }

    fn new_test_state(is_primary: bool) -> Arc<SessionRegistry> {
        ensure_test_data_dir();
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary))
    }

    fn ensure_test_db() -> PathBuf {
        ensure_test_data_dir();
        let db_path = crate::paths::db_path();
        let mut conn = rusqlite::Connection::open(&db_path).expect("open test db");
        crate::migration_runner::run_migrations(&mut conn).expect("run test migrations");
        db_path
    }

    fn new_persist_test_state(
        is_primary: bool,
    ) -> (
        Arc<SessionRegistry>,
        mpsc::Receiver<PersistCommand>,
        PathBuf,
    ) {
        let db_path = ensure_test_db();
        let (persist_tx, persist_rx) = mpsc::channel(32);
        (
            Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary)),
            persist_rx,
            db_path,
        )
    }

    async fn upload_test_attachment(
        state: Arc<SessionRegistry>,
        session_id: &str,
        bytes: &'static [u8],
    ) -> ImageInput {
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("image/png"));
        let Json(response) = upload_session_image_attachment(
            Path(session_id.to_string()),
            State(state),
            Query(UploadImageAttachmentQuery {
                display_name: Some("test.png".to_string()),
                pixel_width: Some(320),
                pixel_height: Some(200),
            }),
            headers,
            Bytes::from_static(bytes),
        )
        .await
        .expect("upload attachment should succeed");
        response.image
    }

    #[tokio::test]
    async fn list_sessions_returns_runtime_summaries() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        state.add_session(handle);

        let Json(response) = list_sessions(State(state)).await;
        assert!(response
            .sessions
            .iter()
            .any(|session| session.id == session_id));
    }

    #[tokio::test]
    async fn get_session_returns_full_untruncated_message_content() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        let large_content = "x".repeat(40_000);
        handle.add_message(Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            sequence: None,
            message_type: MessageType::Assistant,
            content: large_content.clone(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        });
        state.add_session(handle);

        let response = get_session(Path(session_id), State(state)).await;
        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session.messages.len(), 1);
                assert_eq!(payload.session.messages[0].content, large_content);
                assert!(!payload.session.messages[0].content.contains("[truncated]"));
            }
            Err((status, body)) => panic!(
                "expected successful session response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn browse_directory_hides_dotfiles_and_returns_directories_first() {
        let root = std::env::temp_dir().join(format!(
            "orbitdock-api-browse-{}",
            orbitdock_protocol::new_id()
        ));
        std::fs::create_dir_all(root.join("z-dir")).expect("create visible directory");
        std::fs::write(root.join("a-file.txt"), "hello").expect("create visible file");
        std::fs::write(root.join(".hidden.txt"), "secret").expect("create hidden file");

        let Json(response) = browse_directory(Query(files::BrowseDirectoryQuery {
            path: Some(root.to_string_lossy().to_string()),
        }))
        .await;

        std::fs::remove_dir_all(&root).expect("remove browse test directory");

        assert_eq!(response.path, root.to_string_lossy().to_string());
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "z-dir" && entry.is_dir));
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "a-file.txt" && !entry.is_dir));
        assert!(!response
            .entries
            .iter()
            .any(|entry| entry.name.starts_with('.')));

        let first = response
            .entries
            .first()
            .expect("expected at least one listing entry");
        assert!(
            first.is_dir,
            "expected directories to be sorted before files"
        );
    }

    #[tokio::test]
    async fn usage_endpoints_return_control_plane_error_when_secondary() {
        let state = new_test_state(false);

        let Json(codex) = fetch_codex_usage(State(state.clone())).await;
        assert!(codex.usage.is_none());
        assert_eq!(
            codex.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );

        let Json(claude) = fetch_claude_usage(State(state)).await;
        assert!(claude.usage.is_none());
        assert_eq!(
            claude.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );
    }

    #[tokio::test]
    async fn review_comments_endpoint_returns_empty_when_none_exist() {
        ensure_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());

        let Json(response) = list_review_comments_endpoint(
            Path(session_id.clone()),
            Query(ReviewCommentsQuery::default()),
        )
        .await;

        assert_eq!(response.session_id, session_id);
        assert!(response.comments.is_empty());
    }

    #[tokio::test]
    async fn review_comment_mutations_return_authoritative_payloads_and_persist() {
        let (state, mut persist_rx, db_path) = new_persist_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-review-contract".to_string(),
        ));
        flush_batch_for_test(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: session_id.clone(),
                provider: Provider::Codex,
                project_path: "/tmp/orbitdock-review-contract".to_string(),
                project_name: Some("orbitdock-review-contract".to_string()),
                branch: Some("main".to_string()),
                model: Some("gpt-5".to_string()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("persist session row for review comment contract test");

        let Json(created) = create_review_comment_endpoint(
            Path(session_id.clone()),
            State(state.clone()),
            Json(CreateReviewCommentRequest {
                turn_id: Some("turn-1".to_string()),
                file_path: "src/main.rs".to_string(),
                line_start: 12,
                line_end: Some(14),
                body: "Initial review comment".to_string(),
                tag: Some(ReviewCommentTag::Clarity),
            }),
        )
        .await
        .expect("create review comment should succeed");

        assert_eq!(created.session_id, session_id);
        assert!(created.review_revision > 0);
        assert!(!created.deleted);
        let created_comment = created
            .comment
            .clone()
            .expect("create response should include comment");
        assert_eq!(created_comment.body, "Initial review comment");
        assert_eq!(created_comment.tag, Some(ReviewCommentTag::Clarity));

        let create_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("create should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentCreate { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![create_cmd]).expect("flush created comment");

        let stored_after_create =
            crate::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load created comment")
                .expect("created comment should exist");
        assert_eq!(stored_after_create.body, "Initial review comment");

        let Json(updated) = update_review_comment(
            Path(created.comment_id.clone()),
            State(state.clone()),
            Json(UpdateReviewCommentRequest {
                body: Some("Updated review comment".to_string()),
                tag: Some(ReviewCommentTag::Risk),
                status: Some(ReviewCommentStatus::Resolved),
            }),
        )
        .await
        .expect("update review comment should succeed");

        assert_eq!(updated.comment_id, created.comment_id);
        assert_eq!(updated.session_id, session_id);
        assert!(updated.review_revision > 0);
        assert!(!updated.deleted);
        let updated_comment = updated
            .comment
            .clone()
            .expect("update response should include comment");
        assert_eq!(updated_comment.body, "Updated review comment");
        assert_eq!(updated_comment.tag, Some(ReviewCommentTag::Risk));
        assert_eq!(updated_comment.status, ReviewCommentStatus::Resolved);

        let update_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("update should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentUpdate { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![update_cmd]).expect("flush updated comment");

        let stored_after_update =
            crate::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load updated comment")
                .expect("updated comment should exist");
        assert_eq!(stored_after_update.body, "Updated review comment");
        assert_eq!(stored_after_update.tag, Some(ReviewCommentTag::Risk));
        assert_eq!(stored_after_update.status, ReviewCommentStatus::Resolved);

        let Json(deleted) =
            delete_review_comment_by_id(Path(created.comment_id.clone()), State(state.clone()))
                .await
                .expect("delete review comment should succeed");

        assert_eq!(deleted.comment_id, created.comment_id);
        assert_eq!(deleted.session_id, session_id);
        assert!(deleted.review_revision > 0);
        assert!(deleted.deleted);
        assert!(deleted.comment.is_none());

        let delete_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("delete should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentDelete { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![delete_cmd]).expect("flush deleted comment");

        let stored_after_delete =
            crate::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load deleted comment");
        assert!(stored_after_delete.is_none());
    }

    #[tokio::test]
    async fn subagent_tools_endpoint_returns_empty_when_subagent_missing() {
        ensure_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let subagent_id = format!("sub-{}", orbitdock_protocol::new_id());

        let Json(response) =
            list_subagent_tools_endpoint(Path((session_id.clone(), subagent_id.clone()))).await;

        assert_eq!(response.session_id, session_id);
        assert_eq!(response.subagent_id, subagent_id);
        assert!(response.tools.is_empty());
    }

    #[tokio::test]
    async fn claude_models_endpoint_returns_cached_shape() {
        ensure_test_data_dir();
        let Json(response) = list_claude_models().await;
        assert!(response
            .models
            .iter()
            .all(|model| !model.value.trim().is_empty()));
    }

    #[tokio::test]
    async fn list_skills_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let actor = state
            .get_session(&session_id)
            .expect("session should exist for skills endpoint test");
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let session_id_for_task = session_id.clone();
        let task = tokio::spawn(async move {
            let action = action_rx
                .recv()
                .await
                .expect("skills endpoint should dispatch codex action");
            match action {
                CodexAction::ListSkills { cwds, force_reload } => {
                    assert_eq!(cwds, vec!["/tmp/orbitdock-api-test".to_string()]);
                    assert!(force_reload);
                }
                other => panic!("expected ListSkills action, got {:?}", other),
            }

            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::SkillsList {
                        session_id: session_id_for_task.clone(),
                        skills: vec![SkillsListEntry {
                            cwd: "/tmp/orbitdock-api-test".to_string(),
                            skills: vec![SkillMetadata {
                                name: "deploy".to_string(),
                                description: "Deploy app".to_string(),
                                short_description: Some("Deploy".to_string()),
                                path: "/tmp/orbitdock-api-test/.codex/skills/deploy.md".to_string(),
                                scope: SkillScope::Repo,
                                enabled: true,
                            }],
                            errors: vec![],
                        }],
                        errors: vec![SkillErrorInfo {
                            path: "/tmp/orbitdock-api-test/.codex/skills/bad.md".to_string(),
                            message: "invalid frontmatter".to_string(),
                        }],
                    },
                })
                .await;
        });

        let response = list_skills_endpoint(
            Path(session_id.clone()),
            State(state),
            Query(SkillsQuery {
                cwd: vec!["/tmp/orbitdock-api-test".to_string()],
                force_reload: Some(true),
            }),
        )
        .await;

        task.await
            .expect("skills endpoint helper task should complete");

        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session_id, session_id);
                assert_eq!(payload.skills.len(), 1);
                assert_eq!(payload.skills[0].cwd, "/tmp/orbitdock-api-test");
                assert_eq!(payload.skills[0].skills.len(), 1);
                assert_eq!(payload.skills[0].skills[0].name, "deploy");
                assert_eq!(payload.errors.len(), 1);
                assert_eq!(
                    payload.errors[0].path,
                    "/tmp/orbitdock-api-test/.codex/skills/bad.md"
                );
            }
            Err((status, body)) => panic!(
                "expected successful skills response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn list_remote_skills_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let actor = state
            .get_session(&session_id)
            .expect("session should exist for remote skills endpoint test");
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let session_id_for_task = session_id.clone();
        let task = tokio::spawn(async move {
            let action = action_rx
                .recv()
                .await
                .expect("remote skills endpoint should dispatch codex action");
            match action {
                CodexAction::ListRemoteSkills => {}
                other => panic!("expected ListRemoteSkills action, got {:?}", other),
            }

            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::RemoteSkillsList {
                        session_id: session_id_for_task.clone(),
                        skills: vec![RemoteSkillSummary {
                            id: "remote-1".to_string(),
                            name: "deploy-checks".to_string(),
                            description: "Shared deploy readiness checks".to_string(),
                        }],
                    },
                })
                .await;
        });

        let response = list_remote_skills_endpoint(Path(session_id.clone()), State(state)).await;

        task.await
            .expect("remote skills endpoint helper task should complete");

        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session_id, session_id);
                assert_eq!(payload.skills.len(), 1);
                assert_eq!(payload.skills[0].id, "remote-1");
                assert_eq!(payload.skills[0].name, "deploy-checks");
            }
            Err((status, body)) => panic!(
                "expected successful remote skills response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn list_mcp_tools_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let actor = state
            .get_session(&session_id)
            .expect("session should exist for mcp tools endpoint test");
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let session_id_for_task = session_id.clone();
        let task = tokio::spawn(async move {
            let action = action_rx
                .recv()
                .await
                .expect("mcp tools endpoint should dispatch codex action");
            match action {
                CodexAction::ListMcpTools => {}
                other => panic!("expected ListMcpTools action, got {:?}", other),
            }

            let mut tools = HashMap::new();
            tools.insert(
                "docs__search".to_string(),
                McpTool {
                    name: "search".to_string(),
                    title: Some("Search Docs".to_string()),
                    description: Some("Searches docs".to_string()),
                    input_schema: json!({"type": "object"}),
                    output_schema: None,
                    annotations: None,
                },
            );

            let mut resources = HashMap::new();
            resources.insert(
                "docs".to_string(),
                vec![McpResource {
                    name: "overview".to_string(),
                    uri: "docs://overview".to_string(),
                    description: Some("Docs overview".to_string()),
                    mime_type: Some("text/markdown".to_string()),
                    title: None,
                    size: None,
                    annotations: None,
                }],
            );

            let mut resource_templates = HashMap::new();
            resource_templates.insert(
                "docs".to_string(),
                vec![McpResourceTemplate {
                    name: "topic".to_string(),
                    uri_template: "docs://topics/{name}".to_string(),
                    title: Some("Topic".to_string()),
                    description: Some("Topic page template".to_string()),
                    mime_type: Some("text/markdown".to_string()),
                    annotations: None,
                }],
            );

            let mut auth_statuses = HashMap::new();
            auth_statuses.insert("docs".to_string(), McpAuthStatus::OAuth);

            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::McpToolsList {
                        session_id: session_id_for_task.clone(),
                        tools,
                        resources,
                        resource_templates,
                        auth_statuses,
                    },
                })
                .await;
        });

        let response = list_mcp_tools_endpoint(Path(session_id.clone()), State(state)).await;

        task.await
            .expect("mcp tools endpoint helper task should complete");

        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session_id, session_id);
                assert_eq!(payload.tools.len(), 1);
                assert_eq!(
                    payload
                        .tools
                        .get("docs__search")
                        .map(|tool| tool.name.as_str()),
                    Some("search")
                );
                assert_eq!(
                    payload
                        .resources
                        .get("docs")
                        .and_then(|resources| resources.first())
                        .map(|resource| resource.uri.as_str()),
                    Some("docs://overview")
                );
                assert_eq!(
                    payload
                        .resource_templates
                        .get("docs")
                        .and_then(|templates| templates.first())
                        .map(|template| template.uri_template.as_str()),
                    Some("docs://topics/{name}")
                );
                assert_eq!(
                    payload.auth_statuses.get("docs"),
                    Some(&McpAuthStatus::OAuth)
                );
            }
            Err((status, body)) => panic!(
                "expected successful mcp tools response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn list_skills_endpoint_returns_conflict_when_connector_missing() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));

        let response = list_skills_endpoint(
            Path(session_id),
            State(state),
            Query(SkillsQuery::default()),
        )
        .await;

        match response {
            Ok(_) => panic!("expected list_skills_endpoint to fail without connector"),
            Err((status, body)) => {
                assert_eq!(status, StatusCode::CONFLICT);
                assert_eq!(body.code, "session_not_found");
            }
        }
    }

    #[tokio::test]
    async fn image_attachment_upload_and_fetch_round_trip() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));

        let uploaded = upload_test_attachment(state, &session_id, b"png-bytes").await;
        assert_eq!(uploaded.input_type, "attachment");
        assert_eq!(uploaded.mime_type.as_deref(), Some("image/png"));
        assert_eq!(uploaded.byte_count, Some(9));
        assert_eq!(uploaded.pixel_width, Some(320));
        assert_eq!(uploaded.pixel_height, Some(200));

        let response = get_session_image_attachment(Path((session_id, uploaded.value.clone())))
            .await
            .expect("attachment fetch should succeed")
            .into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some("image/png")
        );

        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("attachment body should decode");
        assert_eq!(body.as_ref(), b"png-bytes");
    }

    #[tokio::test]
    async fn post_session_message_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let uploaded =
            upload_test_attachment(state.clone(), &session_id, b"send-message-image").await;

        let _ = post_session_message(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SendSessionMessageRequest {
                content: "look at this".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post session message should succeed");

        let action = action_rx
            .recv()
            .await
            .expect("message endpoint should dispatch codex action");
        match action {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted user message");
        assert_eq!(persisted.message_type, MessageType::User);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }

    #[tokio::test]
    async fn post_steer_turn_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_claude_action_tx(&session_id, action_tx);

        let uploaded = upload_test_attachment(state.clone(), &session_id, b"steer-image").await;

        let _ = post_steer_turn(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SteerTurnRequest {
                content: "consider this image".to_string(),
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post steer should succeed");

        let action = action_rx
            .recv()
            .await
            .expect("steer endpoint should dispatch claude action");
        match action {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted steer message");
        assert_eq!(persisted.message_type, MessageType::Steer);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }
}
