use std::sync::Arc;

mod approvals;
mod capabilities;
mod codex_auth;
mod connector_actions;
mod errors;
mod files;
mod permissions;
mod review_comments;
mod router;
mod server_info;
mod server_meta;
mod session_actions;
mod session_lifecycle;
mod sessions;
mod shell;
mod worktrees;

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use orbitdock_protocol::{
    ApprovalHistoryItem, ImageInput, MentionInput, Message, SessionState, SessionSummary,
    SkillInput, UsageErrorInfo,
};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::infrastructure::persistence::{
    delete_approval, list_approvals, load_messages_for_session, PersistCommand,
};
use crate::runtime::session_queries::{
    load_conversation_bootstrap, load_conversation_page, load_full_session_state, SessionLoadError,
};
use crate::runtime::session_registry::SessionRegistry;

pub use approvals::{
    answer_question, approve_tool, delete_approval_endpoint, list_approvals_endpoint,
};
pub use capabilities::{
    apply_flag_settings, download_remote_skill, list_mcp_tools_endpoint,
    list_remote_skills_endpoint, list_skills_endpoint, mcp_authenticate, mcp_clear_auth,
    mcp_set_servers, refresh_mcp_servers, toggle_mcp_server,
};
pub use codex_auth::{codex_login_cancel, codex_login_start, codex_logout, read_codex_account};
pub(crate) use connector_actions::{
    dispatch_error_response, messaging_dispatch_error_response, session_not_found_error,
};
pub(crate) use errors::{revision_now, ApiErrorResponse, ApiResult};
pub use files::{
    browse_directory, git_init_endpoint, list_recent_projects, list_subagent_tools_endpoint,
};
pub use permissions::{add_permission_rule, get_permission_rules, remove_permission_rule};
pub use review_comments::{
    create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
    update_review_comment,
};
pub use router::build_router;
pub use server_info::{
    check_open_ai_key, set_client_primary_claim, set_open_ai_key, set_server_role,
};
pub use server_meta::{
    fetch_claude_usage, fetch_codex_usage, list_claude_models, list_codex_models,
};
pub use session_actions::{
    compact_context, get_session_image_attachment, interrupt_session, post_session_message,
    post_steer_turn, rewind_files, rollback_turns, stop_task, undo_last_turn,
    upload_session_image_attachment, AcceptedResponse,
};
pub use session_lifecycle::{
    create_session, end_session, fork_session, fork_session_to_existing_worktree,
    fork_session_to_worktree, rename_session, resume_session, takeover_session,
    update_session_config,
};
pub use sessions::{
    get_conversation_bootstrap, get_conversation_history, get_session, list_sessions,
    mark_session_read,
};
pub use shell::{cancel_shell_endpoint, execute_shell_endpoint};
pub use worktrees::{create_worktree, discover_worktrees, list_worktrees, remove_worktree};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::claude_session::ClaudeAction;
    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::SessionHandle;
    use crate::infrastructure::persistence::{flush_batch_for_test, PersistCommand};
    use axum::body::{to_bytes, Bytes};
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use orbitdock_protocol::{
        McpAuthStatus, McpResource, McpResourceTemplate, McpTool, Message, MessageType, Provider,
        RemoteSkillSummary, ReviewCommentStatus, ReviewCommentTag, ServerMessage, SkillErrorInfo,
        SkillMetadata, SkillScope, SkillsListEntry,
    };
    use serde_json::json;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use tokio::sync::mpsc;

    use crate::runtime::session_commands::SessionCommand;
    use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};
    use crate::transport::http::review_comments::{
        CreateReviewCommentRequest, ReviewCommentsQuery, UpdateReviewCommentRequest,
    };
    use crate::transport::http::session_actions::{
        SendSessionMessageRequest, SteerTurnRequest, UploadImageAttachmentQuery,
    };

    fn new_test_state(is_primary: bool) -> Arc<SessionRegistry> {
        new_test_session_registry(is_primary)
    }

    fn ensure_test_db() -> PathBuf {
        ensure_server_test_data_dir();
        let db_path = crate::infrastructure::paths::db_path();
        let mut conn = rusqlite::Connection::open(&db_path).expect("open test db");
        crate::infrastructure::migration_runner::run_migrations(&mut conn)
            .expect("run test migrations");
        db_path
    }

    fn new_persist_test_state(
        is_primary: bool,
    ) -> (
        Arc<SessionRegistry>,
        mpsc::Receiver<PersistCommand>,
        PathBuf,
    ) {
        let db_path = ensure_test_db();
        let (persist_tx, persist_rx) = mpsc::channel(32);
        (
            Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary)),
            persist_rx,
            db_path,
        )
    }

    async fn upload_test_attachment(
        state: Arc<SessionRegistry>,
        session_id: &str,
        bytes: &'static [u8],
    ) -> ImageInput {
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("image/png"));
        let Json(response) = upload_session_image_attachment(
            Path(session_id.to_string()),
            State(state),
            Query(UploadImageAttachmentQuery {
                display_name: Some("test.png".to_string()),
                pixel_width: Some(320),
                pixel_height: Some(200),
            }),
            headers,
            Bytes::from_static(bytes),
        )
        .await
        .expect("upload attachment should succeed");
        response.image
    }

    #[tokio::test]
    async fn list_sessions_returns_runtime_summaries() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        state.add_session(handle);

        let Json(response) = list_sessions(State(state)).await;
        assert!(response
            .sessions
            .iter()
            .any(|session| session.id == session_id));
    }

    #[tokio::test]
    async fn get_session_returns_full_untruncated_message_content() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        let large_content = "x".repeat(40_000);
        handle.add_message(Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            sequence: None,
            message_type: MessageType::Assistant,
            content: large_content.clone(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        });
        state.add_session(handle);

        let response = get_session(Path(session_id), State(state)).await;
        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session.messages.len(), 1);
                assert_eq!(payload.session.messages[0].content, large_content);
                assert!(!payload.session.messages[0].content.contains("[truncated]"));
            }
            Err((status, body)) => panic!(
                "expected successful session response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn browse_directory_hides_dotfiles_and_returns_directories_first() {
        let root = std::env::temp_dir().join(format!(
            "orbitdock-api-browse-{}",
            orbitdock_protocol::new_id()
        ));
        std::fs::create_dir_all(root.join("z-dir")).expect("create visible directory");
        std::fs::write(root.join("a-file.txt"), "hello").expect("create visible file");
        std::fs::write(root.join(".hidden.txt"), "secret").expect("create hidden file");

        let Json(response) = browse_directory(Query(files::BrowseDirectoryQuery {
            path: Some(root.to_string_lossy().to_string()),
        }))
        .await;

        std::fs::remove_dir_all(&root).expect("remove browse test directory");

        assert_eq!(response.path, root.to_string_lossy().to_string());
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "z-dir" && entry.is_dir));
        assert!(response
            .entries
            .iter()
            .any(|entry| entry.name == "a-file.txt" && !entry.is_dir));
        assert!(!response
            .entries
            .iter()
            .any(|entry| entry.name.starts_with('.')));

        let first = response
            .entries
            .first()
            .expect("expected at least one listing entry");
        assert!(
            first.is_dir,
            "expected directories to be sorted before files"
        );
    }

    #[tokio::test]
    async fn usage_endpoints_return_control_plane_error_when_secondary() {
        let state = new_test_state(false);

        let Json(codex) = fetch_codex_usage(State(state.clone())).await;
        assert!(codex.usage.is_none());
        assert_eq!(
            codex.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );

        let Json(claude) = fetch_claude_usage(State(state)).await;
        assert!(claude.usage.is_none());
        assert_eq!(
            claude.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );
    }

    #[tokio::test]
    async fn review_comments_endpoint_returns_empty_when_none_exist() {
        ensure_server_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());

        let Json(response) = list_review_comments_endpoint(
            Path(session_id.clone()),
            Query(ReviewCommentsQuery::default()),
        )
        .await;

        assert_eq!(response.session_id, session_id);
        assert!(response.comments.is_empty());
    }

    #[tokio::test]
    async fn review_comment_mutations_return_authoritative_payloads_and_persist() {
        let (state, mut persist_rx, db_path) = new_persist_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-review-contract".to_string(),
        ));
        flush_batch_for_test(
            &db_path,
            vec![PersistCommand::SessionCreate {
                id: session_id.clone(),
                provider: Provider::Codex,
                project_path: "/tmp/orbitdock-review-contract".to_string(),
                project_name: Some("orbitdock-review-contract".to_string()),
                branch: Some("main".to_string()),
                model: Some("gpt-5".to_string()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            }],
        )
        .expect("persist session row for review comment contract test");

        let Json(created) = create_review_comment_endpoint(
            Path(session_id.clone()),
            State(state.clone()),
            Json(CreateReviewCommentRequest {
                turn_id: Some("turn-1".to_string()),
                file_path: "src/main.rs".to_string(),
                line_start: 12,
                line_end: Some(14),
                body: "Initial review comment".to_string(),
                tag: Some(ReviewCommentTag::Clarity),
            }),
        )
        .await
        .expect("create review comment should succeed");

        assert_eq!(created.session_id, session_id);
        assert!(created.review_revision > 0);
        assert!(!created.deleted);
        let created_comment = created
            .comment
            .clone()
            .expect("create response should include comment");
        assert_eq!(created_comment.body, "Initial review comment");
        assert_eq!(created_comment.tag, Some(ReviewCommentTag::Clarity));

        let create_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("create should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentCreate { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![create_cmd]).expect("flush created comment");

        let stored_after_create =
            crate::infrastructure::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load created comment")
                .expect("created comment should exist");
        assert_eq!(stored_after_create.body, "Initial review comment");

        let Json(updated) = update_review_comment(
            Path(created.comment_id.clone()),
            State(state.clone()),
            Json(UpdateReviewCommentRequest {
                body: Some("Updated review comment".to_string()),
                tag: Some(ReviewCommentTag::Risk),
                status: Some(ReviewCommentStatus::Resolved),
            }),
        )
        .await
        .expect("update review comment should succeed");

        assert_eq!(updated.comment_id, created.comment_id);
        assert_eq!(updated.session_id, session_id);
        assert!(updated.review_revision > 0);
        assert!(!updated.deleted);
        let updated_comment = updated
            .comment
            .clone()
            .expect("update response should include comment");
        assert_eq!(updated_comment.body, "Updated review comment");
        assert_eq!(updated_comment.tag, Some(ReviewCommentTag::Risk));
        assert_eq!(updated_comment.status, ReviewCommentStatus::Resolved);

        let update_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("update should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentUpdate { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![update_cmd]).expect("flush updated comment");

        let stored_after_update =
            crate::infrastructure::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load updated comment")
                .expect("updated comment should exist");
        assert_eq!(stored_after_update.body, "Updated review comment");
        assert_eq!(stored_after_update.tag, Some(ReviewCommentTag::Risk));
        assert_eq!(stored_after_update.status, ReviewCommentStatus::Resolved);

        let Json(deleted) =
            delete_review_comment_by_id(Path(created.comment_id.clone()), State(state.clone()))
                .await
                .expect("delete review comment should succeed");

        assert_eq!(deleted.comment_id, created.comment_id);
        assert_eq!(deleted.session_id, session_id);
        assert!(deleted.review_revision > 0);
        assert!(deleted.deleted);
        assert!(deleted.comment.is_none());

        let delete_cmd = loop {
            let command = persist_rx
                .recv()
                .await
                .expect("delete should enqueue persistence command");
            if matches!(command, PersistCommand::ReviewCommentDelete { .. }) {
                break command;
            }
        };
        flush_batch_for_test(&db_path, vec![delete_cmd]).expect("flush deleted comment");

        let stored_after_delete =
            crate::infrastructure::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load deleted comment");
        assert!(stored_after_delete.is_none());
    }

    #[tokio::test]
    async fn subagent_tools_endpoint_returns_empty_when_subagent_missing() {
        ensure_server_test_data_dir();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let subagent_id = format!("sub-{}", orbitdock_protocol::new_id());

        let Json(response) =
            list_subagent_tools_endpoint(Path((session_id.clone(), subagent_id.clone()))).await;

        assert_eq!(response.session_id, session_id);
        assert_eq!(response.subagent_id, subagent_id);
        assert!(response.tools.is_empty());
    }

    #[tokio::test]
    async fn claude_models_endpoint_returns_cached_shape() {
        ensure_server_test_data_dir();
        let Json(response) = list_claude_models().await;
        assert!(response
            .models
            .iter()
            .all(|model| !model.value.trim().is_empty()));
    }

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
            Query(capabilities::SkillsQuery {
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
            Query(capabilities::SkillsQuery::default()),
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
    async fn image_attachment_upload_and_fetch_round_trip() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));

        let uploaded = upload_test_attachment(state, &session_id, b"png-bytes").await;
        assert_eq!(uploaded.input_type, "attachment");
        assert_eq!(uploaded.mime_type.as_deref(), Some("image/png"));
        assert_eq!(uploaded.byte_count, Some(9));
        assert_eq!(uploaded.pixel_width, Some(320));
        assert_eq!(uploaded.pixel_height, Some(200));

        let response = get_session_image_attachment(Path((session_id, uploaded.value.clone())))
            .await
            .expect("attachment fetch should succeed")
            .into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some("image/png")
        );

        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("attachment body should decode");
        assert_eq!(body.as_ref(), b"png-bytes");
    }

    #[tokio::test]
    async fn post_session_message_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let uploaded =
            upload_test_attachment(state.clone(), &session_id, b"send-message-image").await;

        let _ = post_session_message(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SendSessionMessageRequest {
                content: "look at this".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post session message should succeed");

        let action = action_rx
            .recv()
            .await
            .expect("message endpoint should dispatch codex action");
        match action {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted user message");
        assert_eq!(persisted.message_type, MessageType::User);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }

    #[tokio::test]
    async fn post_steer_turn_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_claude_action_tx(&session_id, action_tx);

        let uploaded = upload_test_attachment(state.clone(), &session_id, b"steer-image").await;

        let _ = post_steer_turn(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SteerTurnRequest {
                content: "consider this image".to_string(),
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post steer should succeed");

        let action = action_rx
            .recv()
            .await
            .expect("steer endpoint should dispatch claude action");
        match action {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted steer message");
        assert_eq!(persisted.message_type, MessageType::Steer);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }
}
