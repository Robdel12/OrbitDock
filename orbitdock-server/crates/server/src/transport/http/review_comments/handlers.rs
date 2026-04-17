use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
  extract::{Path, Query, State},
  Json,
};
use orbitdock_protocol::{ReviewComment, ReviewCommentStatus, ServerMessage};
use tracing::warn;

use crate::{
  infrastructure::persistence::{list_review_comments, PersistCommand},
  runtime::{session_commands::SessionCommand::Broadcast, session_registry::SessionRegistry},
  support::session_time::chrono_now,
  transport::http::{revision_now, ApiResult},
};

use super::{
  support::{
    load_existing_comment, review_comment_id, serialize_review_comment_status,
    serialize_review_comment_tag,
  },
  CreateReviewCommentRequest, ReviewCommentMutationResponse, ReviewCommentsQuery,
  ReviewCommentsResponse, UpdateReviewCommentRequest,
};

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
  State(state): State<std::sync::Arc<SessionRegistry>>,
  Json(body): Json<UpdateReviewCommentRequest>,
) -> ApiResult<ReviewCommentMutationResponse> {
  let existing = load_existing_comment(&comment_id).await?;
  let updated_body = body.body.clone();
  let updated_tag = body.tag;
  let updated_status = body.status;
  let session_id = existing.session_id.clone();

  let _ = state
    .persist()
    .send(PersistCommand::ReviewCommentUpdate {
      id: comment_id.clone(),
      body: body.body,
      tag: body.tag.map(serialize_review_comment_tag),
      status: body.status.map(serialize_review_comment_status),
    })
    .await;

  let updated = ReviewComment {
    id: existing.id.clone(),
    session_id: session_id.clone(),
    turn_id: existing.turn_id.clone(),
    file_path: existing.file_path.clone(),
    line_start: existing.line_start,
    line_end: existing.line_end,
    body: updated_body.unwrap_or_else(|| existing.body.clone()),
    tag: updated_tag.or(existing.tag),
    status: updated_status.unwrap_or(existing.status),
    created_at: existing.created_at.clone(),
    updated_at: Some(chrono_now()),
  };

  let review_revision = revision_now();
  if let Some(actor) = state.get_session(&session_id) {
    actor
      .send(Broadcast {
        msg: ServerMessage::ReviewCommentUpdated {
          session_id: session_id.clone(),
          review_revision,
          comment: updated.clone(),
        },
      })
      .await;
  }

  Ok(Json(ReviewCommentMutationResponse {
    comment_id,
    session_id,
    review_revision,
    comment: Some(updated),
    deleted: false,
    ok: true,
  }))
}

pub async fn delete_review_comment_by_id(
  Path(comment_id): Path<String>,
  State(state): State<std::sync::Arc<SessionRegistry>>,
) -> ApiResult<ReviewCommentMutationResponse> {
  let existing = load_existing_comment(&comment_id).await?;
  let session_id = existing.session_id.clone();

  let _ = state
    .persist()
    .send(PersistCommand::ReviewCommentDelete {
      id: comment_id.clone(),
    })
    .await;

  let review_revision = revision_now();
  if let Some(actor) = state.get_session(&session_id) {
    actor
      .send(Broadcast {
        msg: ServerMessage::ReviewCommentDeleted {
          session_id: session_id.clone(),
          review_revision,
          comment_id: comment_id.clone(),
        },
      })
      .await;
  }

  Ok(Json(ReviewCommentMutationResponse {
    comment_id,
    session_id,
    review_revision,
    comment: None,
    deleted: true,
    ok: true,
  }))
}

pub async fn create_review_comment_endpoint(
  Path(session_id): Path<String>,
  State(state): State<std::sync::Arc<SessionRegistry>>,
  Json(body): Json<CreateReviewCommentRequest>,
) -> ApiResult<ReviewCommentMutationResponse> {
  let comment_id = review_comment_id(
    &session_id,
    SystemTime::now()
      .duration_since(UNIX_EPOCH)
      .unwrap_or_default()
      .as_millis(),
  );
  let now = chrono_now();
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
      tag: body.tag.map(serialize_review_comment_tag),
    })
    .await;

  if let Some(actor) = state.get_session(&session_id) {
    actor
      .send(Broadcast {
        msg: ServerMessage::ReviewCommentCreated {
          session_id: session_id.clone(),
          review_revision,
          comment: comment.clone(),
        },
      })
      .await;
  }

  Ok(Json(ReviewCommentMutationResponse {
    comment_id,
    session_id,
    review_revision,
    comment: Some(comment),
    deleted: false,
    ok: true,
  }))
}
