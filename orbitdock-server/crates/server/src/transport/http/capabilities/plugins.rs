use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  Json,
};
use tokio::sync::oneshot;

use crate::{
  connectors::codex_session::CodexAction,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::{
    connector_actions::{dispatch_codex_query, session_not_found_error},
    ApiResult,
  },
};

use super::{common::codex_plugin_context, PluginsQuery};

pub async fn list_plugins_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<PluginsQuery>,
) -> ApiResult<codex_app_server_protocol::PluginListResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| session_not_found_error(&session_id))?;
  let (cwd, config_overrides, control_plane) = codex_plugin_context(&session);
  let (reply_tx, reply_rx) = oneshot::channel();

  let response = dispatch_codex_query(
    &state,
    &session_id,
    reply_rx,
    CodexAction::ListPlugins {
      cwd,
      cwds: query.cwd,
      force_remote_sync: query.force_remote_sync.unwrap_or(false),
      config_overrides,
      control_plane,
      reply_tx,
    },
  )
  .await?;

  Ok(Json(response))
}

pub async fn install_plugin(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<codex_app_server_protocol::PluginInstallParams>,
) -> ApiResult<codex_app_server_protocol::PluginInstallResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| session_not_found_error(&session_id))?;
  let (cwd, config_overrides, control_plane) = codex_plugin_context(&session);
  let (reply_tx, reply_rx) = oneshot::channel();

  let response = dispatch_codex_query(
    &state,
    &session_id,
    reply_rx,
    CodexAction::InstallPlugin {
      cwd,
      params: body,
      config_overrides,
      control_plane,
      reply_tx,
    },
  )
  .await?;

  Ok(Json(response))
}

pub async fn uninstall_plugin(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<codex_app_server_protocol::PluginUninstallParams>,
) -> ApiResult<codex_app_server_protocol::PluginUninstallResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| session_not_found_error(&session_id))?;
  let (cwd, config_overrides, control_plane) = codex_plugin_context(&session);
  let (reply_tx, reply_rx) = oneshot::channel();

  let response = dispatch_codex_query(
    &state,
    &session_id,
    reply_rx,
    CodexAction::UninstallPlugin {
      cwd,
      params: body,
      config_overrides,
      control_plane,
      reply_tx,
    },
  )
  .await?;

  Ok(Json(response))
}
