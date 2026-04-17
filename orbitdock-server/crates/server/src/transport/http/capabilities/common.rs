use std::{path::PathBuf, sync::Arc};

use axum::{http::StatusCode, Json};
use orbitdock_connector_codex::{CodexConfigOverrides, CodexControlPlane};

use crate::{
  infrastructure::persistence::load_capabilities_from_transcript_path,
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  support::session_paths::claude_transcript_path_from_cwd,
  transport::http::{AcceptedResponse, ApiErrorResponse},
};

pub async fn read_optional_markdown(path: PathBuf) -> Option<String> {
  tokio::fs::read_to_string(path)
    .await
    .ok()
    .filter(|contents| !contents.trim().is_empty())
}

pub async fn load_session_state(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<orbitdock_protocol::SessionState, (StatusCode, Json<ApiErrorResponse>)> {
  if let Some(actor) = state.get_session(session_id) {
    if let Ok(snapshot) = actor.retained_state().await {
      return Ok(snapshot);
    }
  }

  load_full_session_state(state, session_id, false, false)
    .await
    .map_err(|_| crate::transport::http::connector_actions::session_not_found_error(session_id))
}

pub async fn load_claude_skill_names(
  session_id: &str,
  session: &orbitdock_protocol::SessionState,
) -> Vec<String> {
  let Some(transcript_path) = claude_transcript_path_for_session(session_id, session) else {
    return Vec::new();
  };

  let mut skill_names = load_capabilities_from_transcript_path(&transcript_path)
    .await
    .map(|capabilities| capabilities.skills)
    .unwrap_or_default();
  skill_names.sort();
  skill_names.dedup();
  skill_names
}

pub fn codex_plugin_context(
  session: &orbitdock_protocol::SessionState,
) -> (String, CodexConfigOverrides, CodexControlPlane) {
  let cwd = session
    .current_cwd
    .clone()
    .unwrap_or_else(|| session.project_path.clone());
  let overrides = session.codex_config_overrides.clone().unwrap_or_default();

  (
    cwd,
    CodexConfigOverrides {
      model_provider: overrides.model_provider,
      config_profile: None,
    },
    CodexControlPlane {
      approvals_reviewer: overrides
        .approvals_reviewer
        .map(|value| value.as_str().to_string()),
      collaboration_mode: session.collaboration_mode.clone(),
      multi_agent: session.multi_agent,
      personality: session.personality.clone(),
      service_tier: session.service_tier.clone(),
      developer_instructions: session.developer_instructions.clone(),
      effort: session.effort.clone(),
    },
  )
}

pub fn accepted_without_detail() -> (StatusCode, Json<AcceptedResponse>) {
  (
    StatusCode::ACCEPTED,
    Json(AcceptedResponse {
      accepted: true,
      session_detail_snapshot: None,
    }),
  )
}

fn claude_transcript_path_for_session(
  session_id: &str,
  session: &orbitdock_protocol::SessionState,
) -> Option<String> {
  session.transcript_path.clone().or_else(|| {
    let cwd = session
      .current_cwd
      .as_deref()
      .unwrap_or(&session.project_path);
    claude_transcript_path_from_cwd(cwd, session_id)
  })
}
