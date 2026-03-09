use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_protocol::{
    McpAuthStatus, McpResource, McpResourceTemplate, McpTool, RemoteSkillSummary, SkillErrorInfo,
    SkillsListEntry,
};
use serde::{Deserialize, Serialize};

use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_registry::SessionRegistry;

use super::connector_actions::{
    dispatch_claude_action, dispatch_codex_action, subscribe_session_events,
    wait_for_codex_skills_event, wait_for_mcp_tools_event, wait_for_remote_skills_event,
};
use super::errors::{ApiErrorResponse, ApiResult};
use super::session_actions::AcceptedResponse;

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

    if dispatch_codex_action(&state, &session_id, CodexAction::RefreshMcpServers)
        .await
        .is_err()
    {
        let action = match server_name {
            Some(name) => ClaudeAction::RefreshMcpServer { server_name: name },
            None => ClaudeAction::ListMcpTools,
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
