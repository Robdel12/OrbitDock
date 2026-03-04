use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_connector_codex::discover_models;
use orbitdock_protocol::{
    ApprovalHistoryItem, ClaudeIntegrationMode, ClaudeModelOption, ClaudeUsageSnapshot,
    CodexAccountStatus, CodexIntegrationMode, CodexModelOption, CodexUsageSnapshot, DirectoryEntry,
    McpAuthStatus, McpResource, McpResourceTemplate, McpTool, Provider, RecentProject,
    RemoteSkillSummary, ReviewComment, ReviewCommentStatus, ReviewCommentTag, ServerMessage,
    SessionState, SessionStatus, SessionSummary, SkillErrorInfo, SkillsListEntry, SubagentTool,
    TokenUsage, TurnDiff, UsageErrorInfo, WorkStatus, WorktreeOrigin, WorktreeStatus,
    WorktreeSummary,
};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, oneshot};
use tracing::{error, info, warn};

use crate::codex_session::CodexAction;
use crate::persistence::{
    delete_approval, list_approvals, list_review_comments as load_review_comments,
    load_cached_claude_models, load_messages_for_session, load_messages_from_transcript_path,
    load_session_by_id, load_subagent_transcript_path, load_subagents_for_session, PersistCommand,
    RestoredSession,
};
use crate::session_actor::SessionActorHandle;
use crate::session_command::{SessionCommand, SubscribeResult};
use crate::state::SessionRegistry;
use orbitdock_connector_claude::session::ClaudeAction;

#[derive(Debug, Serialize)]
pub struct SessionsResponse {
    pub sessions: Vec<SessionSummary>,
}

#[derive(Debug, Serialize)]
pub struct SessionResponse {
    pub session: SessionState,
}

#[derive(Debug, Serialize)]
pub struct ApprovalsResponse {
    pub session_id: Option<String>,
    pub approvals: Vec<ApprovalHistoryItem>,
}

#[derive(Debug, Serialize)]
pub struct DeleteApprovalResponse {
    pub approval_id: i64,
    pub deleted: bool,
}

#[derive(Debug, Serialize)]
pub struct OpenAiKeyStatusResponse {
    pub configured: bool,
}

