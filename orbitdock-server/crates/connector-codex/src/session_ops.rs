use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;

use codex_app_server_protocol::{
  CollaborationModeListResponse, CollaborationModeMask as AppServerCollaborationModeMask,
  McpAuthStatus as AppServerMcpAuthStatus, McpServerOauthLoginResponse, McpServerStatus,
  PluginInstallParams, PluginInstallResponse, PluginListResponse, PluginUninstallParams,
  PluginUninstallResponse, RequestId, SandboxPolicy as AppServerSandboxPolicy, TurnStartParams,
  TurnSteerParams, UserInput as AppServerUserInput,
};
use codex_protocol::config_types::{CollaborationMode, ModeKind, Settings};
use codex_protocol::openai_models::ReasoningEffort;
use codex_utils_absolute_path::AbsolutePathBuf;
use tracing::warn;

use super::config::{
  parse_approvals_reviewer, parse_personality, parse_service_tier_override,
  preferred_reasoning_summary, reasoning_summary_for_model,
};
use super::policy_bridge::{parse_approval_policy_with_details, parse_sandbox_policy_with_details};
use super::{
  CodexConfigOverrides, CodexConnector, CodexRuntimeOverrides, SteerOutcome, UpdateConfigOptions,
};
use crate::session::{CodexExecApproval, CodexPatchApproval};
use orbitdock_connector_core::{ConnectorError, ConnectorStateEvent};

fn parse_reasoning_effort(value: &str) -> Option<ReasoningEffort> {
  Some(match value {
    "none" => ReasoningEffort::None,
    "minimal" => ReasoningEffort::Minimal,
    "low" => ReasoningEffort::Low,
    "medium" => ReasoningEffort::Medium,
    "high" => ReasoningEffort::High,
    "xhigh" => ReasoningEffort::XHigh,
    _ => return None,
  })
}

fn parse_mode_kind(value: &str) -> Option<ModeKind> {
  match value.trim().to_ascii_lowercase().as_str() {
    "plan" => Some(ModeKind::Plan),
    "default" | "code" | "pair_programming" | "execute" | "custom" => Some(ModeKind::Default),
    _ => None,
  }
}

fn collaboration_mode_name(mode: ModeKind) -> &'static str {
  match mode {
    ModeKind::Plan => "plan",
    ModeKind::Default | ModeKind::PairProgramming | ModeKind::Execute => "default",
  }
}

fn convert_app_server_type<T, U>(value: T, label: &str) -> Result<U, ConnectorError>
where
  T: serde::Serialize,
  U: serde::de::DeserializeOwned,
{
  serde_json::from_value(serde_json::to_value(value).map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to encode Codex {label}: {error}"))
  })?)
  .map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to convert Codex {label} for app-server: {error}"
    ))
  })
}

fn convert_optional<T, U>(value: Option<T>, label: &str) -> Result<Option<U>, ConnectorError>
where
  T: serde::Serialize,
  U: serde::de::DeserializeOwned,
{
  value
    .map(|inner| convert_app_server_type(inner, label))
    .transpose()
}

fn flatten_mcp_tools(
  statuses: &[McpServerStatus],
) -> Result<HashMap<String, orbitdock_protocol::McpTool>, ConnectorError> {
  let mut tools = HashMap::new();

  for status in statuses {
    for (tool_name, tool) in &status.tools {
      tools.insert(
        tool_name.clone(),
        convert_app_server_type(tool.clone(), "MCP tool")?,
      );
    }
  }

  Ok(tools)
}

fn convert_mcp_auth_status(value: AppServerMcpAuthStatus) -> orbitdock_protocol::McpAuthStatus {
  match value {
    AppServerMcpAuthStatus::Unsupported => orbitdock_protocol::McpAuthStatus::Unsupported,
    AppServerMcpAuthStatus::NotLoggedIn => orbitdock_protocol::McpAuthStatus::NotLoggedIn,
    AppServerMcpAuthStatus::BearerToken => orbitdock_protocol::McpAuthStatus::BearerToken,
    AppServerMcpAuthStatus::OAuth => orbitdock_protocol::McpAuthStatus::OAuth,
  }
}

fn app_server_request_id(value: &str) -> RequestId {
  value
    .parse::<i64>()
    .map(RequestId::Integer)
    .unwrap_or_else(|_| RequestId::String(value.to_string()))
}

