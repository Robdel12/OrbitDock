use crate::runtime::codex_config::{CodexConfigInspectorResponse, CodexConfigSelection};
use crate::runtime::session_creation::DirectSessionRequest;
use orbitdock_protocol::{CodexConfigMode, CodexConfigSource, Provider};

use super::create::CreateSessionRequest;

pub(super) fn create_codex_selection(
  body: &CreateSessionRequest,
  developer_instructions: Option<String>,
  codex_config_source: Option<CodexConfigSource>,
) -> Option<CodexConfigSelection> {
  if body.provider != Provider::Codex {
    return None;
  }

  let codex_overrides = orbitdock_protocol::CodexSessionOverrides {
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

pub(super) fn build_direct_session_request(
  body: &CreateSessionRequest,
  resolved_codex: Option<&CodexConfigInspectorResponse>,
  normalized_codex_selection: Option<&CodexConfigSelection>,
  dynamic_tools: Vec<codex_protocol::dynamic_tools::DynamicToolSpec>,
  claude_extra_env: Vec<(String, String)>,
  codex_config_source: Option<CodexConfigSource>,
) -> DirectSessionRequest {
  DirectSessionRequest {
    provider: body.provider,
    cwd: body.cwd.clone(),
    model: match body.provider {
      Provider::Claude => body.model.clone(),
      Provider::Codex => resolved_codex
        .and_then(|resolved| resolved.effective_settings.model.clone())
        .or_else(|| {
          normalized_codex_selection.and_then(|selection| selection.overrides.model.clone())
        }),
    },
    approval_policy: resolved_codex
      .and_then(|resolved| resolved.effective_settings.approval_policy.clone())
      .or_else(|| {
        normalized_codex_selection
          .and_then(|selection| selection.overrides.approval_policy_summary())
      }),
    sandbox_mode: resolved_codex
      .and_then(|resolved| resolved.effective_settings.sandbox_mode.clone())
      .or_else(|| {
        normalized_codex_selection.and_then(|selection| selection.overrides.sandbox_mode_summary())
      }),
    sandbox_policy_details: resolved_codex
      .and_then(|resolved| resolved.effective_settings.sandbox_policy_details.clone())
      .or_else(|| {
        normalized_codex_selection
          .and_then(|selection| selection.overrides.sandbox_policy_details.clone())
      }),
    permission_mode: body.permission_mode.clone(),
    allowed_tools: body.allowed_tools.clone(),
    disallowed_tools: body.disallowed_tools.clone(),
    effort: match body.provider {
      Provider::Claude => body.effort.clone(),
      Provider::Codex => resolved_codex
        .and_then(|resolved| resolved.effective_settings.effort.clone())
        .or_else(|| {
          normalized_codex_selection.and_then(|selection| selection.overrides.effort.clone())
        }),
    },
    collaboration_mode: resolved_codex
      .and_then(|resolved| resolved.effective_settings.collaboration_mode.clone())
      .or_else(|| {
        normalized_codex_selection
          .and_then(|selection| selection.overrides.collaboration_mode.clone())
      }),
    multi_agent: resolved_codex
      .and_then(|resolved| resolved.effective_settings.multi_agent)
      .or_else(|| normalized_codex_selection.and_then(|selection| selection.overrides.multi_agent)),
    personality: resolved_codex
      .and_then(|resolved| resolved.effective_settings.personality.clone())
      .or_else(|| {
        normalized_codex_selection.and_then(|selection| selection.overrides.personality.clone())
      }),
    service_tier: resolved_codex
      .and_then(|resolved| resolved.effective_settings.service_tier.clone())
      .or_else(|| {
        normalized_codex_selection.and_then(|selection| selection.overrides.service_tier.clone())
      }),
    developer_instructions: resolved_codex
      .and_then(|resolved| resolved.effective_settings.developer_instructions.clone())
      .or_else(|| {
        normalized_codex_selection
          .and_then(|selection| selection.overrides.developer_instructions.clone())
      }),
    mission_id: body.mission_id.clone(),
    issue_identifier: body.issue_identifier.clone(),
    worktree_id: None,
    dynamic_tools,
    allow_bypass_permissions: body.allow_bypass_permissions,
    claude_extra_env,
    codex_config_mode: resolved_codex.map(|resolved| resolved.effective_settings.config_mode),
    codex_config_profile: resolved_codex.and_then(|resolved| {
      match resolved.effective_settings.config_mode {
        CodexConfigMode::Profile => resolved.effective_settings.config_profile.clone(),
        _ => None,
      }
    }),
    codex_model_provider: resolved_codex
      .and_then(|resolved| resolved.effective_settings.model_provider.clone()),
    codex_config_source,
    codex_config_overrides: resolved_codex
      .map(|resolved| resolved.effective_settings.overrides.clone())
      .or_else(|| normalized_codex_selection.map(|selection| selection.overrides.clone())),
  }
}