#[derive(Debug, Serialize)]
pub struct CodexUsageResponse {
    pub usage: Option<CodexUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeUsageResponse {
    pub usage: Option<ClaudeUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct DirectoryListingResponse {
    pub path: String,
    pub entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Serialize)]
pub struct RecentProjectsResponse {
    pub projects: Vec<RecentProject>,
}

#[derive(Debug, Serialize)]
pub struct CodexModelsResponse {
    pub models: Vec<CodexModelOption>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeModelsResponse {
    pub models: Vec<ClaudeModelOption>,
}

#[derive(Debug, Serialize)]
pub struct CodexAccountResponse {
    pub status: CodexAccountStatus,
}

#[derive(Debug, Serialize)]
pub struct ReviewCommentsResponse {
    pub session_id: String,
    pub comments: Vec<ReviewComment>,
}

#[derive(Debug, Serialize)]
pub struct SubagentToolsResponse {
    pub session_id: String,
    pub subagent_id: String,
    pub tools: Vec<SubagentTool>,
}

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

// ── Worktree types ────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct WorktreesListResponse {
    pub repo_root: Option<String>,
    pub worktrees: Vec<WorktreeSummary>,
}

#[derive(Debug, Serialize)]
pub struct WorktreeCreatedResponse {
    pub worktree: WorktreeSummary,
}

#[derive(Debug, Deserialize, Default)]
pub struct WorktreesQuery {
    #[serde(default)]
    pub repo_root: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateWorktreeRequest {
    pub repo_path: String,
    pub branch_name: String,
    #[serde(default)]
    pub base_branch: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DiscoverWorktreesRequest {
    pub repo_path: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct RemoveWorktreeQuery {
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub delete_branch: bool,
    #[serde(default)]
    pub delete_remote_branch: bool,
    #[serde(default)]
    pub archive_only: bool,
}

#[derive(Debug, Serialize)]
pub struct WorktreeRemovedResponse {
    pub worktree_id: String,
    pub ok: bool,
}

#[derive(Debug, Deserialize)]
pub struct GitInitRequest {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct GitInitResponse {
    ok: bool,
}

// ── Review comment mutation types ─────────────────────────────

#[derive(Debug, Deserialize)]
pub struct CreateReviewCommentRequest {
    pub turn_id: Option<String>,
    pub file_path: String,
    pub line_start: u32,
    pub line_end: Option<u32>,
    pub body: String,
    #[serde(default)]
    pub tag: Option<ReviewCommentTag>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateReviewCommentRequest {
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub tag: Option<ReviewCommentTag>,
    #[serde(default)]
    pub status: Option<ReviewCommentStatus>,
}

#[derive(Debug, Serialize)]
pub struct ReviewCommentMutationResponse {
    pub comment_id: String,
    pub ok: bool,
}

// ── Config mutation types ─────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct SetOpenAiKeyRequest {
    pub key: String,
}

#[derive(Debug, Deserialize)]
pub struct SetServerRoleRequest {
    pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct ServerRoleResponse {
    pub is_primary: bool,
}

// ── Codex auth types ──────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct CodexLoginStartedResponse {
    pub login_id: String,
    pub auth_url: String,
}

#[derive(Debug, Deserialize)]
pub struct CodexLoginCancelRequest {
    pub login_id: String,
}

#[derive(Debug, Serialize)]
pub struct CodexLoginCanceledResponse {
    pub login_id: String,
    pub status: orbitdock_protocol::CodexLoginCancelStatus,
}

#[derive(Debug, Serialize)]
pub struct CodexLogoutResponse {
    pub status: CodexAccountStatus,
}

// ── Async action types ────────────────────────────────────────

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

#[derive(Debug, Serialize)]
pub struct AcceptedResponse {
    pub accepted: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct ApprovalsQuery {
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize, Default)]
pub struct BrowseDirectoryQuery {
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CodexAccountQuery {
    #[serde(default)]
    pub refresh_token: Option<bool>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ReviewCommentsQuery {
    #[serde(default)]
    pub turn_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SkillsQuery {
    #[serde(default)]
    pub cwd: Vec<String>,
    #[serde(default)]
    pub force_reload: Option<bool>,
}

#[derive(Debug, Serialize)]
pub(crate) struct ApiErrorResponse {
    code: &'static str,
    error: String,
}

#[derive(Debug)]
enum SessionLoadError {
    NotFound,
    Db(String),
    Runtime(String),
}

#[derive(Debug)]
enum CodexActionError {
    SessionNotFound,
    ConnectorNotAvailable,
    ChannelClosed,
    Timeout,
}

type ApiResult<T> = Result<Json<T>, (StatusCode, Json<ApiErrorResponse>)>;
type ApiInnerResult<T> = Result<T, (StatusCode, Json<ApiErrorResponse>)>;
const CODEX_ACTION_WAIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);

pub async fn list_sessions(State(state): State<Arc<SessionRegistry>>) -> Json<SessionsResponse> {
    Json(SessionsResponse {
        sessions: state.get_session_summaries(),
    })
}

pub async fn get_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionResponse> {
    match load_session_state(&state, &session_id).await {
        Ok(session) => Ok(Json(SessionResponse { session })),
        Err(SessionLoadError::NotFound) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {} not found", session_id),
            }),
        )),
        Err(SessionLoadError::Db(err)) => {
            error!(
                component = "api",
                event = "api.get_session.db_error",
                session_id = %session_id,
                error = %err,
                "Failed to load session from database"
            );
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "db_error",
                    error: err,
                }),
            ))
        }
        Err(SessionLoadError::Runtime(err)) => {
            error!(
                component = "api",
                event = "api.get_session.runtime_error",
                session_id = %session_id,
                error = %err,
                "Failed to load runtime session state"
            );
            Err((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ApiErrorResponse {
                    code: "runtime_error",
                    error: err,
                }),
            ))
        }
    }
}

pub async fn list_approvals_endpoint(
    Query(query): Query<ApprovalsQuery>,
) -> ApiResult<ApprovalsResponse> {
    match list_approvals(query.session_id.clone(), query.limit).await {
        Ok(approvals) => Ok(Json(ApprovalsResponse {
            session_id: query.session_id,
            approvals,
        })),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "approval_list_failed",
                error: format!("Failed to list approvals: {err}"),
            }),
        )),
    }
}

pub async fn delete_approval_endpoint(
    Path(approval_id): Path<i64>,
) -> ApiResult<DeleteApprovalResponse> {
    match delete_approval(approval_id).await {
        Ok(true) => Ok(Json(DeleteApprovalResponse {
            approval_id,
            deleted: true,
        })),
        Ok(false) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Approval {} not found", approval_id),
            }),
        )),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "approval_delete_failed",
                error: format!("Failed to delete approval {}: {}", approval_id, err),
            }),
        )),
    }
}

pub async fn check_open_ai_key() -> Json<OpenAiKeyStatusResponse> {
    Json(OpenAiKeyStatusResponse {
        configured: crate::ai_naming::resolve_api_key().is_some(),
    })
}