async fn take_pending_request(connector: &CodexConnector, request_id: &str) -> RequestId {
  connector
    .pending_app_server_requests
    .lock()
    .await
    .remove(request_id)
    .unwrap_or_else(|| app_server_request_id(request_id))
}

fn app_server_user_input(
  content: &str,
  skills: &[orbitdock_protocol::SkillInput],
  images: &[orbitdock_protocol::ImageInput],
  mentions: &[orbitdock_protocol::MentionInput],
) -> Vec<AppServerUserInput> {
  let mut items = Vec::new();
  if !content.is_empty() {
    items.push(AppServerUserInput::Text {
      text: content.to_string(),
      text_elements: Vec::new(),
    });
  }

  for skill in skills {
    items.push(AppServerUserInput::Skill {
      name: skill.name.clone(),
      path: PathBuf::from(&skill.path),
    });
  }

  for image in images {
    match image.input_type.as_str() {
      "url" => items.push(AppServerUserInput::Image {
        url: image.value.clone(),
      }),
      "path" => items.push(AppServerUserInput::LocalImage {
        path: PathBuf::from(&image.value),
      }),
      other => {
        warn!("Unknown image input_type: {}, treating as url", other);
        items.push(AppServerUserInput::Image {
          url: image.value.clone(),
        });
      }
    }
  }

  for mention in mentions {
    items.push(AppServerUserInput::Mention {
      name: mention.name.clone(),
      path: mention.path.clone(),
    });
  }

  items
}

fn select_collaboration_mode_mask(
  masks: Vec<AppServerCollaborationModeMask>,
  mode: ModeKind,
  requested_name: &str,
) -> Option<AppServerCollaborationModeMask> {
  let normalized = requested_name.trim();
  masks.into_iter().find(|mask| {
    mask.name.trim().eq_ignore_ascii_case(normalized)
      || mask
        .mode
        .map(|candidate| candidate == mode)
        .unwrap_or(false)
  })
}

fn build_collaboration_mode(
  mode: ModeKind,
  selected_mask: Option<AppServerCollaborationModeMask>,
  model: String,
  effort: Option<ReasoningEffort>,
  developer_instructions: Option<&str>,
) -> CollaborationMode {
  let mask_model = selected_mask.as_ref().and_then(|mask| mask.model.clone());
  let mask_effort = selected_mask
    .and_then(|mask| mask.reasoning_effort)
    .flatten();

  CollaborationMode {
    mode,
    settings: Settings {
      model: mask_model.unwrap_or(model),
      reasoning_effort: mask_effort.or(effort),
      developer_instructions: developer_instructions.map(ToString::to_string),
    },
  }
}

async fn app_server_collaboration_mode_for_update(
  app_server: &crate::app_server::CodexAppServer,
  explicit_collaboration_mode: Option<&str>,
  permission_mode: Option<&str>,
  model: String,
  effort: Option<ReasoningEffort>,
  developer_instructions: Option<&str>,
) -> Result<Option<CollaborationMode>, ConnectorError> {
  let requested_mode = explicit_collaboration_mode
    .or(permission_mode)
    .and_then(parse_mode_kind);
  let requested_name = explicit_collaboration_mode
    .or(permission_mode)
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .map(ToString::to_string);

  if requested_mode.is_none() && developer_instructions.is_none() {
    return Ok(None);
  }

  let mode = requested_mode.unwrap_or(ModeKind::Default);
  let name = requested_name
    .as_deref()
    .unwrap_or_else(|| collaboration_mode_name(mode));
  let masks = app_server.collaboration_mode_list().await?.data;
  let selected_mask = select_collaboration_mode_mask(masks, mode, name);

  Ok(Some(build_collaboration_mode(
    mode,
    selected_mask,
    model,
    effort,
    developer_instructions,
  )))
}

