use super::errors::{conflict, internal, unprocessable};
use super::*;
use crate::connectors::codex_session::CodexAction;
use crate::runtime::restored_sessions::load_prepared_resume_session;
use crate::runtime::session_creation::{
    launch_prepared_direct_session, prepare_persist_direct_session, DirectSessionRequest,
};
use crate::runtime::session_fork_policy::{plan_fork_config, ForkConfigInputs};
use crate::runtime::session_fork_runtime::{
    finalize_codex_fork_session, start_claude_fork_session,
};
use crate::runtime::session_fork_targets::{
    create_fork_target_worktree, resolve_existing_fork_worktree_path,
};
use crate::runtime::session_mutations::{
    end_session as end_runtime_session, rename_session as rename_runtime_session,
    update_session_config as update_runtime_session_config, SessionConfigUpdate,
    SessionMutationError,
};
use crate::runtime::session_resume::{launch_resumed_session, ResumeSessionError};
use crate::runtime::session_takeover::{
    takeover_passive_session, TakeoverSessionError, TakeoverSessionInputs,
};
use orbitdock_protocol::{Provider, ServerMessage};
use tracing::error;

fn resolve_developer_instructions(
    developer_instructions: Option<String>,
    system_prompt: Option<String>,
    append_system_prompt: Option<String>,
) -> Option<String> {
    if developer_instructions.is_some() {
        return developer_instructions;
    }

    match (
        system_prompt.filter(|value| !value.trim().is_empty()),
        append_system_prompt.filter(|value| !value.trim().is_empty()),
    ) {
        (Some(base), Some(append)) => Some(format!("{base}\n\n{append}")),
        (Some(base), None) => Some(base),
        (None, Some(append)) => Some(append),
        (None, None) => None,
    }
}

fn lifecycle_error(
    status: StatusCode,
    code: &'static str,
    error: impl Into<String>,
) -> (StatusCode, Json<ApiErrorResponse>) {
    super::errors::api_error(status, code, error)
}

fn map_resume_error(error: ResumeSessionError) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        ResumeSessionError::MissingClaudeResumeId => unprocessable(error.code(), error.message()),
    }
}

fn map_takeover_error(error: TakeoverSessionError) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        TakeoverSessionError::NotFound(_) => {
            super::errors::api_error(StatusCode::NOT_FOUND, error.code(), error.message())
        }
        TakeoverSessionError::NotPassive(_) => conflict(error.code(), error.message()),
        TakeoverSessionError::TakeHandleFailed => internal(error.code(), error.message()),
        TakeoverSessionError::ConnectorFailed(_) => internal(error.code(), error.message()),
    }
}

