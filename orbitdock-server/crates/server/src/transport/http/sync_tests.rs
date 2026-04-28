use super::*;
use axum::http::{header::AUTHORIZATION, HeaderValue};
use orbitdock_protocol::{Provider, SessionControlMode, WorkspaceProviderKind};
use std::sync::Arc;

use crate::infrastructure::{
  auth_tokens,
  persistence::{SyncCommand, SyncEnvelope, SyncSessionCreateParams},
};
use crate::support::test_support::test_env_lock;
use crate::transport::http::test_support::ensure_test_db;

async fn setup_state_with_workspace() -> (
  Arc<SessionRegistry>,
  String,
  tokio::sync::MutexGuard<'static, ()>,
) {
  let guard = test_env_lock().lock().await;
  let db_path = ensure_test_db();
  let issued = auth_tokens::issue_token(Some("workspace-sync")).expect("issue token");
  {
    let conn = rusqlite::Connection::open(&db_path).expect("open db");
    conn
      .execute(
        "INSERT INTO missions (id, name, repo_root, tracker_kind, provider, enabled, paused)
               VALUES ('mission-1', 'Mission', '/tmp/repo', 'linear', 'codex', 1, 0)",
        [],
      )
      .unwrap();
    conn.execute(
              "INSERT INTO mission_issues (id, mission_id, issue_id, issue_identifier, orchestration_state, attempt)
               VALUES ('mi-1', 'mission-1', 'issue-1', '#1', 'queued', 0)",
              [],
          )
          .unwrap();
    conn
      .execute(
        "INSERT INTO workspaces (id, mission_issue_id, branch, sync_token)
               VALUES ('workspace-1', 'mi-1', 'mission/issue-1', ?1)",
        rusqlite::params![issued.id],
      )
      .unwrap();
  }

  let (persist_tx, _persist_rx) = tokio::sync::mpsc::channel(8);
  (
    Arc::new(SessionRegistry::new_with_primary_and_db_path(
      persist_tx,
      db_path,
      true,
      WorkspaceProviderKind::Local,
    )),
    issued.token,
    guard,
  )
}

#[tokio::test]
async fn post_sync_batch_applies_batch_and_returns_ack() {
  let (state, token, _guard) = setup_state_with_workspace().await;
  let mut headers = HeaderMap::new();
  headers.insert(
    AUTHORIZATION,
    HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
  );

  let Json(response) = post_sync_batch(
    State(state.clone()),
    headers,
    Json(SyncBatchRequest {
      commands: vec![SyncEnvelope {
        sequence: 1,
        workspace_id: "workspace-1".into(),
        timestamp: crate::support::session_time::chrono_now(),
        command: SyncCommand::SessionCreate(Box::new(SyncSessionCreateParams {
          id: "session-1".into(),
          provider: Provider::Codex,
          control_mode: SessionControlMode::Direct,
          project_path: "/tmp/repo".into(),
          project_name: Some("repo".into()),
          branch: Some("main".into()),
          model: None,
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
          mission_id: Some("mission-1".into()),
          issue_identifier: Some("#1".into()),
          allow_bypass_permissions: false,
          worktree_id: None,
        })),
      }],
    }),
  )
  .await
  .expect("sync batch should succeed");

  assert_eq!(response.acked_through, 1);

  let conn = rusqlite::Connection::open(state.db_path()).unwrap();
  let session_count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE id = 'session-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(session_count, 1);
  let acked: i64 = conn
    .query_row(
      "SELECT sync_acked_through FROM workspaces WHERE id = 'workspace-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert_eq!(acked, 1);
}

#[tokio::test]
async fn post_sync_batch_requires_a_bearer_token() {
  let (state, _token, _guard) = setup_state_with_workspace().await;

  let error = post_sync_batch(
    State(state),
    HeaderMap::new(),
    Json(SyncBatchRequest { commands: vec![] }),
  )
  .await
  .unwrap_err();

  assert_eq!(error.0, StatusCode::UNAUTHORIZED);
  assert_eq!(error.1.code, "missing_bearer_token");
}

#[tokio::test]
async fn post_sync_batch_rejects_sequence_gap() {
  let (state, token, _guard) = setup_state_with_workspace().await;
  let mut headers = HeaderMap::new();
  headers.insert(
    AUTHORIZATION,
    HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
  );

  let error = post_sync_batch(
    State(state),
    headers,
    Json(SyncBatchRequest {
      commands: vec![SyncEnvelope {
        sequence: 2,
        workspace_id: "workspace-1".into(),
        timestamp: crate::support::session_time::chrono_now(),
        command: SyncCommand::SetSummary {
          session_id: "session-1".into(),
          summary: "gap".into(),
        },
      }],
    }),
  )
  .await
  .unwrap_err();

  assert_eq!(error.0, StatusCode::CONFLICT);
  assert_eq!(error.1.code, "sync_sequence_conflict");
}