pub async fn fetch_codex_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<CodexUsageResponse> {
    if !state.is_primary() {
        return Json(CodexUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::usage_probe::fetch_codex_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(CodexUsageResponse { usage, error_info })
}

pub async fn fetch_claude_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<ClaudeUsageResponse> {
    if !state.is_primary() {
        return Json(ClaudeUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::usage_probe::fetch_claude_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(ClaudeUsageResponse { usage, error_info })
}

pub async fn browse_directory(
    Query(query): Query<BrowseDirectoryQuery>,
) -> Json<DirectoryListingResponse> {
    let target = resolve_browse_target(query.path.as_deref());

    let entries = match read_directory_entries(&target) {
        Ok(entries) => entries,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.browse_directory.read_error",
                path = %target.display(),
                error = %err,
                "Cannot read directory"
            );
            vec![]
        }
    };

    Json(DirectoryListingResponse {
        path: target.to_string_lossy().to_string(),
        entries,
    })
}

pub async fn list_recent_projects(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<RecentProjectsResponse> {
    Json(RecentProjectsResponse {
        projects: state.list_recent_projects().await,
    })
}

pub async fn list_codex_models() -> ApiResult<CodexModelsResponse> {
    match discover_models().await {
        Ok(models) => Ok(Json(CodexModelsResponse { models })),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "model_list_failed",
                error: format!("Failed to list models: {err}"),
            }),
        )),
    }
}

pub async fn list_claude_models() -> Json<ClaudeModelsResponse> {
    Json(ClaudeModelsResponse {
        models: load_cached_claude_models(),
    })
}

pub async fn read_codex_account(
    State(state): State<Arc<SessionRegistry>>,
    Query(query): Query<CodexAccountQuery>,
) -> ApiResult<CodexAccountResponse> {
    let auth = state.codex_auth();
    match auth
        .read_account(query.refresh_token.unwrap_or(false))
        .await
    {
        Ok(status) => Ok(Json(CodexAccountResponse { status })),
        Err(err) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "codex_auth_error",
                error: err,
            }),
        )),
    }
}

pub async fn list_review_comments_endpoint(
    Path(session_id): Path<String>,
    Query(query): Query<ReviewCommentsQuery>,
) -> Json<ReviewCommentsResponse> {
    let comments = match load_review_comments(&session_id, query.turn_id.as_deref()).await {
        Ok(comments) => comments,
        Err(err) => {
            warn!(
                component = "api",
                event = "api.review_comments.list_error",
                session_id = %session_id,
                error = %err,
                "Failed to list review comments"
            );
            vec![]
        }
    };

    Json(ReviewCommentsResponse {
        session_id,
        comments,
    })
}

pub async fn list_subagent_tools_endpoint(
    Path((session_id, subagent_id)): Path<(String, String)>,
) -> Json<SubagentToolsResponse> {
    let tools = load_subagent_tools(&subagent_id).await;
    Json(SubagentToolsResponse {
        session_id,
        subagent_id,
        tools,
    })
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

    // Try Codex first, fall back to Claude
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

// ── Group A: Pure operations ──────────────────────────────────

pub async fn set_open_ai_key(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SetOpenAiKeyRequest>,
) -> ApiResult<OpenAiKeyStatusResponse> {
    info!(
        component = "api",
        event = "api.openai_key.set",
        "OpenAI API key set via REST"
    );

    let _ = state
        .persist()
        .send(PersistCommand::SetConfig {
            key: "openai_api_key".into(),
            value: body.key,
        })
        .await;

    Ok(Json(OpenAiKeyStatusResponse { configured: true }))
}

pub async fn list_worktrees(
    Query(query): Query<WorktreesQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorktreesListResponse> {
    let worktrees = if let Some(ref root) = query.repo_root {
        let db_rows = crate::persistence::load_worktrees_by_repo(state.db_path(), root);

        if db_rows.is_empty() {
            // Fallback: discover from git for repos not yet tracked
            match crate::git::discover_worktrees(root).await {
                Ok(discovered) => discovered
                    .into_iter()
                    .map(|w| WorktreeSummary {
                        id: orbitdock_protocol::new_id(),
                        repo_root: root.clone(),
                        worktree_path: w.path,
                        branch: w.branch.unwrap_or_else(|| "HEAD".to_string()),
                        base_branch: None,
                        status: WorktreeStatus::Active,
                        active_session_count: 0,
                        total_session_count: 0,
                        created_at: String::new(),
                        last_session_ended_at: None,
                        disk_present: true,
                        auto_prune: true,
                        custom_name: None,
                        created_by: WorktreeOrigin::Discovered,
                    })
                    .collect(),
                Err(_) => Vec::new(),
            }
        } else {
            // Enrich DB rows with disk presence check
            let mut summaries = Vec::with_capacity(db_rows.len());
            for row in db_rows {
                let disk_present = crate::git::worktree_exists_on_disk(&row.worktree_path).await;
                summaries.push(WorktreeSummary {
                    id: row.id,
                    repo_root: row.repo_root,
                    worktree_path: row.worktree_path,
                    branch: row.branch,
                    base_branch: row.base_branch,
                    status: WorktreeStatus::from_str_opt(&row.status)
                        .unwrap_or(WorktreeStatus::Active),
                    active_session_count: 0,
                    total_session_count: 0,
                    created_at: String::new(),
                    last_session_ended_at: None,
                    disk_present,
                    auto_prune: true,
                    custom_name: None,
                    created_by: WorktreeOrigin::User,
                });
            }
            summaries
        }
    } else {
        Vec::new()
    };

    Ok(Json(WorktreesListResponse {
        repo_root: query.repo_root,
        worktrees,
    }))
}

pub async fn discover_worktrees(
    Json(body): Json<DiscoverWorktreesRequest>,
) -> ApiResult<WorktreesListResponse> {
    let worktrees = match crate::git::discover_worktrees(&body.repo_path).await {
        Ok(discovered) => discovered
            .into_iter()
            .map(|w| WorktreeSummary {
                id: orbitdock_protocol::new_id(),
                repo_root: body.repo_path.clone(),
                worktree_path: w.path,
                branch: w.branch.unwrap_or_else(|| "HEAD".to_string()),
                base_branch: None,
                status: WorktreeStatus::Active,
                active_session_count: 0,
                total_session_count: 0,
                created_at: String::new(),
                last_session_ended_at: None,
                disk_present: true,
                auto_prune: true,
                custom_name: None,
                created_by: WorktreeOrigin::Discovered,
            })
            .collect(),
        Err(_) => Vec::new(),
    };

    Ok(Json(WorktreesListResponse {
        repo_root: Some(body.repo_path),
        worktrees,
    }))
}

pub async fn create_worktree(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CreateWorktreeRequest>,
) -> ApiResult<WorktreeCreatedResponse> {
    match crate::worktree_service::create_tracked_worktree(
        &state,
        &body.repo_path,
        &body.branch_name,
        body.base_branch.as_deref(),
        WorktreeOrigin::User,
    )
    .await
    {
        Ok(summary) => Ok(Json(WorktreeCreatedResponse { worktree: summary })),
        Err(e) => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "create_failed",
                error: e,
            }),
        )),
    }
}

