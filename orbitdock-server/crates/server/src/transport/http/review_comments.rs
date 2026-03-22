use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use orbitdock_protocol::{ReviewComment, ReviewCommentStatus, ReviewCommentTag, ServerMessage};
use serde::{Deserialize, Serialize};
use tracing::warn;

use crate::infrastructure::persistence::{
    list_review_comments, load_review_comment_by_id, PersistCommand,
};
use crate::runtime::session_registry::SessionRegistry;

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
    let updated_tag = body.tag;
    let updated_status = body.status;

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
        tag: updated_tag.or(existing.tag),
        status: updated_status.unwrap_or(existing.status),
        created_at: existing.created_at.clone(),
        updated_at: Some(crate::support::session_time::chrono_now()),
    };

    let review_revision = revision_now();
    if let Some(actor) = state.get_session(&updated.session_id) {
        actor
            .send(
                crate::runtime::session_commands::SessionCommand::Broadcast {
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
                crate::runtime::session_commands::SessionCommand::Broadcast {
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

    let now = crate::support::session_time::chrono_now();
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
                crate::runtime::session_commands::SessionCommand::Broadcast {
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Path, extract::Query, extract::State, Json};
    use orbitdock_protocol::{Provider, ReviewCommentStatus, ReviewCommentTag};

    use crate::domain::sessions::session::SessionHandle;
    use crate::infrastructure::persistence::{
        flush_batch_for_test, PersistCommand, SessionCreateParams,
    };
    use crate::transport::http::test_support::{
        flush_next_persist_command, new_persist_test_state,
    };

    #[tokio::test]
    async fn review_comments_endpoint_returns_empty_when_none_exist() {
        crate::support::test_support::ensure_server_test_data_dir();
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
            vec![PersistCommand::SessionCreate(Box::new(
                SessionCreateParams {
                    id: session_id.clone(),
                    provider: Provider::Codex,
                    project_path: "/tmp/orbitdock-review-contract".to_string(),
                    project_name: Some("orbitdock-review-contract".to_string()),
                    branch: Some("main".to_string()),
                    model: Some("gpt-5".to_string()),
                    approval_policy: None,
                    sandbox_mode: None,
                    permission_mode: None,
                    collaboration_mode: None,
                    multi_agent: None,
                    personality: None,
                    service_tier: None,
                    developer_instructions: None,
                    codex_config_mode: None,
                    codex_config_profile: None,
                    codex_model_provider: None,
                    codex_config_source: None,
                    codex_config_overrides_json: None,
                    forked_from_session_id: None,
                    mission_id: None,
                    issue_identifier: None,
                    allow_bypass_permissions: false,
                },
            ))],
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

        flush_next_persist_command(&mut persist_rx, &db_path).await;

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

        flush_next_persist_command(&mut persist_rx, &db_path).await;

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

        flush_next_persist_command(&mut persist_rx, &db_path).await;

        let stored_after_delete =
            crate::infrastructure::persistence::load_review_comment_by_id(&created.comment_id)
                .await
                .expect("load deleted comment");
        assert!(stored_after_delete.is_none());
    }
}
