use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use tokio::sync::oneshot;

use crate::{
  connectors::codex_session::CodexAction,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::{
    connector_actions::dispatch_codex_query, session_actions::session_controls_for_state,
    session_load_error, ApiErrorResponse, ApiResult,
  },
};

use super::{
  common::{load_session_state, read_optional_markdown},
  SessionCollaborationMode, SessionCollaborationModesResponse, SessionInstructionsPayload,
  SessionRuntimeResponse,
};

pub async fn list_collaboration_modes_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionCollaborationModesResponse> {
  let session = load_session_state(&state, &session_id).await?;
  let collaboration_modes = load_collaboration_modes(&state, &session_id, session.provider).await?;

  Ok(Json(SessionCollaborationModesResponse {
    data: collaboration_modes,
  }))
}

pub async fn get_session_runtime(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<SessionRuntimeResponse>, (axum::http::StatusCode, Json<ApiErrorResponse>)> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|error| session_load_error(&session_id, error))?;
  let collaboration_modes = load_collaboration_modes(&state, &session_id, session.provider).await?;
  let instructions = load_session_instructions(&session).await;

  Ok(Json(SessionRuntimeResponse {
    session_id,
    provider: session.provider,
    controls: session_controls_for_state(&session),
    instructions,
    collaboration_modes,
  }))
}

pub(super) async fn load_collaboration_modes(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  provider: orbitdock_protocol::Provider,
) -> Result<Vec<SessionCollaborationMode>, (axum::http::StatusCode, Json<ApiErrorResponse>)> {
  if provider != orbitdock_protocol::Provider::Codex {
    return Ok(Vec::new());
  }

  let (reply_tx, reply_rx) = oneshot::channel();
  let response = dispatch_codex_query(
    state,
    session_id,
    reply_rx,
    CodexAction::ListCollaborationModes { reply_tx },
  )
  .await?;

  Ok(map_collaboration_modes(response.data))
}

pub(super) async fn load_session_instructions(
  session: &orbitdock_protocol::SessionState,
) -> SessionInstructionsPayload {
  let system_prompt = Some(crate::domain::instructions::orbitdock_system_instructions());
  match session.provider {
    orbitdock_protocol::Provider::Claude => {
      let home = std::env::var("HOME").ok().map(std::path::PathBuf::from);
      let global_path = home.map(|path| path.join(".claude/CLAUDE.md"));
      let project_path = std::path::PathBuf::from(&session.project_path).join("CLAUDE.md");

      let global = match global_path {
        Some(path) => read_optional_markdown(path).await,
        None => None,
      };
      let project = read_optional_markdown(project_path).await;
      let claude_md = match (global, project) {
        (Some(global), Some(project)) => Some(format!("{global}\n\n{project}")),
        (Some(global), None) => Some(global),
        (None, Some(project)) => Some(project),
        (None, None) => None,
      };

      SessionInstructionsPayload {
        claude_md,
        system_prompt: system_prompt.clone(),
        developer_instructions: session.developer_instructions.clone(),
      }
    }
    orbitdock_protocol::Provider::Codex => SessionInstructionsPayload {
      claude_md: None,
      system_prompt,
      developer_instructions: session.developer_instructions.clone(),
    },
  }
}

fn map_collaboration_modes(
  data: Vec<codex_app_server_protocol::CollaborationModeMask>,
) -> Vec<SessionCollaborationMode> {
  data
    .into_iter()
    .map(|mode| SessionCollaborationMode {
      name: mode.name,
      mode: mode.mode.map(|value| match value {
        codex_protocol::config_types::ModeKind::Plan => "plan".to_string(),
        codex_protocol::config_types::ModeKind::Default => "default".to_string(),
        codex_protocol::config_types::ModeKind::PairProgramming => "pair_programming".to_string(),
        codex_protocol::config_types::ModeKind::Execute => "execute".to_string(),
      }),
      model: mode.model,
      reasoning_effort: mode
        .reasoning_effort
        .as_ref()
        .and_then(|value| value.as_ref())
        .map(ToString::to_string),
      clears_reasoning_effort: matches!(mode.reasoning_effort, Some(None)),
    })
    .collect()
}