pub async fn remove_worktree(
    Path(worktree_id): Path<String>,
    Query(query): Query<RemoveWorktreeQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<WorktreeRemovedResponse> {
    let row = crate::persistence::load_worktree_by_id(state.db_path(), &worktree_id).ok_or_else(
        || {
            (
                StatusCode::NOT_FOUND,
                Json(ApiErrorResponse {
                    code: "not_found",
                    error: format!("worktree {worktree_id} not found"),
                }),
            )
        },
    )?;

    if !query.archive_only {
        if let Err(e) =
            crate::git::remove_worktree(&row.repo_root, &row.worktree_path, query.force).await
        {
            if !query.force {
                warn!(
                    component = "worktree",
                    event = "worktree.remove.failed",
                    worktree_id = %worktree_id,
                    repo_root = %row.repo_root,
                    worktree_path = %row.worktree_path,
                    error = %e,
                    "Failed to remove worktree"
                );
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiErrorResponse {
                        code: "remove_failed",
                        error: e,
                    }),
                ));
            }
            // Force mode: log and continue even if git removal fails
            warn!(
                component = "worktree",
                event = "worktree.remove.force_fallthrough",
                worktree_id = %worktree_id,
                error = %e,
                "git worktree remove failed in force mode, continuing"
            );
        }
    }

    if !query.archive_only && query.delete_branch {
        if let Err(e) = crate::git::delete_branch(&row.repo_root, &row.branch).await {
            warn!(
                component = "worktree",
                event = "worktree.delete_branch.failed",
                worktree_id = %worktree_id,
                repo_root = %row.repo_root,
                branch = %row.branch,
                error = %e,
                "Failed to delete branch after worktree removal"
            );
        }
    }

    if !query.archive_only && query.delete_remote_branch {
        if let Err(e) = crate::git::delete_remote_branch(&row.repo_root, &row.branch).await {
            warn!(
                component = "worktree",
                event = "worktree.delete_remote_branch.failed",
                worktree_id = %worktree_id,
                repo_root = %row.repo_root,
                branch = %row.branch,
                error = %e,
                "Failed to delete remote branch after worktree removal"
            );
        }
    }

    let _ = state
        .persist()
        .send(PersistCommand::WorktreeUpdateStatus {
            id: worktree_id.clone(),
            status: "removed".into(),
            last_session_ended_at: None,
        })
        .await;

    state.broadcast_to_list(ServerMessage::WorktreeRemoved {
        request_id: String::new(),
        worktree_id: worktree_id.clone(),
    });

    Ok(Json(WorktreeRemovedResponse {
        worktree_id,
        ok: true,
    }))
}

pub async fn git_init_endpoint(Json(body): Json<GitInitRequest>) -> ApiResult<GitInitResponse> {
    // Verify the directory exists
    if tokio::fs::metadata(&body.path).await.is_err() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "path_not_found",
                error: format!("directory does not exist: {}", body.path),
            }),
        ));
    }

    crate::git::git_init(&body.path)
        .await
        .map(|_| Json(GitInitResponse { ok: true }))
        .map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiErrorResponse {
                    code: "git_init_failed",
                    error: e,
                }),
            )
        })
}

