use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  http::StatusCode,
  Json,
};
use codex_app_server_protocol::{
  PluginInstallParams, PluginInstallResponse, PluginListResponse, PluginUninstallParams,
  PluginUninstallResponse,
};
use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_connector_codex::{CodexConfigOverrides, CodexControlPlane};
use orbitdock_protocol::{
  McpAuthStatus, McpResource, McpResourceTemplate, McpTool, SkillErrorInfo, SkillsListEntry,
};
use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_queries::load_full_session_state;
use crate::runtime::session_registry::SessionRegistry;

use super::connector_actions::{
  dispatch_claude_action, dispatch_codex_action, dispatch_codex_query, subscribe_session_events,
  wait_for_codex_skills_event, wait_for_mcp_tools_event,
};
use super::errors::{ApiErrorResponse, ApiResult};
use super::session_actions::AcceptedResponse;

#[derive(Debug, Serialize)]
pub struct SkillsResponse {
  pub session_id: String,
  pub skills: Vec<SkillsListEntry>,
  pub errors: Vec<SkillErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct McpToolsResponse {
  pub session_id: String,
  pub tools: HashMap<String, McpTool>,
  pub resources: HashMap<String, Vec<McpResource>>,
  pub resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
  pub auth_statuses: HashMap<String, McpAuthStatus>,
}

#[derive(Debug, Serialize)]
pub struct SessionInstructionsResponse {
  pub session_id: String,
  pub provider: orbitdock_protocol::Provider,
  pub instructions: SessionInstructionsPayload,
}

#[derive(Debug, Serialize, Default)]
pub struct SessionInstructionsPayload {
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub claude_md: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub system_prompt: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub developer_instructions: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RefreshMcpServerRequest {
  pub server_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct McpToggleRequest {
  pub server_name: String,
  pub enabled: bool,
}

#[derive(Debug, Deserialize)]
pub struct McpServerNameRequest {
  pub server_name: String,
}

#[derive(Debug, Deserialize)]
pub struct McpSetServersRequest {
  pub servers: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct ApplyFlagSettingsRequest {
  pub settings: serde_json::Value,
}

#[derive(Debug, Deserialize, Default)]
pub struct SkillsQuery {
  #[serde(default)]
  pub cwd: Vec<String>,
  #[serde(default)]
  pub force_reload: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct PluginsQuery {
  #[serde(default)]
  pub cwd: Vec<String>,
  #[serde(default)]
  pub force_remote_sync: Option<bool>,
}

async fn read_optional_markdown(path: PathBuf) -> Option<String> {
  tokio::fs::read_to_string(path)
    .await
    .ok()
    .filter(|contents| !contents.trim().is_empty())
}

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

pub async fn list_skills_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<SkillsQuery>,
) -> ApiResult<SkillsResponse> {
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
    errors,
  }))
}

fn codex_plugin_context(
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

pub async fn list_plugins_endpoint(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Query(query): Query<PluginsQuery>,
) -> ApiResult<PluginListResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| super::connector_actions::session_not_found_error(&session_id))?;
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

pub async fn install_plugin(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<PluginInstallParams>,
) -> ApiResult<PluginInstallResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| super::connector_actions::session_not_found_error(&session_id))?;
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
  Json(body): Json<PluginUninstallParams>,
) -> ApiResult<PluginUninstallResponse> {
  let session = load_full_session_state(&state, &session_id, false, false)
    .await
    .map_err(|_| super::connector_actions::session_not_found_error(&session_id))?;
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

  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse { accepted: true }),
  ))
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

  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse { accepted: true }),
  ))
}

pub async fn mcp_authenticate(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<McpServerNameRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
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
    Json(AcceptedResponse { accepted: true }),
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

  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse { accepted: true }),
  ))
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

  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse { accepted: true }),
  ))
}

pub async fn apply_flag_settings(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<ApplyFlagSettingsRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  dispatch_claude_action(
    &state,
    &session_id,
    ClaudeAction::ApplyFlagSettings {
      settings: body.settings,
    },
  )
  .await?;

  Ok((
    StatusCode::ACCEPTED,
    Json(AcceptedResponse { accepted: true }),
  ))
}

#[cfg(test)]
mod tests {
  use super::*;
  use axum::{extract::Path, extract::Query, extract::State, Json};
  use codex_app_server_protocol::{
    PluginAuthPolicy, PluginInstallPolicy, PluginListResponse, PluginMarketplaceEntry,
    PluginSource, PluginSummary,
  };
  use codex_utils_absolute_path::AbsolutePathBuf;
  use orbitdock_protocol::{
    McpAuthStatus, McpResource, McpResourceTemplate, McpTool, Provider, ServerMessage,
    SkillErrorInfo, SkillMetadata, SkillScope, SkillsListEntry,
  };
  use serde_json::json;
  use std::collections::HashMap;
  use std::path::PathBuf;
  use tokio::sync::mpsc;

