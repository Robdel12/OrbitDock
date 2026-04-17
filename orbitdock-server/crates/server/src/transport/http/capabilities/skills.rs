use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  Json,
};

use crate::{
  connectors::codex_session::CodexAction,
  runtime::session_registry::SessionRegistry,
  transport::http::{
    connector_actions::{
      dispatch_codex_action, subscribe_session_events, wait_for_codex_skills_event,
    },
    ApiResult,
  },
};

use super::{
  common::{load_claude_skill_names, load_session_state},
  SkillsQuery, SkillsResponse,
};

pub async fn list_skills_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<SkillsQuery>,
) -> ApiResult<SkillsResponse> {
  let session = load_session_state(&state, &session_id).await?;

  if session.provider == orbitdock_protocol::Provider::Claude {
    let claude_skill_names = load_claude_skill_names(&session_id, &session).await;
    return Ok(Json(SkillsResponse {
      session_id,
      skills: Vec::new(),
      claude_skill_names,
      errors: Vec::new(),
    }));
  }

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
    claude_skill_names: Vec::new(),
    errors,
  }))
}