pub async fn update_review_comment(
    Path(comment_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<UpdateReviewCommentRequest>,
) -> ApiResult<ReviewCommentMutationResponse> {
    let tag_str = body.tag.map(|t| match t {
        ReviewCommentTag::Clarity => "clarity".to_string(),
        ReviewCommentTag::Scope => "scope".to_string(),
        ReviewCommentTag::Risk => "risk".to_string(),
        ReviewCommentTag::Nit => "nit".to_string(),
    });
    let status_str = body.status.map(|s| match s {
        ReviewCommentStatus::Open => "open".to_string(),
        ReviewCommentStatus::Resolved => "resolved".to_string(),
    });

    let _ = state
        .persist()
        .send(PersistCommand::ReviewCommentUpdate {
            id: comment_id.clone(),
            body: body.body,
            tag: tag_str,
            status: status_str,
        })
        .await;

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        ok: true,
    }))
}

pub async fn delete_review_comment_by_id(
    Path(comment_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<ReviewCommentMutationResponse> {
    let _ = state
        .persist()
        .send(PersistCommand::ReviewCommentDelete {
            id: comment_id.clone(),
        })
        .await;

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        ok: true,
    }))
}

// ── Group B: Operations with broadcast ────────────────────────

pub async fn set_server_role(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SetServerRoleRequest>,
) -> ApiResult<ServerRoleResponse> {
    info!(
        component = "api",
        event = "api.server_role.set",
        is_primary = body.is_primary,
        "Server role updated via REST"
    );

    let _changed = state.set_primary(body.is_primary);

    let role_value = if body.is_primary {
        "primary".to_string()
    } else {
        "secondary".to_string()
    };
    let _ = state
        .persist()
        .send(PersistCommand::SetConfig {
            key: "server_role".into(),
            value: role_value,
        })
        .await;

    let update = crate::websocket::server_info_message(&state);
    state.broadcast_to_list(update);

    Ok(Json(ServerRoleResponse {
        is_primary: body.is_primary,
    }))
}

pub async fn create_review_comment_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CreateReviewCommentRequest>,
) -> ApiResult<ReviewCommentMutationResponse> {
    use std::time::{SystemTime, UNIX_EPOCH};

    let comment_id = format!(
        "rc-{}-{}",
        &session_id[..8.min(session_id.len())],
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );

    let tag_str = body.tag.map(|t| {
        match t {
            ReviewCommentTag::Clarity => "clarity",
            ReviewCommentTag::Scope => "scope",
            ReviewCommentTag::Risk => "risk",
            ReviewCommentTag::Nit => "nit",
        }
        .to_string()
    });

    let now = crate::session_utils::chrono_now();

    let comment = ReviewComment {
        id: comment_id.clone(),
        session_id: session_id.clone(),
        turn_id: body.turn_id.clone(),
        file_path: body.file_path.clone(),
        line_start: body.line_start,
        line_end: body.line_end,
        body: body.body.clone(),
        tag: body.tag,
        status: ReviewCommentStatus::Open,
        created_at: now,
        updated_at: None,
    };

    let _ = state
        .persist()
        .send(PersistCommand::ReviewCommentCreate {
            id: comment_id.clone(),
            session_id: session_id.clone(),
            turn_id: body.turn_id,
            file_path: body.file_path,
            line_start: body.line_start,
            line_end: body.line_end,
            body: body.body,
            tag: tag_str,
        })
        .await;

    // Broadcast to session subscribers
    if let Some(actor) = state.get_session(&session_id) {
        actor
            .send(crate::session_command::SessionCommand::Broadcast {
                msg: ServerMessage::ReviewCommentCreated {
                    session_id,
                    comment,
                },
            })
            .await;
    }

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        ok: true,
    }))
}

pub async fn codex_login_start(
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<CodexLoginStartedResponse> {
    let auth = state.codex_auth();
    match auth.start_chatgpt_login().await {
        Ok((login_id, auth_url)) => {
            if let Ok(status) = auth.read_account(false).await {
                state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
            }
            Ok(Json(CodexLoginStartedResponse { login_id, auth_url }))
        }
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "codex_auth_login_start_failed",
                error: err,
            }),
        )),
    }
}

pub async fn codex_login_cancel(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CodexLoginCancelRequest>,
) -> Json<CodexLoginCanceledResponse> {
    let auth = state.codex_auth();
    let status = auth.cancel_chatgpt_login(body.login_id.clone()).await;
    if let Ok(account_status) = auth.read_account(false).await {
        state.broadcast_to_list(ServerMessage::CodexAccountStatus {
            status: account_status,
        });
    }
    Json(CodexLoginCanceledResponse {
        login_id: body.login_id,
        status,
    })
}

pub async fn codex_logout(
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<CodexLogoutResponse> {
    let auth = state.codex_auth();
    match auth.logout().await {
        Ok(status) => {
            let updated = ServerMessage::CodexAccountUpdated {
                status: status.clone(),
            };
            state.broadcast_to_list(updated);
            Ok(Json(CodexLogoutResponse { status }))
        }
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "codex_auth_logout_failed",
                error: err,
            }),
        )),
    }
}