  use crate::connectors::codex_session::CodexAction;
  use crate::domain::sessions::session::SessionHandle;
  use crate::infrastructure::persistence::{
    flush_batch_for_test, PersistCommand, SessionCreateParams,
  };
  use crate::runtime::session_commands::SessionCommand;
  use crate::transport::http::test_support::{new_persist_test_state, new_test_state};

  fn persist_codex_session(
    db_path: &PathBuf,
    session_id: &str,
    project_path: &str,
    developer_instructions: Option<&str>,
  ) {
    flush_batch_for_test(
      db_path,
      vec![PersistCommand::SessionCreate(Box::new(
        SessionCreateParams {
          id: session_id.to_string(),
          provider: Provider::Codex,
          control_mode: orbitdock_protocol::SessionControlMode::Passive,
          project_path: project_path.to_string(),
          project_name: Some("orbitdock-api-test".to_string()),
          branch: Some("main".to_string()),
          model: Some("gpt-5".to_string()),
          approval_policy: None,
          sandbox_mode: None,
          permission_mode: None,
          collaboration_mode: None,
          multi_agent: None,
          personality: None,
          service_tier: None,
          developer_instructions: developer_instructions.map(str::to_string),
          codex_config_mode: None,
          codex_config_profile: None,
          codex_model_provider: None,
          codex_config_source: None,
          codex_config_overrides_json: None,
          forked_from_session_id: None,
          mission_id: None,
          issue_identifier: None,
          allow_bypass_permissions: false,
          worktree_id: None,
        },
      ))],
    )
    .expect("persist codex session fixture");
  }

