use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_protocol::{ReviewComment, ReviewCommentStatus, ReviewCommentTag, ServerMessage};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::domain::sessions::registry::SessionRegistry;
use crate::infrastructure::persistence::{
    list_review_comments, load_review_comment_by_id, PersistCommand,
};

use super::{revision_now, ApiErrorResponse, ApiResult};

#[derive(Debug, Serialize)]
pub struct ReviewCommentsResponse {
    pub session_id: String,
    pub review_revision: u64,
    pub comments: Vec<ReviewComment>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ReviewCommentsQuery {
    #[serde(default)]
    pub turn_id: Option<String>,
}

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
    pub session_id: String,
    pub review_revision: u64,
    pub comment_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comment: Option<ReviewComment>,
    pub deleted: bool,
    pub ok: bool,
}

pub async fn list_review_comments_endpoint(
    Path(session_id): Path<String>,
    Query(query): Query<ReviewCommentsQuery>,
) -> Json<ReviewCommentsResponse> {
    let comments = match list_review_comments(&session_id, query.turn_id.as_deref()).await {
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
        review_revision: revision_now(),
        comments,
    })
}

pub async fn update_review_comment(
    Path(comment_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<UpdateReviewCommentRequest>,
) -> ApiResult<ReviewCommentMutationResponse> {
    let existing = load_review_comment_by_id(&comment_id)
        .await
        .map_err(|err| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "review_comment_load_failed",
                    error: err.to_string(),
                }),
            )
        })?;

    let existing = existing.ok_or_else(|| {
        (
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "review_comment_not_found",
                error: format!("review comment {comment_id} not found"),
            }),
        )
    })?;

    let updated_body = body.body.clone();
    let updated_tag = body.tag.clone();
    let updated_status = body.status.clone();

    let tag_str = body.tag.map(|tag| match tag {
        ReviewCommentTag::Clarity => "clarity".to_string(),
        ReviewCommentTag::Scope => "scope".to_string(),
        ReviewCommentTag::Risk => "risk".to_string(),
        ReviewCommentTag::Nit => "nit".to_string(),
    });
    let status_str = body.status.map(|status| match status {
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

    let updated = ReviewComment {
        id: existing.id.clone(),
        session_id: existing.session_id.clone(),
        turn_id: existing.turn_id.clone(),
        file_path: existing.file_path.clone(),
        line_start: existing.line_start,
        line_end: existing.line_end,
        body: updated_body.unwrap_or_else(|| existing.body.clone()),
        tag: updated_tag.or_else(|| existing.tag.clone()),
        status: updated_status.unwrap_or_else(|| existing.status.clone()),
        created_at: existing.created_at.clone(),
        updated_at: Some(crate::domain::sessions::session_utils::chrono_now()),
    };

    let review_revision = revision_now();
    if let Some(actor) = state.get_session(&updated.session_id) {
        actor
            .send(
                crate::domain::sessions::session_command::SessionCommand::Broadcast {
                    msg: ServerMessage::ReviewCommentUpdated {
                        session_id: updated.session_id.clone(),
                        review_revision,
                        comment: updated.clone(),
                    },
                },
            )
            .await;
    }

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        session_id: existing.session_id,
        review_revision,
        comment: Some(updated),
        deleted: false,
        ok: true,
    }))
}

pub async fn delete_review_comment_by_id(
    Path(comment_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<ReviewCommentMutationResponse> {
    let existing = load_review_comment_by_id(&comment_id)
        .await
        .map_err(|err| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "review_comment_load_failed",
                    error: err.to_string(),
                }),
            )
        })?;

    let existing = existing.ok_or_else(|| {
        (
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "review_comment_not_found",
                error: format!("review comment {comment_id} not found"),
            }),
        )
    })?;

    let _ = state
        .persist()
        .send(PersistCommand::ReviewCommentDelete {
            id: comment_id.clone(),
        })
        .await;

    let review_revision = revision_now();
    if let Some(actor) = state.get_session(&existing.session_id) {
        actor
            .send(
                crate::domain::sessions::session_command::SessionCommand::Broadcast {
                    msg: ServerMessage::ReviewCommentDeleted {
                        session_id: existing.session_id.clone(),
                        review_revision,
                        comment_id: comment_id.clone(),
                    },
                },
            )
            .await;
    }

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        session_id: existing.session_id,
        review_revision,
        comment: None,
        deleted: true,
        ok: true,
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

    let tag_str = body.tag.map(|tag| {
        match tag {
            ReviewCommentTag::Clarity => "clarity",
            ReviewCommentTag::Scope => "scope",
            ReviewCommentTag::Risk => "risk",
            ReviewCommentTag::Nit => "nit",
        }
        .to_string()
    });

    let now = crate::domain::sessions::session_utils::chrono_now();
    let review_revision = revision_now();

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

    if let Some(actor) = state.get_session(&session_id) {
        actor
            .send(
                crate::domain::sessions::session_command::SessionCommand::Broadcast {
                    msg: ServerMessage::ReviewCommentCreated {
                        session_id: session_id.clone(),
                        review_revision,
                        comment: comment.clone(),
                    },
                },
            )
            .await;
    }

    Ok(Json(ReviewCommentMutationResponse {
        comment_id,
        session_id: comment.session_id.clone(),
        review_revision,
        comment: Some(comment),
        deleted: false,
        ok: true,
    }))
}