// ── Group C: Async fire-and-forget (202 Accepted) ─────────────

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

    // Try Codex first, fall back to Claude
    if dispatch_codex_action(&state, &session_id, CodexAction::RefreshMcpServers)
        .await
        .is_err()
    {
        let action = match server_name {
            Some(name) => ClaudeAction::RefreshMcpServer { server_name: name },
            None => ClaudeAction::ListMcpTools, // No specific server — refresh all via status query
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

// ── Private helpers ───────────────────────────────────────────

async fn load_session_state(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> Result<SessionState, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::GetState { reply: reply_tx })
            .await;

        let mut snapshot = reply_rx
            .await
            .map_err(|err| SessionLoadError::Runtime(err.to_string()))?;

        hydrate_runtime_messages(&actor, &mut snapshot, session_id).await;
        hydrate_subagents(&mut snapshot, session_id).await;
        return Ok(snapshot);
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            if restored.messages.is_empty() {
                if let Some(ref transcript_path) = restored.transcript_path {
                    if let Ok(messages) =
                        load_messages_from_transcript_path(transcript_path, session_id).await
                    {
                        if !messages.is_empty() {
                            restored.messages = messages;
                        }
                    }
                }
            }

            let mut state = restored_session_to_state(restored);
            hydrate_subagents(&mut state, session_id).await;
            Ok(state)
        }
        Ok(None) => Err(SessionLoadError::NotFound),
        Err(err) => Err(SessionLoadError::Db(err.to_string())),
    }
}

async fn hydrate_runtime_messages(
    actor: &SessionActorHandle,
    state: &mut SessionState,
    session_id: &str,
) {
    if !state.messages.is_empty() {
        return;
    }

    if let Some(path) = state.transcript_path.clone() {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::LoadTranscriptAndSync {
                path,
                session_id: session_id.to_string(),
                reply: reply_tx,
            })
            .await;

        if let Ok(Some(loaded)) = reply_rx.await {
            *state = loaded;
        }
    }

    if state.messages.is_empty() {
        if let Ok(messages) = load_messages_for_session(session_id).await {
            if !messages.is_empty() {
                state.messages = messages;
            }
        }
    }
}

async fn hydrate_subagents(state: &mut SessionState, session_id: &str) {
    if !state.subagents.is_empty() {
        return;
    }

    match load_subagents_for_session(session_id).await {
        Ok(subagents) => {
            state.subagents = subagents;
        }
        Err(err) => {
            warn!(
                component = "api",
                event = "api.get_session.subagents_load_failed",
                session_id = %session_id,
                error = %err,
                "Failed to load session subagents"
            );
        }
    }
}

fn restored_session_to_state(restored: RestoredSession) -> SessionState {
    let provider = parse_provider(&restored.provider);
    let status = parse_session_status(restored.end_reason.as_ref(), &restored.status);
    let work_status = parse_work_status(status, &restored.work_status);

    SessionState {
        id: restored.id,
        provider,
        project_path: restored.project_path,
        transcript_path: restored.transcript_path,
        project_name: restored.project_name,
        model: restored.model,
        custom_name: restored.custom_name,
        summary: restored.summary,
        first_prompt: restored.first_prompt,
        last_message: restored.last_message,
        status,
        work_status,
        messages: restored.messages,
        pending_approval: None,
        permission_mode: restored.permission_mode,
        pending_tool_name: restored.pending_tool_name,
        pending_tool_input: restored.pending_tool_input,
        pending_question: restored.pending_question,
        pending_approval_id: restored.pending_approval_id,
        token_usage: TokenUsage {
            input_tokens: restored.input_tokens as u64,
            output_tokens: restored.output_tokens as u64,
            cached_tokens: restored.cached_tokens as u64,
            context_window: restored.context_window as u64,
        },
        token_usage_snapshot_kind: restored.token_usage_snapshot_kind,
        current_diff: restored.current_diff,
        current_plan: restored.current_plan,
        codex_integration_mode: parse_codex_integration_mode(restored.codex_integration_mode),
        claude_integration_mode: parse_claude_integration_mode(restored.claude_integration_mode),
        approval_policy: restored.approval_policy,
        sandbox_mode: restored.sandbox_mode,
        started_at: restored.started_at,
        last_activity_at: restored.last_activity_at,
        forked_from_session_id: restored.forked_from_session_id,
        revision: Some(0),
        current_turn_id: None,
        turn_count: 0,
        turn_diffs: restored
            .turn_diffs
            .into_iter()
            .map(
                |(
                    turn_id,
                    diff,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    snapshot_kind,
                )| {
                    TurnDiff {
                        turn_id,
                        diff,
                        token_usage: Some(TokenUsage {
                            input_tokens: input_tokens as u64,
                            output_tokens: output_tokens as u64,
                            cached_tokens: cached_tokens as u64,
                            context_window: context_window as u64,
                        }),
                        snapshot_kind: Some(snapshot_kind),
                    }
                },
            )
            .collect(),
        git_branch: restored.git_branch,
        git_sha: restored.git_sha,
        current_cwd: restored.current_cwd,
        subagents: Vec::new(),
        effort: restored.effort,
        terminal_session_id: restored.terminal_session_id,
        terminal_app: restored.terminal_app,
        approval_version: Some(restored.approval_version),
        repository_root: None,
        is_worktree: false,
        worktree_id: None,
        unread_count: restored.unread_count,
    }
}

