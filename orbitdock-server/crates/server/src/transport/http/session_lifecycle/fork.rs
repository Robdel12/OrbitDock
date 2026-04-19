use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use serde::{Deserialize, Serialize};

use super::super::errors::{internal, unprocessable, ApiErrorResponse};
use super::super::{revision_now, session_not_found_error};
use super::common::lifecycle_error;
use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_fork_policy::{plan_fork_config, ForkConfigInputs};
use crate::runtime::session_fork_runtime::{
  finalize_codex_fork_session, start_claude_fork_session,
};
use crate::runtime::session_fork_targets::{
  create_fork_target_worktree, resolve_existing_fork_worktree_path,
};
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::{
  CodexApprovalPolicy, CodexSandboxPolicy, Provider, ServerMessage, SessionSummary,
};

#[derive(Debug, Deserialize)]
pub struct ForkSessionRequest {
  #[serde(default)]
  pub nth_user_message: Option<u32>,
  #[serde(default)]
  pub model: Option<String>,
  #[serde(default)]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default)]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
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
    requested_approval_policy: body
      .approval_policy_details
      .as_ref()
      .map(CodexApprovalPolicy::summary_text),
    requested_sandbox_mode: body
      .sandbox_policy_details
      .as_ref()
      .map(CodexSandboxPolicy::summary_text),
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

      Ok(Json(ForkSessionResponse {
        source_session_id,
        new_session_id: started.new_session_id,
        session: started.summary,
      }))
    }
    Provider::Codex => {
      let source_action_tx = state
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
      approval_policy_details: None,
      sandbox_policy_details: None,
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
      approval_policy_details: None,
      sandbox_policy_details: None,
      cwd: Some(target_worktree_path),
      permission_mode: None,
      allowed_tools: Vec::new(),
      disallowed_tools: Vec::new(),
    }),
  )
  .await
}
