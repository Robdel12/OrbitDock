use axum::{extract::Path, extract::Query, extract::State, Json};
use orbitdock_protocol::{Provider, ReviewCommentStatus, ReviewCommentTag};
use rusqlite::{params, Connection};

use crate::{
  domain::sessions::session::SessionHandle,
  infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
  transport::http::test_support::{flush_next_persist_command, new_persist_test_state},
};

use super::{
  create_review_comment_endpoint, delete_review_comment_by_id, list_review_comments_endpoint,
  update_review_comment, CreateReviewCommentRequest, ReviewCommentsQuery,
  UpdateReviewCommentRequest,
};

fn load_review_comment_row(
  db_path: &std::path::Path,
  comment_id: &str,
) -> Option<(String, Option<ReviewCommentTag>, ReviewCommentStatus)> {
  let conn = Connection::open(db_path).expect("open review comment test db");
  conn
    .query_row(
      "SELECT body, tag, status FROM review_comments WHERE id = ?1",
      params![comment_id],
      |row| {
        let body: String = row.get(0)?;
        let tag = row
          .get::<_, Option<String>>(1)?
          .and_then(|value| match value.as_str() {
            "nit" => Some(ReviewCommentTag::Nit),
            "risk" => Some(ReviewCommentTag::Risk),
            "clarity" => Some(ReviewCommentTag::Clarity),
            "scope" => Some(ReviewCommentTag::Scope),
            _ => None,
          });
        let status = match row.get::<_, String>(2)?.as_str() {
          "resolved" => ReviewCommentStatus::Resolved,
          _ => ReviewCommentStatus::Open,
        };
        Ok((body, tag, status))
      },
    )
    .ok()
}

#[tokio::test]
async fn review_comments_endpoint_returns_empty_when_none_exist() {
  let _guard = crate::support::test_support::test_env_lock().lock().await;
  crate::support::test_support::ensure_server_test_data_dir();
  let session_id = orbitdock_protocol::new_session_id();

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
  let (state, mut persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
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
        control_mode: orbitdock_protocol::SessionControlMode::Direct,
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
        worktree_id: None,
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
    load_review_comment_row(&db_path, &created.comment_id).expect("created comment should exist");
  assert_eq!(stored_after_create.0, "Initial review comment");

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
    load_review_comment_row(&db_path, &created.comment_id).expect("updated comment should exist");
  assert_eq!(stored_after_update.0, "Updated review comment");
  assert_eq!(stored_after_update.1, Some(ReviewCommentTag::Risk));
  assert_eq!(stored_after_update.2, ReviewCommentStatus::Resolved);

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

  let stored_after_delete = load_review_comment_row(&db_path, &created.comment_id);
  assert!(stored_after_delete.is_none());
}