fn resolve_browse_target(path: Option<&str>) -> PathBuf {
    match path {
        Some(path) if !path.is_empty() => {
            if let Some(stripped) = path.strip_prefix('~') {
                if let Some(home) = dirs::home_dir() {
                    return home.join(stripped.trim_start_matches('/'));
                }
            }
            PathBuf::from(path)
        }
        _ => dirs::home_dir().unwrap_or_else(|| PathBuf::from("/")),
    }
}

fn read_directory_entries(target: &PathBuf) -> Result<Vec<DirectoryEntry>, std::io::Error> {
    let mut listing: Vec<DirectoryEntry> = Vec::new();

    for entry in std::fs::read_dir(target)? {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };

        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(_) => continue,
        };

        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }

        let is_dir = meta.is_dir();
        let is_git = if is_dir {
            entry.path().join(".git").exists()
        } else {
            false
        };

        listing.push(DirectoryEntry {
            name,
            is_dir,
            is_git,
        });
    }

    listing.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(listing)
}

async fn load_subagent_tools(subagent_id: &str) -> Vec<SubagentTool> {
    match load_subagent_transcript_path(subagent_id).await {
        Ok(Some(path)) => {
            let parse_path = path.clone();
            tokio::task::spawn_blocking(move || {
                crate::subagent_parser::parse_tools(std::path::Path::new(&parse_path))
            })
            .await
            .unwrap_or_default()
        }
        Ok(None) => vec![],
        Err(err) => {
            warn!(
                component = "api",
                event = "api.subagent_tools.load_error",
                subagent_id = %subagent_id,
                error = %err,
                "Failed to load subagent transcript path"
            );
            vec![]
        }
    }
}

async fn subscribe_session_events(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> ApiInnerResult<broadcast::Receiver<ServerMessage>> {
    let actor = state.get_session(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::SessionNotFound, session_id)
    })?;

    let (reply_tx, reply_rx) = oneshot::channel();
    actor
        .send(SessionCommand::Subscribe {
            since_revision: None,
            reply: reply_tx,
        })
        .await;

    match reply_rx.await {
        Ok(SubscribeResult::Snapshot { rx, .. }) | Ok(SubscribeResult::Replay { rx, .. }) => Ok(rx),
        Err(_) => Err(codex_action_error_response(
            CodexActionError::ChannelClosed,
            session_id,
        )),
    }
}

async fn dispatch_codex_action(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    action: CodexAction,
) -> ApiInnerResult<()> {
    let tx = state.get_codex_action_tx(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::ConnectorNotAvailable, session_id)
    })?;

    tx.send(action)
        .await
        .map_err(|_| codex_action_error_response(CodexActionError::ChannelClosed, session_id))
}

async fn dispatch_claude_action(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    action: ClaudeAction,
) -> ApiInnerResult<()> {
    let tx = state.get_claude_action_tx(session_id).ok_or_else(|| {
        codex_action_error_response(CodexActionError::ConnectorNotAvailable, session_id)
    })?;

    tx.send(action)
        .await
        .map_err(|_| codex_action_error_response(CodexActionError::ChannelClosed, session_id))
}

async fn wait_for_codex_skills_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<(Vec<SkillsListEntry>, Vec<SkillErrorInfo>)> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::SkillsList {
                    session_id: sid,
                    skills,
                    errors,
                }) if sid == session_id => return Ok((skills, errors)),
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

async fn wait_for_remote_skills_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<Vec<RemoteSkillSummary>> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::RemoteSkillsList {
                    session_id: sid,
                    skills,
                }) if sid == session_id => return Ok(skills),
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

type McpToolsEvent = (
    HashMap<String, McpTool>,
    HashMap<String, Vec<McpResource>>,
    HashMap<String, Vec<McpResourceTemplate>>,
    HashMap<String, McpAuthStatus>,
);

async fn wait_for_mcp_tools_event(
    session_id: &str,
    rx: &mut broadcast::Receiver<ServerMessage>,
) -> ApiInnerResult<McpToolsEvent> {
    tokio::time::timeout(CODEX_ACTION_WAIT_TIMEOUT, async {
        loop {
            match rx.recv().await {
                Ok(ServerMessage::McpToolsList {
                    session_id: sid,
                    tools,
                    resources,
                    resource_templates,
                    auth_statuses,
                }) if sid == session_id => {
                    return Ok((tools, resources, resource_templates, auth_statuses));
                }
                Ok(ServerMessage::Error {
                    session_id: Some(sid),
                    code,
                    message,
                }) if sid == session_id => {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(ApiErrorResponse {
                            code: "codex_action_error",
                            error: format!("{code}: {message}"),
                        }),
                    ));
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(codex_action_error_response(
                        CodexActionError::ChannelClosed,
                        session_id,
                    ));
                }
            }
        }
    })
    .await
    .map_err(|_| codex_action_error_response(CodexActionError::Timeout, session_id))?
}

