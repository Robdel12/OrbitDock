use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;

use axum::{extract::Path, extract::Query, extract::State, http::StatusCode, Json};
use codex_app_server_protocol::{
  PluginAuthPolicy, PluginInstallPolicy, PluginListResponse, PluginMarketplaceEntry, PluginSource,
  PluginSummary,
};
use codex_utils_absolute_path::AbsolutePathBuf;
use orbitdock_protocol::{
  McpAuthStatus, McpResource, McpResourceTemplate, McpTool, Provider, ServerMessage,
  SkillErrorInfo, SkillMetadata, SkillScope, SkillsListEntry,
};
use serde_json::json;
use tempfile::NamedTempFile;
use tokio::sync::mpsc;

use crate::{
  connectors::codex_session::CodexAction,
  domain::sessions::session::SessionHandle,
  infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
  runtime::session_commands::SessionCommand,
  transport::http::test_support::{new_persist_test_state, new_test_state},
};

use super::{
  get_session_instructions, install_plugin, list_mcp_tools_endpoint, list_plugins_endpoint,
  list_skills_endpoint, uninstall_plugin, PluginsQuery, SkillsQuery,
};

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
        provider: orbitdock_protocol::Provider::Codex,
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

fn persist_claude_session(
  db_path: &PathBuf,
  session_id: &str,
  project_path: &str,
  transcript_path: &str,
) {
  flush_batch_for_test(
    db_path,
    vec![PersistCommand::ClaudeSessionUpsert {
      id: session_id.to_string(),
      project_path: project_path.to_string(),
      project_name: Some("orbitdock-api-test".to_string()),
      branch: Some("main".to_string()),
      model: Some("claude-opus-4-1".to_string()),
      context_label: None,
      transcript_path: Some(transcript_path.to_string()),
      source: Some("hook".to_string()),
      agent_type: None,
      permission_mode: Some("acceptEdits".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      forked_from_session_id: None,
      repository_root: Some(project_path.to_string()),
      is_worktree: false,
      git_sha: Some("abc123".to_string()),
    }],
  )
  .expect("persist claude session fixture");
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

  task.await.expect("skills helper task should complete");

  match response {
    Ok(Json(payload)) => {
      assert_eq!(payload.session_id, session_id);
      assert_eq!(payload.skills.len(), 1);
      assert!(payload.claude_skill_names.is_empty());
      assert_eq!(payload.skills[0].cwd, "/tmp/orbitdock-api-test");
      assert_eq!(payload.skills[0].skills.len(), 1);
      assert_eq!(payload.skills[0].skills[0].name, "deploy");
      assert_eq!(payload.errors.len(), 1);
    }
    Err((status, body)) => panic!(
      "expected successful skills response, got status {:?} with error {:?}",
      status, body.error
    ),
  }
}

#[tokio::test]
async fn list_skills_endpoint_returns_claude_skill_names_from_transcript() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  let mut transcript = NamedTempFile::new().expect("claude transcript temp file");
  writeln!(
    transcript,
    "{}",
    serde_json::json!({
      "type": "system",
      "subtype": "init",
      "skills": ["testing-philosophy", "api-transport-architecture", "testing-philosophy"],
      "slash_commands": [],
      "tools": [],
    })
  )
  .expect("write transcript init event");
  persist_claude_session(
    &db_path,
    &session_id,
    "/tmp/orbitdock-api-test",
    transcript.path().to_str().expect("transcript path"),
  );

  let response = list_skills_endpoint(
    Path(session_id.clone()),
    State(state),
    Query(SkillsQuery::default()),
  )
  .await;

  match response {
    Ok(Json(payload)) => {
      assert_eq!(payload.session_id, session_id);
      assert!(payload.skills.is_empty());
      assert_eq!(
        payload.claude_skill_names,
        vec![
          "api-transport-architecture".to_string(),
          "testing-philosophy".to_string(),
        ]
      );
      assert!(payload.errors.is_empty());
    }
    Err((status, body)) => panic!(
      "expected successful Claude skills response, got status {:?} with error {:?}",
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

  task.await.expect("plugins helper task should complete");

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
        let _ = reply_tx.send(Ok(codex_app_server_protocol::PluginInstallResponse {
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
    Json(codex_app_server_protocol::PluginInstallParams {
      marketplace_path: AbsolutePathBuf::try_from(PathBuf::from(
        "/tmp/orbitdock-api-test/.codex/plugins/marketplace.toml",
      ))
      .expect("absolute marketplace path"),
      plugin_name: "deploy-checks".to_string(),
      force_remote_sync: true,
    }),
  )
  .await;

  task.await.expect("install helper task should complete");

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
        let _ = reply_tx.send(Ok(codex_app_server_protocol::PluginUninstallResponse {}));
      }
      other => panic!("expected UninstallPlugin action, got {:?}", other),
    }
  });

  let response = uninstall_plugin(
    Path(session_id),
    State(state),
    Json(codex_app_server_protocol::PluginUninstallParams {
      plugin_id: "marketplace/deploy-checks".to_string(),
      force_remote_sync: true,
    }),
  )
  .await;

  task.await.expect("uninstall helper task should complete");

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

  task.await.expect("mcp tools helper task should complete");

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
      assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
      assert_eq!(body.code, "connector_unavailable");
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
