use std::collections::HashMap;

use super::errors::{bad_request, internal, not_found, unprocessable};
use super::*;
use orbitdock_protocol::PermissionGrantScope;

fn approval_dispatch_error_response(
    code: &'static str,
    session_id: &str,
) -> (StatusCode, Json<ApiErrorResponse>) {
    match code {
        "not_found" => not_found(
            "not_found",
            format!(
                "Session {} not found or has no active connector",
                session_id
            ),
        ),
        "invalid_answer_payload" => bad_request(
            "invalid_answer_payload",
            "Question approvals require a non-empty answer or answers map",
        ),
        "invalid_permissions_payload" => bad_request(
            "invalid_permissions_payload",
            "Permission approvals require an object payload or null",
        ),
        "rollback_failed" => unprocessable(
            "rollback_failed",
            "Could not find user message for rollback",
        ),
        _ => internal(code, format!("Operation failed for session {}", session_id)),
    }
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

#[derive(Debug, Deserialize, Default)]
pub struct ApprovalsQuery {
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct ApproveToolRequest {
    pub request_id: String,
    pub decision: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub interrupt: Option<bool>,
    #[serde(default)]
    pub updated_input: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct AnswerQuestionRequest {
    pub request_id: String,
    #[serde(default)]
    pub answer: String,
    #[serde(default)]
    pub question_id: Option<String>,
    #[serde(default)]
    pub answers: HashMap<String, Vec<String>>,
}

#[derive(Debug, Deserialize)]
pub struct RespondToPermissionRequest {
    pub request_id: String,
    #[serde(default)]
    pub permissions: Option<serde_json::Value>,
    #[serde(default)]
    pub scope: Option<PermissionGrantScope>,
}

#[derive(Debug, Serialize)]
pub struct ApprovalDecisionResponse {
    pub session_id: String,
    pub request_id: String,
    pub outcome: String,
    pub active_request_id: Option<String>,
    pub approval_version: u64,
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

pub async fn approve_tool(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ApproveToolRequest>,
) -> Result<Json<ApprovalDecisionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let result = crate::runtime::approval_dispatch::dispatch_approve_tool(
        &state,
        &session_id,
        body.request_id.clone(),
        body.decision,
        body.message,
        body.interrupt,
        body.updated_input,
    )
    .await
    .map_err(|code| approval_dispatch_error_response(code, &session_id))?;

    Ok(Json(ApprovalDecisionResponse {
        session_id,
        request_id: body.request_id,
        outcome: result.outcome,
        active_request_id: result.active_request_id,
        approval_version: result.approval_version,
    }))
}

pub async fn answer_question(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<AnswerQuestionRequest>,
) -> Result<Json<ApprovalDecisionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let result = crate::runtime::message_dispatch::dispatch_answer_question(
        &state,
        &session_id,
        body.request_id.clone(),
        body.answer,
        body.question_id,
        body.answers,
    )
    .await
    .map_err(|code| approval_dispatch_error_response(code, &session_id))?;

    Ok(Json(ApprovalDecisionResponse {
        session_id,
        request_id: body.request_id,
        outcome: result.outcome,
        active_request_id: result.active_request_id,
        approval_version: result.approval_version,
    }))
}

pub async fn respond_to_permission_request(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RespondToPermissionRequest>,
) -> Result<Json<ApprovalDecisionResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let result = crate::runtime::message_dispatch::dispatch_request_permissions_response(
        &state,
        &session_id,
        body.request_id.clone(),
        body.permissions,
        body.scope,
    )
    .await
    .map_err(|code| approval_dispatch_error_response(code, &session_id))?;

    Ok(Json(ApprovalDecisionResponse {
        session_id,
        request_id: body.request_id,
        outcome: result.outcome,
        active_request_id: result.active_request_id,
        approval_version: result.approval_version,
    }))
}