  #[tokio::test]
  async fn list_skills_endpoint_dispatches_action_and_returns_payload() {
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-api-test".to_string(),
    ));
    let actor = state
      .get_session(&session_id)
      .expect("session should exist for skills endpoint test");
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_codex_action_tx(&session_id, action_tx);

    let session_id_for_task = session_id.clone();
    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("skills endpoint should dispatch codex action");
      match action {
        CodexAction::ListSkills { cwds, force_reload } => {
          assert_eq!(cwds, vec!["/tmp/orbitdock-api-test".to_string()]);
          assert!(force_reload);
        }
        other => panic!("expected ListSkills action, got {:?}", other),
      }

      actor
        .send(SessionCommand::Broadcast {
          msg: ServerMessage::SkillsList {
            session_id: session_id_for_task.clone(),
            skills: vec![SkillsListEntry {
              cwd: "/tmp/orbitdock-api-test".to_string(),
              skills: vec![SkillMetadata {
                name: "deploy".to_string(),
                description: "Deploy app".to_string(),
                short_description: Some("Deploy".to_string()),
                path: "/tmp/orbitdock-api-test/.codex/skills/deploy.md".to_string(),
                scope: SkillScope::Repo,
                enabled: true,
              }],
              errors: vec![],
            }],
            errors: vec![SkillErrorInfo {
              path: "/tmp/orbitdock-api-test/.codex/skills/bad.md".to_string(),
              message: "invalid frontmatter".to_string(),
            }],
          },
        })
        .await;
    });

    let response = list_skills_endpoint(
      Path(session_id.clone()),
      State(state),
      Query(SkillsQuery {
        cwd: vec!["/tmp/orbitdock-api-test".to_string()],
        force_reload: Some(true),
      }),
    )
    .await;

    task
      .await
      .expect("skills endpoint helper task should complete");

    match response {
      Ok(Json(payload)) => {
        assert_eq!(payload.session_id, session_id);
        assert_eq!(payload.skills.len(), 1);
        assert_eq!(payload.skills[0].cwd, "/tmp/orbitdock-api-test");
        assert_eq!(payload.skills[0].skills.len(), 1);
        assert_eq!(payload.skills[0].skills[0].name, "deploy");
        assert_eq!(payload.errors.len(), 1);
        assert_eq!(
          payload.errors[0].path,
          "/tmp/orbitdock-api-test/.codex/skills/bad.md"
        );
      }
      Err((status, body)) => panic!(
        "expected successful skills response, got status {:?} with error {:?}",
        status, body.error
      ),
    }
  }

  #[tokio::test]
  async fn list_plugins_endpoint_dispatches_action_and_returns_payload() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(&db_path, &session_id, "/tmp/orbitdock-api-test", None);
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_codex_action_tx(&session_id, action_tx);

    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("plugins endpoint should dispatch codex action");
      match action {
        CodexAction::ListPlugins {
          cwd,
          cwds,
          force_remote_sync,
          reply_tx,
          ..
        } => {
          assert_eq!(cwd, "/tmp/orbitdock-api-test");
          assert_eq!(cwds, vec!["/tmp/orbitdock-api-test".to_string()]);
          assert!(force_remote_sync);
          let response = PluginListResponse {
            marketplaces: vec![PluginMarketplaceEntry {
              name: "Curated".to_string(),
              path: AbsolutePathBuf::try_from(PathBuf::from(
                "/tmp/orbitdock-api-test/.codex/plugins/marketplace.toml",
              ))
              .expect("absolute marketplace path"),
              interface: None,
              plugins: vec![PluginSummary {
                id: "marketplace/deploy-checks".to_string(),
                name: "deploy-checks".to_string(),
                source: PluginSource::Local {
                  path: AbsolutePathBuf::try_from(PathBuf::from(
                    "/tmp/orbitdock-api-test/.codex/plugins/deploy-checks",
                  ))
                  .expect("absolute plugin path"),
                },
                installed: true,
                enabled: true,
                install_policy: PluginInstallPolicy::Available,
                auth_policy: PluginAuthPolicy::OnInstall,
                interface: None,
              }],
            }],
            marketplace_load_errors: Vec::new(),
            remote_sync_error: None,
            featured_plugin_ids: Vec::new(),
          };
          let _ = reply_tx.send(Ok(response));
        }
        other => panic!("expected ListPlugins action, got {:?}", other),
      }
    });

    let response = list_plugins_endpoint(
      Path(session_id.clone()),
      State(state),
      Query(PluginsQuery {
        cwd: vec!["/tmp/orbitdock-api-test".to_string()],
        force_remote_sync: Some(true),
      }),
    )
    .await;

    task
      .await
      .expect("plugins endpoint helper task should complete");

    match response {
      Ok(Json(payload)) => {
        assert_eq!(payload.marketplaces.len(), 1);
        assert_eq!(payload.marketplaces[0].name, "Curated");
        assert_eq!(payload.marketplaces[0].plugins.len(), 1);
        assert_eq!(
          payload.marketplaces[0].plugins[0].id,
          "marketplace/deploy-checks"
        );
      }
      Err((status, body)) => panic!(
        "expected successful plugins response, got status {:?} with error {:?}",
        status, body.error
      ),
    }
  }

  #[tokio::test]
  async fn install_plugin_endpoint_dispatches_action_and_returns_payload() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(&db_path, &session_id, "/tmp/orbitdock-api-test", None);
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_codex_action_tx(&session_id, action_tx);

    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("install plugin endpoint should dispatch codex action");
      match action {
        CodexAction::InstallPlugin {
          cwd,
          params,
          reply_tx,
          ..
        } => {
          assert_eq!(cwd, "/tmp/orbitdock-api-test");
          assert_eq!(params.plugin_name, "deploy-checks");
          assert!(params.force_remote_sync);
          assert_eq!(
            params.marketplace_path.as_path(),
            std::path::Path::new("/tmp/orbitdock-api-test/.codex/plugins/marketplace.toml")
          );
          let _ = reply_tx.send(Ok(PluginInstallResponse {
            auth_policy: PluginAuthPolicy::OnInstall,
            apps_needing_auth: vec![],
          }));
        }
        other => panic!("expected InstallPlugin action, got {:?}", other),
      }
    });

    let response = install_plugin(
      Path(session_id),
      State(state),
      Json(PluginInstallParams {
        marketplace_path: AbsolutePathBuf::try_from(PathBuf::from(
          "/tmp/orbitdock-api-test/.codex/plugins/marketplace.toml",
        ))
        .expect("absolute marketplace path"),
        plugin_name: "deploy-checks".to_string(),
        force_remote_sync: true,
      }),
    )
    .await;

    task
      .await
      .expect("install plugin endpoint helper task should complete");

    match response {
      Ok(Json(payload)) => {
        assert_eq!(payload.auth_policy, PluginAuthPolicy::OnInstall);
        assert!(payload.apps_needing_auth.is_empty());
      }
      Err((status, body)) => panic!(
        "expected successful install plugin response, got status {:?} with error {:?}",
        status, body.error
      ),
    }
  }

  #[tokio::test]
  async fn uninstall_plugin_endpoint_dispatches_action_and_returns_payload() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(&db_path, &session_id, "/tmp/orbitdock-api-test", None);
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_codex_action_tx(&session_id, action_tx);

    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("uninstall plugin endpoint should dispatch codex action");
      match action {
        CodexAction::UninstallPlugin {
          cwd,
          params,
          reply_tx,
          ..
        } => {
          assert_eq!(cwd, "/tmp/orbitdock-api-test");
          assert_eq!(params.plugin_id, "marketplace/deploy-checks");
          assert!(params.force_remote_sync);
          let _ = reply_tx.send(Ok(PluginUninstallResponse {}));
        }
        other => panic!("expected UninstallPlugin action, got {:?}", other),
      }
    });

    let response = uninstall_plugin(
      Path(session_id),
      State(state),
      Json(PluginUninstallParams {
        plugin_id: "marketplace/deploy-checks".to_string(),
        force_remote_sync: true,
      }),
    )
    .await;

    task
      .await
      .expect("uninstall plugin endpoint helper task should complete");

    match response {
      Ok(Json(_payload)) => {}
      Err((status, body)) => panic!(
        "expected successful uninstall plugin response, got status {:?} with error {:?}",
        status, body.error
      ),
    }
  }

  #[tokio::test]
  async fn list_mcp_tools_endpoint_dispatches_action_and_returns_payload() {
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-api-test".to_string(),
    ));
    let actor = state
      .get_session(&session_id)
      .expect("session should exist for mcp tools endpoint test");
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_codex_action_tx(&session_id, action_tx);

    let session_id_for_task = session_id.clone();
    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("mcp tools endpoint should dispatch codex action");
      match action {
        CodexAction::ListMcpTools => {}
        other => panic!("expected ListMcpTools action, got {:?}", other),
      }

      let mut tools = HashMap::new();
      tools.insert(
        "docs__search".to_string(),
        McpTool {
          name: "search".to_string(),
          title: Some("Search Docs".to_string()),
          description: Some("Searches docs".to_string()),
          input_schema: json!({"type": "object"}),
          output_schema: None,
          annotations: None,
        },
      );

      let mut resources = HashMap::new();
      resources.insert(
        "docs".to_string(),
        vec![McpResource {
          name: "overview".to_string(),
          uri: "docs://overview".to_string(),
          description: Some("Docs overview".to_string()),
          mime_type: Some("text/markdown".to_string()),
          title: None,
          size: None,
          annotations: None,
        }],
      );

      let mut resource_templates = HashMap::new();
      resource_templates.insert(
        "docs".to_string(),
        vec![McpResourceTemplate {
          name: "topic".to_string(),
          uri_template: "docs://topics/{name}".to_string(),
          title: Some("Topic".to_string()),
          description: Some("Topic page template".to_string()),
          mime_type: Some("text/markdown".to_string()),
          annotations: None,
        }],
      );

      let mut auth_statuses = HashMap::new();
      auth_statuses.insert("docs".to_string(), McpAuthStatus::OAuth);

      actor
        .send(SessionCommand::Broadcast {
          msg: ServerMessage::McpToolsList {
            session_id: session_id_for_task.clone(),
            tools,
            resources,
            resource_templates,
            auth_statuses,
          },
        })
        .await;
    });

    let response = list_mcp_tools_endpoint(Path(session_id.clone()), State(state)).await;

    task
      .await
      .expect("mcp tools endpoint helper task should complete");

    match response {
      Ok(Json(payload)) => {
        assert_eq!(payload.session_id, session_id);
        assert_eq!(payload.tools.len(), 1);
        assert_eq!(
          payload
            .tools
            .get("docs__search")
            .map(|tool| tool.name.as_str()),
          Some("search")
        );
        assert_eq!(
          payload
            .resources
            .get("docs")
            .and_then(|resources| resources.first())
            .map(|resource| resource.uri.as_str()),
          Some("docs://overview")
        );
        assert_eq!(
          payload
            .resource_templates
            .get("docs")
            .and_then(|templates| templates.first())
            .map(|template| template.uri_template.as_str()),
          Some("docs://topics/{name}")
        );
        assert_eq!(
          payload.auth_statuses.get("docs"),
          Some(&McpAuthStatus::OAuth)
        );
      }
      Err((status, body)) => panic!(
        "expected successful mcp tools response, got status {:?} with error {:?}",
        status, body.error
      ),
    }
  }

  #[tokio::test]
  async fn list_skills_endpoint_returns_conflict_when_connector_missing() {
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-api-test".to_string(),
    ));

    let response = list_skills_endpoint(
      Path(session_id),
      State(state),
      Query(SkillsQuery::default()),
    )
    .await;

    match response {
      Ok(_) => panic!("expected list_skills_endpoint to fail without connector"),
      Err((status, body)) => {
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body.code, "session_not_found");
      }
    }
  }

  #[tokio::test]
  async fn instructions_endpoint_returns_codex_developer_instructions() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_codex_session(
      &db_path,
      &session_id,
      "/tmp/orbitdock-instructions-test",
      Some("Stay focused and verify outputs"),
    );

    let response = get_session_instructions(Path(session_id.clone()), State(state))
      .await
      .expect("instructions endpoint should succeed");

    assert_eq!(response.0.session_id, session_id);
    assert_eq!(response.0.provider, Provider::Codex);
    assert_eq!(
      response.0.instructions.developer_instructions.as_deref(),
      Some("Stay focused and verify outputs")
    );
    assert!(response.0.instructions.claude_md.is_none());
  }
}