fn codex_action_error_response(
    error: CodexActionError,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        CodexActionError::SessionNotFound => (
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {session_id} not found"),
            }),
        ),
        CodexActionError::ConnectorNotAvailable => (
            StatusCode::CONFLICT,
            Json(ApiErrorResponse {
                code: "session_not_found",
                error: format!("Session {session_id} not found or has no active connector"),
            }),
        ),
        CodexActionError::ChannelClosed => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "channel_closed",
                error: format!("Session {session_id} connector channel is closed"),
            }),
        ),
        CodexActionError::Timeout => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(ApiErrorResponse {
                code: "timeout",
                error: format!("Timed out waiting for session {session_id} response"),
            }),
        ),
    }
}

fn not_control_plane_endpoint_error() -> UsageErrorInfo {
    UsageErrorInfo {
        code: "not_control_plane_endpoint".to_string(),
        message: "This endpoint is not primary for control-plane usage reads.".to_string(),
    }
}

fn parse_provider(value: &str) -> Provider {
    if value.eq_ignore_ascii_case("claude") {
        Provider::Claude
    } else {
        Provider::Codex
    }
}

fn parse_session_status(end_reason: Option<&String>, value: &str) -> SessionStatus {
    if end_reason.is_some() {
        return SessionStatus::Ended;
    }

    if value.eq_ignore_ascii_case("ended") {
        SessionStatus::Ended
    } else {
        SessionStatus::Active
    }
}

fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
    if status == SessionStatus::Ended {
        return WorkStatus::Ended;
    }

    match value.trim().to_ascii_lowercase().as_str() {
        "working" => WorkStatus::Working,
        "permission" => WorkStatus::Permission,
        "question" => WorkStatus::Question,
        "reply" => WorkStatus::Reply,
        "ended" => WorkStatus::Ended,
        _ => WorkStatus::Waiting,
    }
}

fn parse_codex_integration_mode(value: Option<String>) -> Option<CodexIntegrationMode> {
    match value.as_deref() {
        Some("direct") => Some(CodexIntegrationMode::Direct),
        Some("passive") => Some(CodexIntegrationMode::Passive),
        _ => None,
    }
}

fn parse_claude_integration_mode(value: Option<String>) -> Option<ClaudeIntegrationMode> {
    match value.as_deref() {
        Some("direct") => Some(ClaudeIntegrationMode::Direct),
        Some("passive") => Some(ClaudeIntegrationMode::Passive),
        _ => None,
    }
}

// -- Mark read --

#[derive(Debug, Serialize)]
pub struct MarkReadResponse {
    pub session_id: String,
    pub unread_count: u64,
}

pub async fn mark_session_read(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<MarkReadResponse> {
    let actor = match state.get_session(&session_id) {
        Some(a) => a,
        None => {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiErrorResponse {
                    code: "session_not_found",
                    error: format!("Session {} not found", session_id),
                }),
            ))
        }
    };

    let (tx, rx) = oneshot::channel();
    actor.send(SessionCommand::MarkRead { reply: tx }).await;

    let unread_count = rx.await.unwrap_or(0);

    // Persist the read watermark
    let max_seq: i64 = match load_messages_for_session(&session_id).await {
        Ok(msgs) => msgs.len() as i64,
        Err(_) => 0,
    };
    let _ = state
        .persist()
        .send(PersistCommand::MarkSessionRead {
            session_id: session_id.clone(),
            up_to_sequence: max_seq,
        })
        .await;

    Ok(Json(MarkReadResponse {
        session_id,
        unread_count,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex_session::CodexAction;
    use crate::session::SessionHandle;
    use orbitdock_protocol::{
        McpResource, McpResourceTemplate, Message, MessageType, RemoteSkillSummary, SkillMetadata,
        SkillScope,
    };
    use serde_json::json;
    use std::collections::HashMap;
    use std::sync::Once;
    use tokio::sync::mpsc;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-http-api-tests");
            crate::paths::init_data_dir(Some(&dir));
        });
    }

    fn new_test_state(is_primary: bool) -> Arc<SessionRegistry> {
        ensure_test_data_dir();
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        Arc::new(SessionRegistry::new_with_primary(persist_tx, is_primary))
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

        let Json(response) = browse_directory(Query(BrowseDirectoryQuery {
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
        ensure_test_data_dir();
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
    async fn subagent_tools_endpoint_returns_empty_when_subagent_missing() {
        ensure_test_data_dir();
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
        ensure_test_data_dir();
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
}
