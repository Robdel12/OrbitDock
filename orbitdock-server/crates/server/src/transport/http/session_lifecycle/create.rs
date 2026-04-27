use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use super::super::errors::{unprocessable, ApiErrorResponse};
use super::common::{lifecycle_error, resolve_developer_instructions};
use crate::runtime::codex_config::{resolve_codex_settings, CodexConfigSelection};
use crate::runtime::session_creation::{
  launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::{
  CodexApprovalPolicy, CodexConfigMode, CodexConfigSource, CodexSandboxPolicy,
  CodexSessionOverrides, Provider, SessionSummary,
};

#[derive(Debug, Deserialize)]
pub struct CreateSessionRequest {
  #[serde(default)]
  pub session_id: Option<String>,
  pub provider: Provider,
  pub cwd: String,
  #[serde(default)]
  pub model: Option<String>,
  #[serde(default)]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default)]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  #[serde(default)]
  pub permission_mode: Option<String>,
  #[serde(default)]
  pub allowed_tools: Vec<String>,
  #[serde(default)]
  pub disallowed_tools: Vec<String>,
  #[serde(default)]
  pub effort: Option<String>,
  #[serde(default)]
  pub collaboration_mode: Option<String>,
  #[serde(default)]
  pub multi_agent: Option<bool>,
  #[serde(default)]
  pub personality: Option<String>,
  #[serde(default)]
  pub service_tier: Option<String>,
  #[serde(default)]
  pub developer_instructions: Option<String>,
  #[serde(default)]
  pub system_prompt: Option<String>,
  #[serde(default)]
  pub append_system_prompt: Option<String>,
  #[serde(default)]
  pub allow_bypass_permissions: bool,
  #[serde(default)]
  pub codex_config_mode: Option<CodexConfigMode>,
  #[serde(default)]
  pub codex_config_profile: Option<String>,
  #[serde(default)]
  pub codex_model_provider: Option<String>,
  #[serde(default)]
  pub codex_config_source: Option<CodexConfigSource>,
  #[serde(default)]
  pub mission_id: Option<String>,
  #[serde(default)]
  pub issue_id: Option<String>,
  #[serde(default)]
  pub issue_identifier: Option<String>,
  #[serde(default)]
  pub workspace_id: Option<String>,
  #[serde(default)]
  pub initial_prompt: Option<String>,
  #[serde(default)]
  pub skills: Vec<String>,
  #[serde(default)]
  pub tracker_kind: Option<String>,
  #[serde(default)]
  pub tracker_api_key: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateSessionResponse {
  pub session_id: String,
  pub session: SessionSummary,
}

fn create_codex_selection(
  body: &CreateSessionRequest,
  developer_instructions: Option<String>,
  codex_config_source: Option<CodexConfigSource>,
) -> Option<CodexConfigSelection> {
  if body.provider != Provider::Codex {
    return None;
  }

  let codex_overrides = CodexSessionOverrides {
    model: body.model.clone(),
    model_provider: body.codex_model_provider.clone(),
    approval_policy_details: body.approval_policy_details.clone(),
    sandbox_policy_details: body.sandbox_policy_details.clone(),
    approvals_reviewer: None,
    collaboration_mode: body.collaboration_mode.clone(),
    multi_agent: body.multi_agent,
    personality: body.personality.clone(),
    service_tier: body.service_tier.clone(),
    developer_instructions,
    effort: body.effort.clone(),
  };
  let config_mode = body.codex_config_mode.unwrap_or({
    if body.codex_config_profile.is_some() {
      CodexConfigMode::Profile
    } else if body.codex_model_provider.is_some() {
      CodexConfigMode::Custom
    } else {
      CodexConfigMode::Inherit
    }
  });

  Some(codex_overrides)
    .zip(codex_config_source)
    .map(|(overrides, source)| {
      CodexConfigSelection {
        config_source: source,
        config_mode,
        config_profile: body.codex_config_profile.clone(),
        model_provider: body.codex_model_provider.clone(),
        overrides,
      }
      .normalized()
    })
}

pub async fn create_session(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<CreateSessionRequest>,
) -> Result<Json<CreateSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let session_id = body
    .session_id
    .clone()
    .unwrap_or_else(orbitdock_protocol::new_session_id);
  let developer_instructions = resolve_developer_instructions(
    body.developer_instructions.clone(),
    body.system_prompt.clone(),
    body.append_system_prompt.clone(),
  );
  let codex_config_source = if body.provider == Provider::Codex {
    Some(body.codex_config_source.unwrap_or(CodexConfigSource::User))
  } else {
    None
  };
  let normalized_codex_selection =
    create_codex_selection(&body, developer_instructions.clone(), codex_config_source);
  let claude_extra_env = body
    .tracker_api_key
    .as_ref()
    .zip(body.tracker_kind.as_deref())
    .map(|(api_key, tracker_kind)| {
      crate::runtime::workspace_dispatch::local::build_mission_tool_env(
        tracker_kind,
        api_key,
        body.issue_id.as_deref().unwrap_or_default(),
        body.issue_identifier.as_deref().unwrap_or_default(),
        body.mission_id.as_deref().unwrap_or_default(),
      )
    })
    .unwrap_or_default();
  let include_mission_tools = body.tracker_api_key.is_some()
    || crate::domain::codex_tools::has_mission_context(
      body.mission_id.as_deref(),
      body.issue_identifier.as_deref(),
    );
  let dynamic_tools =
    crate::domain::codex_tools::default_codex_dynamic_tool_specs(include_mission_tools);
  if !claude_extra_env.is_empty() {
    let orbitdock_bin = std::env::current_exe()
      .map(|path| path.to_string_lossy().to_string())
      .unwrap_or_else(|_| "orbitdock".to_string());
    let mcp_config = crate::runtime::workspace_dispatch::local::build_mcp_config(&orbitdock_bin);
    let mcp_path = format!("{}/.mcp.json", body.cwd.trim_end_matches('/'));
    let _ = tokio::fs::write(
      &mcp_path,
      serde_json::to_string_pretty(&mcp_config).unwrap_or_default(),
    )
    .await;
  }
  let resolved_codex = if let Some(selection) = normalized_codex_selection.clone() {
    Some(
      resolve_codex_settings(&body.cwd, selection)
        .await
        .map_err(|error| unprocessable("invalid_codex_config", error))?,
    )
  } else {
    None
  };
  if let Some(ref resolved) = resolved_codex {
    info!(
      component = "session",
      event = "session.create.codex_config_resolved",
      session_id = %session_id,
      requested_model = ?body.model,
      resolved_model = ?resolved.effective_settings.model,
      codex_config_mode = ?resolved.effective_settings.config_mode,
      codex_config_profile = ?resolved.effective_settings.config_profile,
      codex_model_provider = ?resolved.effective_settings.model_provider,
      "Resolved Codex session config before create"
    );
  }
  let prepared = prepare_persist_direct_session(
    &state,
    session_id.clone(),
    DirectSessionRequest {
      provider: body.provider,
      cwd: body.cwd.clone(),
      model: match body.provider {
        Provider::Claude => body.model.clone(),
        Provider::Codex => resolved_codex
          .as_ref()
          .and_then(|resolved| resolved.effective_settings.model.clone())
          .or_else(|| {
            normalized_codex_selection
              .as_ref()
              .and_then(|selection| selection.overrides.model.clone())
          }),
      },
      approval_policy: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.approval_policy.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.approval_policy_summary())
        }),
      sandbox_mode: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.sandbox_mode.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.sandbox_mode_summary())
        }),
      sandbox_policy_details: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.sandbox_policy_details.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.sandbox_policy_details.clone())
        }),
      permission_mode: body.permission_mode.clone(),
      allowed_tools: body.allowed_tools.clone(),
      disallowed_tools: body.disallowed_tools.clone(),
      effort: match body.provider {
        Provider::Claude => body.effort.clone(),
        Provider::Codex => resolved_codex
          .as_ref()
          .and_then(|resolved| resolved.effective_settings.effort.clone())
          .or_else(|| {
            normalized_codex_selection
              .as_ref()
              .and_then(|selection| selection.overrides.effort.clone())
          }),
      },
      collaboration_mode: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.collaboration_mode.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.collaboration_mode.clone())
        }),
      multi_agent: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.multi_agent)
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.multi_agent)
        }),
      personality: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.personality.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.personality.clone())
        }),
      service_tier: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.service_tier.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.service_tier.clone())
        }),
      developer_instructions: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.developer_instructions.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.developer_instructions.clone())
        }),
      mission_id: body.mission_id.clone(),
      issue_identifier: body.issue_identifier.clone(),
      worktree_id: None,
      dynamic_tools,
      allow_bypass_permissions: body.allow_bypass_permissions,
      claude_extra_env,
      codex_config_mode: resolved_codex
        .as_ref()
        .map(|resolved| resolved.effective_settings.config_mode),
      codex_config_profile: resolved_codex.as_ref().and_then(|resolved| {
        match resolved.effective_settings.config_mode {
          CodexConfigMode::Profile => resolved.effective_settings.config_profile.clone(),
          _ => None,
        }
      }),
      codex_model_provider: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.model_provider.clone()),
      codex_config_source,
      codex_config_overrides: resolved_codex
        .as_ref()
        .map(|resolved| resolved.effective_settings.overrides.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .map(|selection| selection.overrides.clone())
        }),
    },
  )
  .await;
  let summary = prepared.summary.clone();

  if let Err(error_message) = launch_prepared_direct_session(&state, prepared).await {
    error!(
      component = "session",
      event = "session.create.http.connector_failed",
      session_id = %session_id,
      provider = ?body.provider,
      error = %error_message,
      "HTTP: Failed to start direct session connector"
    );
    return Err(lifecycle_error(
      StatusCode::SERVICE_UNAVAILABLE,
      "connector_start_failed",
      format!(
        "Failed to start {:?} connector for session {}: {}",
        body.provider, session_id, error_message
      ),
    ));
  }

  if let Some(initial_prompt) = &body.initial_prompt {
    crate::runtime::session_prompt::send_initial_prompt(
      &state,
      &session_id,
      body.provider,
      initial_prompt,
      resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.model.clone())
        .or(body.model.clone()),
      resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.effort.clone())
        .or(body.effort.clone()),
      &body.skills,
    )
    .await;
  }

  if let (Some(mission_id), Some(issue_id)) = (&body.mission_id, &body.issue_id) {
    let _ = state
      .persist()
      .send(
        crate::infrastructure::persistence::PersistCommand::MissionIssueUpdateState {
          mission_id: mission_id.clone(),
          issue_id: issue_id.clone(),
          orchestration_state: "running".to_string(),
          session_id: Some(session_id.clone()),
          workspace_id: body.workspace_id.clone(),
          attempt: None,
          last_error: Some(None),
          retry_due_at: None,
          started_at: None,
          completed_at: None,
        },
      )
      .await;
  }

  state.notify_active_session_updated(&session_id);

  Ok(Json(CreateSessionResponse {
    session_id,
    session: summary,
  }))
}

#[cfg(test)]
#[path = "create_tests.rs"]
mod tests;