impl CodexConnector {
  pub async fn fork_thread(
    &self,
    model: Option<&str>,
    approval_policy: Option<&str>,
    sandbox_mode: Option<&str>,
    cwd: Option<&str>,
  ) -> Result<(CodexConnector, String), ConnectorError> {
    let app_server = self.app_server_session()?;
    let effective_cwd = cwd.unwrap_or(".");
    let approval_policy =
      parse_approval_policy_with_details(approval_policy, None).map_err(|error| {
        ConnectorError::ProviderError(format!("Invalid approval policy: {error}"))
      })?;
    let sandbox = parse_sandbox_policy_with_details(sandbox_mode, None)
      .map_err(|error| ConnectorError::ProviderError(format!("Invalid sandbox mode: {error}")))?;
    let response = app_server
      .thread_fork(codex_app_server_protocol::ThreadForkParams {
        thread_id: self.thread_id.clone(),
        path: None,
        model: model.map(ToString::to_string),
        model_provider: None,
        service_tier: None,
        cwd: Some(effective_cwd.to_string()),
        approval_policy: convert_optional(approval_policy, "approval policy")?,
        approvals_reviewer: None,
        sandbox: sandbox.map(|policy| match policy {
          codex_protocol::protocol::SandboxPolicy::DangerFullAccess => {
            codex_app_server_protocol::SandboxMode::DangerFullAccess
          }
          codex_protocol::protocol::SandboxPolicy::ReadOnly { .. } => {
            codex_app_server_protocol::SandboxMode::ReadOnly
          }
          _ => codex_app_server_protocol::SandboxMode::WorkspaceWrite,
        }),
        permission_profile: None,
        config: None,
        base_instructions: None,
        developer_instructions: None,
        ephemeral: false,
        exclude_turns: false,
        persist_extended_history: true,
      })
      .await
      .map_err(|e| ConnectorError::ProviderError(format!("Failed to fork thread: {}", e)))?;

    let new_thread_id = response.thread.id.clone();
    let reasoning_effort = convert_optional(response.reasoning_effort, "reasoning effort")?;
    let connector = Self::from_app_server_thread(
      app_server,
      new_thread_id.clone(),
      self.codex_home.clone(),
      effective_cwd,
      Some(response.model),
      reasoning_effort,
    )
    .await?;

    Ok((connector, new_thread_id))
  }

  pub async fn send_message(
    &self,
    content: &str,
    model: Option<&str>,
    effort: Option<&str>,
    skills: &[orbitdock_protocol::SkillInput],
    images: &[orbitdock_protocol::ImageInput],
    mentions: &[orbitdock_protocol::MentionInput],
  ) -> Result<(), ConnectorError> {
    let app_server = self.app_server_session()?;
    let effort_value = effort.and_then(parse_reasoning_effort);
    let effective_model = if let Some(model) = model {
      Some(model.to_string())
    } else {
      self.current_model.lock().await.clone()
    };
    let summary = Some(reasoning_summary_for_model(
      effective_model.as_deref(),
      preferred_reasoning_summary(),
    ));
    let cwd = self.current_cwd.lock().await.clone();
    let pending_context = self.pending_turn_context.lock().await.clone();
    let requested_model = model.map(ToString::to_string).or(pending_context.model);
    let requested_effort =
      convert_optional(effort_value, "reasoning effort")?.or(pending_context.effort);
    let requested_summary =
      convert_optional(summary, "reasoning summary")?.or(pending_context.summary);
    let requested_collaboration_mode = pending_context.collaboration_mode;
    let next_model = requested_collaboration_mode
      .as_ref()
      .map(|mode| mode.settings.model.clone())
      .or_else(|| requested_model.clone());
    let next_effort = requested_collaboration_mode
      .as_ref()
      .map(|mode| mode.settings.reasoning_effort)
      .unwrap_or(requested_effort);
    let response = app_server
      .turn_start(TurnStartParams {
        thread_id: self.thread_id.clone(),
        input: app_server_user_input(content, skills, images, mentions),
        responsesapi_client_metadata: None,
        environments: None,
        cwd: pending_context
          .cwd
          .or_else(|| (!cwd.trim().is_empty()).then(|| PathBuf::from(cwd.as_str()))),
        approval_policy: pending_context.approval_policy,
        approvals_reviewer: pending_context.approvals_reviewer,
        sandbox_policy: pending_context.sandbox_policy,
        permission_profile: None,
        model: requested_model,
        service_tier: pending_context.service_tier,
        effort: requested_effort,
        summary: requested_summary,
        personality: pending_context.personality,
        output_schema: None,
        collaboration_mode: requested_collaboration_mode,
      })
      .await?;
    *self.pending_turn_context.lock().await = Default::default();
    *self.active_turn_id.lock().await = Some(response.turn.id);
    if let Some(model) = next_model {
      *self.current_model.lock().await = Some(model);
    }
    *self.current_reasoning_effort.lock().await = next_effort;

    Ok(())
  }

