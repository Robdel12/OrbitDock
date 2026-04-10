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
  pub approval_policy: Option<String>,
  #[serde(default)]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default)]
  pub sandbox_mode: Option<String>,
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
    approval_policy: body
      .approval_policy_details
      .as_ref()
      .map(|details| details.legacy_summary())
      .or(body.approval_policy.clone()),
    approval_policy_details: body.approval_policy_details.clone(),
    sandbox_mode: body
      .sandbox_policy_details
      .as_ref()
      .map(|details| details.legacy_summary())
      .or(body.sandbox_mode.clone()),
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
            .and_then(|selection| selection.overrides.approval_policy.clone())
        }),
      sandbox_mode: resolved_codex
        .as_ref()
        .and_then(|resolved| resolved.effective_settings.sandbox_mode.clone())
        .or_else(|| {
          normalized_codex_selection
            .as_ref()
            .and_then(|selection| selection.overrides.sandbox_mode.clone())
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

  state.notify_dashboard_session_updated(&session_id);

  Ok(Json(CreateSessionResponse {
    session_id,
    session: summary,
  }))
}

#[cfg(test)]
mod tests {
  use super::*;

  fn codex_request(
    codex_config_mode: Option<CodexConfigMode>,
    codex_config_profile: Option<&str>,
    model_provider: Option<&str>,
    model: Option<&str>,
  ) -> CreateSessionRequest {
    CreateSessionRequest {
      session_id: None,
      provider: Provider::Codex,
      cwd: "/tmp/project".to_string(),
      model: model.map(str::to_string),
      approval_policy: None,
      approval_policy_details: None,
      sandbox_mode: None,
      sandbox_policy_details: None,
      permission_mode: None,
      allowed_tools: Vec::new(),
      disallowed_tools: Vec::new(),
      effort: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      system_prompt: None,
      append_system_prompt: None,
      allow_bypass_permissions: false,
      codex_config_mode,
      codex_config_profile: codex_config_profile.map(str::to_string),
      codex_model_provider: model_provider.map(str::to_string),
      codex_config_source: Some(CodexConfigSource::User),
      mission_id: None,
      issue_id: None,
      issue_identifier: None,
      workspace_id: None,
      initial_prompt: None,
      skills: Vec::new(),
      tracker_kind: None,
      tracker_api_key: None,
    }
  }

  #[test]
  fn create_codex_selection_clears_stale_model_for_profile_mode() {
    let selection = create_codex_selection(
      &codex_request(
        Some(CodexConfigMode::Profile),
        Some("qwen"),
        Some("openrouter"),
        Some("gpt-5.4"),
      ),
      None,
      Some(CodexConfigSource::User),
    )
    .expect("selection should exist");

    assert_eq!(selection.config_mode, CodexConfigMode::Profile);
    assert_eq!(selection.config_profile.as_deref(), Some("qwen"));
    assert_eq!(selection.overrides.model, None);
    assert_eq!(selection.overrides.model_provider, None);
  }

  #[test]
  fn create_codex_selection_preserves_explicit_model_for_custom_mode() {
    let selection = create_codex_selection(
      &codex_request(
        Some(CodexConfigMode::Custom),
        None,
        Some("openrouter"),
        Some("qwen/qwen3-coder-next"),
      ),
      None,
      Some(CodexConfigSource::User),
    )
    .expect("selection should exist");

    assert_eq!(selection.config_mode, CodexConfigMode::Custom);
    assert_eq!(
      selection.overrides.model.as_deref(),
      Some("qwen/qwen3-coder-next")
    );
    assert_eq!(
      selection.overrides.model_provider.as_deref(),
      Some("openrouter")
    );
  }
}
