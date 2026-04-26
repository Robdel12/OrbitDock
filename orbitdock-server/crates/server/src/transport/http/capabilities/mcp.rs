use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};

use crate::{
  connectors::codex_session::CodexAction,
  runtime::session_registry::SessionRegistry,
  transport::http::{
    connector_actions::{
      dispatch_claude_action, dispatch_codex_action, dispatch_codex_query,
      subscribe_session_events, wait_for_mcp_tools_event,
    },
    AcceptedResponse, ApiErrorResponse, ApiResult,
  },
};
use orbitdock_connector_claude::session::ClaudeAction;
use tokio::sync::oneshot;

use super::{
  common::accepted_without_detail, McpAuthenticateResponse, McpServerNameRequest,
  McpSetServersRequest, McpToggleRequest, McpToolsResponse, RefreshMcpServerRequest,
};

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

  Ok(accepted_without_detail())
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

  Ok(accepted_without_detail())
}

pub async fn mcp_authenticate(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<McpServerNameRequest>,
) -> Result<(StatusCode, Json<McpAuthenticateResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  if state.get_codex_action_tx(&session_id).is_some() {
    let (reply_tx, reply_rx) = oneshot::channel();
    let response = dispatch_codex_query(
      &state,
      &session_id,
      reply_rx,
      CodexAction::AuthenticateMcpServer {
        server_name: body.server_name,
        reply_tx,
      },
    )
    .await?;

    return Ok((
      StatusCode::ACCEPTED,
      Json(McpAuthenticateResponse {
        accepted: true,
        authorization_url: Some(response.authorization_url),
      }),
    ));
  }

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
    Json(McpAuthenticateResponse {
      accepted: true,
      authorization_url: None,
    }),
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

  Ok(accepted_without_detail())
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

  Ok(accepted_without_detail())
}