fn map_session_mutation_error(error: SessionMutationError) -> (StatusCode, Json<ApiErrorResponse>) {
    match error {
        SessionMutationError::NotFound(_) => {
            super::errors::api_error(StatusCode::NOT_FOUND, error.code(), error.message())
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct RenameSessionRequest {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateSessionConfigRequest {
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
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
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
}

pub async fn rename_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RenameSessionRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    rename_runtime_session(&state, &session_id, body.name)
        .await
        .map_err(map_session_mutation_error)?;

    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn update_session_config(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<UpdateSessionConfigRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    update_runtime_session_config(
        &state,
        &session_id,
        SessionConfigUpdate {
            approval_policy: body.approval_policy,
            sandbox_mode: body.sandbox_mode,
            permission_mode: body.permission_mode,
            collaboration_mode: body.collaboration_mode,
            multi_agent: body.multi_agent,
            personality: body.personality,
            service_tier: body.service_tier,
            developer_instructions: body.developer_instructions,
            model: body.model,
            effort: body.effort,
        },
    )
    .await
    .map_err(map_session_mutation_error)?;

    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn end_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    end_runtime_session(&state, &session_id).await;

    Ok(Json(AcceptedResponse { accepted: true }))
}

#[derive(Debug, Deserialize)]
pub struct CreateSessionRequest {
    pub provider: Provider,
    pub cwd: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
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
}

#[derive(Debug, Serialize)]
pub struct CreateSessionResponse {
    pub session_id: String,
    pub session: SessionSummary,
}

pub async fn create_session(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CreateSessionRequest>,
) -> Result<Json<CreateSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let session_id = orbitdock_protocol::new_id();
    let developer_instructions = resolve_developer_instructions(
        body.developer_instructions.clone(),
        body.system_prompt.clone(),
        body.append_system_prompt.clone(),
    );
    let prepared = prepare_persist_direct_session(
        &state,
        session_id.clone(),
        DirectSessionRequest {
            provider: body.provider,
            cwd: body.cwd.clone(),
            model: body.model.clone(),
            approval_policy: body.approval_policy.clone(),
            sandbox_mode: body.sandbox_mode.clone(),
            permission_mode: body.permission_mode.clone(),
            allowed_tools: body.allowed_tools.clone(),
            disallowed_tools: body.disallowed_tools.clone(),
            effort: body.effort.clone(),
            collaboration_mode: body.collaboration_mode.clone(),
            multi_agent: body.multi_agent,
            personality: body.personality.clone(),
            service_tier: body.service_tier.clone(),
            developer_instructions,
            mission_id: None,
            issue_identifier: None,
            dynamic_tools: Vec::new(),
            allow_bypass_permissions: body.allow_bypass_permissions,
        },
    )
    .await;
    let summary = prepared.summary.clone();

    if let Err(error_message) = launch_prepared_direct_session(&state, prepared).await {
        error!(
            component = "session",
            event = "session.create.http.connector_failed",
            session_id = %session_id,
            error = %error_message,
            "HTTP: Failed to start direct session connector"
        );
    }

    state.broadcast_to_list(ServerMessage::SessionCreated {
        session: summary.clone().into(),
    });

    Ok(Json(CreateSessionResponse {
        session_id,
        session: summary,
    }))
}

#[derive(Debug, Serialize)]
pub struct ResumeSessionResponse {
    pub session_id: String,
    pub session: SessionSummary,
}

pub async fn resume_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<ResumeSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    use orbitdock_protocol::SessionStatus;

    if let Some(handle) = state.get_session(&session_id) {
        let snap = handle.snapshot();
        if snap.status == SessionStatus::Active {
            return Err(conflict(
                "already_active",
                format!("Session {} is already active", session_id),
            ));
        }
        state.remove_session(&session_id);
    }

    let prepared = match load_prepared_resume_session(&session_id).await {
        Ok(Some(prepared)) => prepared,
        Ok(None) => return Err(session_not_found_error(&session_id)),
        Err(error) => return Err(internal("db_error", error.to_string())),
    };

    let summary = launch_resumed_session(&state, &session_id, prepared)
        .await
        .map_err(map_resume_error)?
        .summary;

    Ok(Json(ResumeSessionResponse {
        session_id,
        session: summary,
    }))
}

#[derive(Debug, Deserialize)]
pub struct TakeoverSessionRequest {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
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
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub disallowed_tools: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct TakeoverSessionResponse {
    pub session_id: String,
    pub accepted: bool,
}

pub async fn takeover_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<TakeoverSessionRequest>,
) -> Result<Json<TakeoverSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    takeover_passive_session(
        &state,
        &session_id,
        TakeoverSessionInputs {
            model: body.model,
            approval_policy: body.approval_policy,
            sandbox_mode: body.sandbox_mode,
            permission_mode: body.permission_mode,
            collaboration_mode: body.collaboration_mode,
            multi_agent: body.multi_agent,
            personality: body.personality,
            service_tier: body.service_tier,
            developer_instructions: body.developer_instructions,
            allowed_tools: body.allowed_tools,
            disallowed_tools: body.disallowed_tools,
        },
    )
    .await
    .map_err(map_takeover_error)?;

    Ok(Json(TakeoverSessionResponse {
        session_id,
        accepted: true,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ForkSessionRequest {
    #[serde(default)]
    pub nth_user_message: Option<u32>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub approval_policy: Option<String>,
    #[serde(default)]
    pub sandbox_mode: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub disallowed_tools: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ForkSessionResponse {
    pub source_session_id: String,
    pub new_session_id: String,
    pub session: SessionSummary,
}

pub async fn fork_session(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkSessionRequest>,
) -> Result<Json<ForkSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let source_snapshot = state
        .get_session(&source_session_id)
        .map(|session| session.snapshot())
        .ok_or_else(|| session_not_found_error(&source_session_id))?;

    let fork_plan = plan_fork_config(ForkConfigInputs {
        requested_model: body.model.clone(),
        requested_approval_policy: body.approval_policy.clone(),
        requested_sandbox_mode: body.sandbox_mode.clone(),
        requested_cwd: body.cwd.clone(),
        source_cwd: Some(source_snapshot.project_path.clone()),
        source_model: source_snapshot.model.clone(),
        source_approval_policy: source_snapshot.approval_policy.clone(),
        source_sandbox_mode: source_snapshot.sandbox_mode.clone(),
    });
    let effective_cwd = fork_plan
        .effective_cwd
        .clone()
        .unwrap_or_else(|| source_snapshot.project_path.clone());

    match source_snapshot.provider {
        Provider::Claude => {
            let started = start_claude_fork_session(
                &state,
                &source_session_id,
                &effective_cwd,
                fork_plan.effective_model.as_deref(),
                body.permission_mode.as_deref(),
                &body.allowed_tools,
                &body.disallowed_tools,
            )
            .await
            .map_err(|error| internal("fork_failed", error))?;

            state.broadcast_to_list(ServerMessage::SessionCreated {
                session: started.summary.clone().into(),
            });

            Ok(Json(ForkSessionResponse {
                source_session_id,
                new_session_id: started.new_session_id,
                session: started.summary,
            }))
        }
        Provider::Codex => {
            let source_action_tx =
                state
                    .get_codex_action_tx(&source_session_id)
                    .ok_or_else(|| {
                        unprocessable(
                            "not_found",
                            format!(
                                "Source session {} has no active Codex connector",
                                source_session_id
                            ),
                        )
                    })?;

            let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
            if source_action_tx
                .send(CodexAction::ForkSession {
                    source_session_id: source_session_id.clone(),
                    nth_user_message: body.nth_user_message,
                    model: fork_plan.effective_model.clone(),
                    approval_policy: fork_plan.effective_approval_policy.clone(),
                    sandbox_mode: fork_plan.effective_sandbox_mode.clone(),
                    cwd: Some(effective_cwd.clone()),
                    reply_tx,
                })
                .await
                .is_err()
            {
                return Err(internal(
                    "channel_closed",
                    "Source session's action channel is closed",
                ));
            }

            let fork_result = match reply_rx.await {
                Ok(result) => result,
                Err(_) => return Err(internal("fork_failed", "Fork operation was cancelled")),
            };
            let (new_connector, new_thread_id) =
                fork_result.map_err(|error| internal("fork_failed", error.to_string()))?;

            let started = finalize_codex_fork_session(
                &state,
                crate::runtime::session_fork_runtime::FinalizeCodexForkRequest {
                    source_session_id: &source_session_id,
                    nth_user_message: body.nth_user_message,
                    effective_cwd: &effective_cwd,
                    effective_model: fork_plan.effective_model.as_deref(),
                    effective_approval_policy: fork_plan.effective_approval_policy.as_deref(),
                    effective_sandbox_mode: fork_plan.effective_sandbox_mode.as_deref(),
                    new_connector,
                    new_thread_id,
                },
            )
            .await
            .map_err(|error| internal("fork_failed", error))?;

            state.broadcast_to_list(ServerMessage::SessionCreated {
                session: started.summary.clone().into(),
            });

            Ok(Json(ForkSessionResponse {
                source_session_id,
                new_session_id: started.new_session_id,
                session: started.summary,
            }))
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct ForkToWorktreeRequest {
    pub branch_name: String,
    #[serde(default)]
    pub base_branch: Option<String>,
    #[serde(default)]
    pub nth_user_message: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct ForkToWorktreeResponse {
    pub source_session_id: String,
    pub new_session_id: String,
    pub session: SessionSummary,
    pub worktree: orbitdock_protocol::WorktreeSummary,
}

pub async fn fork_session_to_worktree(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkToWorktreeRequest>,
) -> Result<Json<ForkToWorktreeResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let source_snapshot = state
        .get_session(&source_session_id)
        .map(|session| session.snapshot())
        .ok_or_else(|| session_not_found_error(&source_session_id))?;

    let worktree_summary = create_fork_target_worktree(
        &state,
        &source_snapshot,
        &body.branch_name,
        body.base_branch.as_deref(),
    )
    .await
    .map_err(|error| {
        lifecycle_error(
            if error.code == "worktree_create_invalid_input" {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            },
            error.code,
            error.message,
        )
    })?;

    state.broadcast_to_list(ServerMessage::WorktreeCreated {
        request_id: String::new(),
        repo_root: worktree_summary.repo_root.clone(),
        worktree_revision: revision_now(),
        worktree: worktree_summary.clone(),
    });

    let fork_result = fork_session(
        Path(source_session_id.clone()),
        State(state),
        Json(ForkSessionRequest {
            nth_user_message: body.nth_user_message,
            model: None,
            approval_policy: None,
            sandbox_mode: None,
            cwd: Some(worktree_summary.worktree_path.clone()),
            permission_mode: None,
            allowed_tools: Vec::new(),
            disallowed_tools: Vec::new(),
        }),
    )
    .await?;

    Ok(Json(ForkToWorktreeResponse {
        source_session_id: fork_result.source_session_id.clone(),
        new_session_id: fork_result.new_session_id.clone(),
        session: fork_result.session.clone(),
        worktree: worktree_summary,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ForkToExistingWorktreeRequest {
    pub worktree_id: String,
    #[serde(default)]
    pub nth_user_message: Option<u32>,
}

pub async fn fork_session_to_existing_worktree(
    Path(source_session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ForkToExistingWorktreeRequest>,
) -> Result<Json<ForkSessionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let source_snapshot = state
        .get_session(&source_session_id)
        .map(|session| session.snapshot())
        .ok_or_else(|| session_not_found_error(&source_session_id))?;

    let target_worktree_path =
        resolve_existing_fork_worktree_path(state.db_path(), &source_snapshot, &body.worktree_id)
            .await
            .map_err(|error| {
                lifecycle_error(
                    match error.code {
                        "worktree_repo_mismatch" => StatusCode::BAD_REQUEST,
                        "worktree_missing" => StatusCode::GONE,
                        _ => StatusCode::NOT_FOUND,
                    },
                    error.code,
                    error.message,
                )
            })?;

    fork_session(
        Path(source_session_id),
        State(state),
        Json(ForkSessionRequest {
            nth_user_message: body.nth_user_message,
            model: None,
            approval_policy: None,
            sandbox_mode: None,
            cwd: Some(target_worktree_path),
            permission_mode: None,
            allowed_tools: Vec::new(),
            disallowed_tools: Vec::new(),
        }),
    )
    .await
}
