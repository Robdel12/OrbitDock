use std::{path::PathBuf, sync::Arc};

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};

use crate::{
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::{
  common::read_optional_markdown, SessionInstructionsPayload, SessionInstructionsResponse,
};

pub async fn get_session_instructions(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionInstructionsResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| {
      (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("Session {} not found", session_id),
        }),
      )
    })?;

  let system_prompt = Some(crate::domain::instructions::orbitdock_system_instructions());
  let instructions = match session.provider {
    orbitdock_protocol::Provider::Claude => {
      let home = std::env::var("HOME").ok().map(PathBuf::from);
      let global_path = home.map(|path| path.join(".claude/CLAUDE.md"));
      let project_path = PathBuf::from(&session.project_path).join("CLAUDE.md");

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
  };

  Ok(Json(SessionInstructionsResponse {
    session_id,
    provider: session.provider,
    instructions,
  }))
}