  pub async fn steer_turn(
    &self,
    content: &str,
    images: &[orbitdock_protocol::ImageInput],
    mentions: &[orbitdock_protocol::MentionInput],
  ) -> Result<SteerOutcome, ConnectorError> {
    let expected_turn_id = self
      .active_turn_id
      .lock()
      .await
      .clone()
      .ok_or_else(|| ConnectorError::ProviderError("No active turn to steer".into()))?;
    self
      .app_server_session()?
      .turn_steer(TurnSteerParams {
        thread_id: self.thread_id.clone(),
        input: app_server_user_input(content, &[], images, mentions),
        responsesapi_client_metadata: None,
        expected_turn_id,
      })
      .await?;
    Ok(SteerOutcome::Accepted)
  }

  pub async fn session_shell_command(&self, command: &str) -> Result<(), ConnectorError> {
    self
      .app_server_session()?
      .thread_shell_command(self.thread_id.clone(), command.to_string())
      .await?;
    Ok(())
  }

  pub async fn list_skills(
    &self,
    cwds: Vec<String>,
    force_reload: bool,
  ) -> Result<(), ConnectorError> {
    let response = self
      .app_server_session()?
      .skills_list(codex_app_server_protocol::SkillsListParams {
        cwds: crate::app_server::compat::strings_to_path_bufs(cwds),
        force_reload,
        per_cwd_extra_user_roots: None,
      })
      .await?;
    let skills = response
      .data
      .into_iter()
      .map(|entry| orbitdock_protocol::SkillsListEntry {
        cwd: entry.cwd.to_string_lossy().to_string(),
        skills: entry
          .skills
          .into_iter()
          .map(|skill| orbitdock_protocol::SkillMetadata {
            name: skill.name,
            description: skill.description,
            short_description: skill.short_description,
            path: skill.path.to_string_lossy().to_string(),
            scope: convert_app_server_type(skill.scope, "skill scope")
              .unwrap_or(orbitdock_protocol::SkillScope::User),
            enabled: skill.enabled,
          })
          .collect(),
        errors: entry
          .errors
          .into_iter()
          .map(|error| orbitdock_protocol::SkillErrorInfo {
            path: error.path.to_string_lossy().to_string(),
            message: error.message,
          })
          .collect(),
      })
      .collect();
    let output = ConnectorStateEvent::SkillsList {
      skills,
      errors: Vec::new(),
    }
    .into();
    self
      .output_tx
      .send(output)
      .await
      .map_err(|_| ConnectorError::ProviderError("Codex output channel is closed".to_string()))?;
    Ok(())
  }

  pub async fn list_plugins(
    &self,
    cwd: &str,
    cwds: Vec<String>,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: &CodexRuntimeOverrides,
  ) -> Result<PluginListResponse, ConnectorError> {
    let roots: Vec<_> = cwds
      .into_iter()
      .map(|value| normalize_absolute_path(cwd, &value))
      .collect::<Result<_, _>>()?;
    crate::app_server::shared_app_server(cwd, config_overrides, runtime_overrides)
      .await?
      .plugin_list(roots)
      .await
  }

  pub async fn list_collaboration_modes(
    &self,
  ) -> Result<CollaborationModeListResponse, ConnectorError> {
    self.app_server_session()?.collaboration_mode_list().await
  }

  pub async fn install_plugin(
    &self,
    cwd: &str,
    params: PluginInstallParams,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: &CodexRuntimeOverrides,
  ) -> Result<PluginInstallResponse, ConnectorError> {
    crate::app_server::shared_app_server(cwd, config_overrides, runtime_overrides)
      .await?
      .plugin_install(params)
      .await
  }

  pub async fn uninstall_plugin(
    &self,
    cwd: &str,
    params: PluginUninstallParams,
    config_overrides: &CodexConfigOverrides,
    runtime_overrides: &CodexRuntimeOverrides,
  ) -> Result<PluginUninstallResponse, ConnectorError> {
    crate::app_server::shared_app_server(cwd, config_overrides, runtime_overrides)
      .await?
      .plugin_uninstall(params)
      .await
  }

