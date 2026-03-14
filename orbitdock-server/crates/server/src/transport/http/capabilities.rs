use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_protocol::{
    McpAuthStatus, McpResource, McpResourceTemplate, McpTool, RemoteSkillSummary, SkillErrorInfo,
    SkillsListEntry,
};
use serde::{Deserialize, Serialize};

use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_queries::load_full_session_state;
use crate::runtime::session_registry::SessionRegistry;

use super::connector_actions::{
    dispatch_claude_action, dispatch_codex_action, subscribe_session_events,
    wait_for_codex_skills_event, wait_for_mcp_tools_event, wait_for_remote_skills_event,
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
pub struct RemoteSkillsResponse {
    pub session_id: String,
    pub skills: Vec<RemoteSkillSummary>,
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
pub struct DownloadRemoteSkillRequest {
    pub hazelnut_id: String,
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
    let session = load_full_session_state(&state, &session_id, false)
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
                system_prompt: None,
                developer_instructions: session.developer_instructions.clone(),
            }
        }
        orbitdock_protocol::Provider::Codex => SessionInstructionsPayload {
            claude_md: None,
            system_prompt: None,
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

pub async fn list_remote_skills_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<RemoteSkillsResponse> {
    let mut rx = subscribe_session_events(&state, &session_id).await?;

    dispatch_codex_action(&state, &session_id, CodexAction::ListRemoteSkills).await?;

    let skills = wait_for_remote_skills_event(&session_id, &mut rx).await?;
    Ok(Json(RemoteSkillsResponse { session_id, skills }))
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

pub async fn download_remote_skill(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<DownloadRemoteSkillRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    dispatch_codex_action(
        &state,
        &session_id,
        CodexAction::DownloadRemoteSkill {
            hazelnut_id: body.hazelnut_id,
        },
    )
    .await?;

    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
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
    use orbitdock_protocol::{
        McpAuthStatus, McpResource, McpResourceTemplate, McpTool, Provider, RemoteSkillSummary,
        ServerMessage, SkillErrorInfo, SkillMetadata, SkillScope, SkillsListEntry,
    };
    use serde_json::json;
    use std::collections::HashMap;
    use tokio::sync::mpsc;

    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::{SessionConfigPatch, SessionHandle};
    use crate::runtime::session_commands::SessionCommand;
    use crate::transport::http::test_support::new_test_state;

    #[tokio::test]
    async fn list_skills_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
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

        task.await
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
    async fn list_remote_skills_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let actor = state
            .get_session(&session_id)
            .expect("session should exist for remote skills endpoint test");
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let session_id_for_task = session_id.clone();
        let task = tokio::spawn(async move {
            let action = action_rx
                .recv()
                .await
                .expect("remote skills endpoint should dispatch codex action");
            match action {
                CodexAction::ListRemoteSkills => {}
                other => panic!("expected ListRemoteSkills action, got {:?}", other),
            }

            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::RemoteSkillsList {
                        session_id: session_id_for_task.clone(),
                        skills: vec![RemoteSkillSummary {
                            id: "remote-1".to_string(),
                            name: "deploy-checks".to_string(),
                            description: "Shared deploy readiness checks".to_string(),
                        }],
                    },
                })
                .await;
        });

        let response = list_remote_skills_endpoint(Path(session_id.clone()), State(state)).await;

        task.await
            .expect("remote skills endpoint helper task should complete");

        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session_id, session_id);
                assert_eq!(payload.skills.len(), 1);
                assert_eq!(payload.skills[0].id, "remote-1");
                assert_eq!(payload.skills[0].name, "deploy-checks");
            }
            Err((status, body)) => panic!(
                "expected successful remote skills response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn list_mcp_tools_endpoint_dispatches_action_and_returns_payload() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
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

        task.await
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
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
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
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-instructions-test".to_string(),
        );
        handle.set_config(SessionConfigPatch {
            developer_instructions: Some("Stay focused and verify outputs".to_string()),
            ..Default::default()
        });
        state.add_session(handle);

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