  pub async fn list_mcp_tools(&self) -> Result<(), ConnectorError> {
    let response = self.app_server_session()?.mcp_server_status_list().await?;
    let tools = flatten_mcp_tools(&response.data)?;
    let resources = response
      .data
      .iter()
      .map(|status| {
        Ok((
          status.name.clone(),
          convert_app_server_type(status.resources.clone(), "MCP resources")?,
        ))
      })
      .collect::<Result<HashMap<_, _>, ConnectorError>>()?;
    let resource_templates = response
      .data
      .iter()
      .map(|status| {
        Ok((
          status.name.clone(),
          convert_app_server_type(status.resource_templates.clone(), "MCP resource templates")?,
        ))
      })
      .collect::<Result<HashMap<_, _>, ConnectorError>>()?;
    let auth_statuses = response
      .data
      .into_iter()
      .map(|status| (status.name, convert_mcp_auth_status(status.auth_status)))
      .collect::<HashMap<_, _>>();
    let output = ConnectorStateEvent::McpToolsList {
      tools,
      resources,
      resource_templates,
      auth_statuses,
    }
    .into();
    self
      .output_tx
      .send(output)
      .await
      .map_err(|_| ConnectorError::ProviderError("Codex output channel is closed".to_string()))?;
    Ok(())
  }

  pub async fn refresh_mcp_servers(&self) -> Result<(), ConnectorError> {
    self.app_server_session()?.mcp_server_refresh().await?;
    Ok(())
  }

  pub async fn authenticate_mcp_server(
    &self,
    server_name: &str,
  ) -> Result<McpServerOauthLoginResponse, ConnectorError> {
    self
      .app_server_session()?
      .mcp_server_oauth_login(server_name.to_string())
      .await
  }

  pub async fn interrupt(&self) -> Result<(), ConnectorError> {
    let Some(turn_id) = self.active_turn_id.lock().await.clone() else {
      return Ok(());
    };
    self
      .app_server_session()?
      .turn_interrupt(codex_app_server_protocol::TurnInterruptParams {
        thread_id: self.thread_id.clone(),
        turn_id,
      })
      .await?;

    Ok(())
  }

  pub async fn approve_exec(
    &self,
    request_id: &str,
    decision: CodexExecApproval,
  ) -> Result<(), ConnectorError> {
    let server_request_id = take_pending_request(self, request_id).await;
    self
      .app_server_session()?
      .resolve_server_request(
        server_request_id,
        crate::app_server::response_codec::exec_approval_response(decision),
      )
      .await?;

    Ok(())
  }

  pub async fn approve_patch(
    &self,
    request_id: &str,
    decision: CodexPatchApproval,
  ) -> Result<(), ConnectorError> {
    let server_request_id = take_pending_request(self, request_id).await;
    self
      .app_server_session()?
      .resolve_server_request(
        server_request_id,
        crate::app_server::response_codec::patch_approval_response(decision),
      )
      .await?;

    Ok(())
  }

  pub async fn answer_question(
    &self,
    request_id: &str,
    answers: HashMap<String, Vec<String>>,
  ) -> Result<(), ConnectorError> {
    let server_request_id = take_pending_request(self, request_id).await;
    self
      .app_server_session()?
      .resolve_server_request(
        server_request_id,
        crate::app_server::response_codec::question_response(answers),
      )
      .await?;

    Ok(())
  }

  pub async fn respond_to_permission_request(
    &self,
    request_id: &str,
    permissions: serde_json::Value,
    scope: orbitdock_protocol::PermissionGrantScope,
  ) -> Result<(), ConnectorError> {
    let server_request_id = take_pending_request(self, request_id).await;
    let response = crate::app_server::response_codec::permissions_response(permissions, scope)?;
    self
      .app_server_session()?
      .resolve_server_request(server_request_id, response)
      .await?;

    Ok(())
  }

  pub async fn set_thread_name(&self, name: &str) -> Result<(), ConnectorError> {
    self
      .app_server_session()?
      .thread_set_name(self.thread_id.clone(), name.to_string())
      .await?;

    Ok(())
  }

  pub async fn update_config(
    &self,
    options: UpdateConfigOptions<'_>,
  ) -> Result<(), ConnectorError> {
    let UpdateConfigOptions {
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      sandbox_policy_details,
      approvals_reviewer,
      permission_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      model,
      effort,
    } = options;

    let app_server = self.app_server_session()?;
    let policy = parse_approval_policy_with_details(approval_policy, approval_policy_details)
      .map_err(|e| ConnectorError::ProviderError(format!("Invalid approval policy: {e}")))?;
    let sandbox = parse_sandbox_policy_with_details(sandbox_mode, sandbox_policy_details)
      .map_err(|e| ConnectorError::ProviderError(format!("Invalid sandbox mode: {e}")))?;

    let approvals_reviewer = parse_approvals_reviewer(approvals_reviewer);
    // The app-server exposes collaboration mode as a per-turn override, but
    // multi-agent is a thread/runtime feature. OrbitDock applies it when the
    // session is started or resumed, and persists mid-session changes for the
    // next materialization.
    let _ = multi_agent;
    let effort = effort.and_then(parse_reasoning_effort);
    let current_model = self.current_model.lock().await.clone();
    let effective_model = model
      .map(ToString::to_string)
      .or(current_model)
      .ok_or_else(|| ConnectorError::ProviderError("Codex model is not available".to_string()))?;
    let effective_effort = effort.or(*self.current_reasoning_effort.lock().await);
    let collaboration_mode = app_server_collaboration_mode_for_update(
      &app_server,
      collaboration_mode,
      permission_mode,
      effective_model.clone(),
      effective_effort,
      developer_instructions,
    )
    .await?;
    let override_cwd = {
      let cwd = self.current_cwd.lock().await;
      cwd.trim().to_string()
    };
    let mut pending = self.pending_turn_context.lock().await;
    pending.cwd = (!override_cwd.is_empty()).then(|| PathBuf::from(override_cwd.as_str()));
    pending.approval_policy = convert_optional(policy, "approval policy")?;
    pending.approvals_reviewer = convert_optional(approvals_reviewer, "approvals reviewer")?;
    pending.sandbox_policy =
      convert_optional::<_, AppServerSandboxPolicy>(sandbox, "sandbox policy")?;
    pending.model = model.map(ToString::to_string);
    pending.service_tier =
      convert_optional(parse_service_tier_override(service_tier), "service tier")?;
    pending.effort = convert_optional(effort, "reasoning effort")?;
    pending.personality = convert_optional(parse_personality(personality), "personality")?;
    pending.collaboration_mode = convert_optional(collaboration_mode, "collaboration mode")?;

    Ok(())
  }

  pub async fn compact(&self) -> Result<(), ConnectorError> {
    self
      .app_server_session()?
      .thread_compact_start(self.thread_id.clone())
      .await?;
    Ok(())
  }

  pub async fn undo(&self) -> Result<(), ConnectorError> {
    self.thread_rollback(1).await?;
    Ok(())
  }

  pub async fn thread_rollback(&self, num_turns: u32) -> Result<(), ConnectorError> {
    self
      .app_server_session()?
      .thread_rollback(self.thread_id.clone(), num_turns)
      .await?;
    Ok(())
  }

  pub async fn submit_dynamic_tool_response(
    &self,
    call_id: String,
    response: codex_protocol::dynamic_tools::DynamicToolResponse,
  ) -> Result<(), ConnectorError> {
    let server_request_id = take_pending_request(self, &call_id).await;
    let response = crate::app_server::response_codec::dynamic_tool_response(response)?;
    self
      .app_server_session()?
      .resolve_server_request(server_request_id, response)
      .await?;
    Ok(())
  }

  pub async fn shutdown(&self) -> Result<(), ConnectorError> {
    if let Some(app_server) = self.app_server.as_ref() {
      app_server.unregister_session(&self.thread_id).await;
    }
    Ok(())
  }
}

fn normalize_absolute_path(cwd: &str, value: &str) -> Result<AbsolutePathBuf, ConnectorError> {
  let path = PathBuf::from(value);
  let path = if path.is_absolute() {
    path
  } else {
    Path::new(cwd).join(path)
  };

  AbsolutePathBuf::try_from(path)
    .map_err(|e| ConnectorError::ProviderError(format!("Invalid plugin cwd path `{value}`: {}", e)))
}

#[cfg(test)]
#[path = "session_ops_tests.rs"]
mod session_ops_tests;
