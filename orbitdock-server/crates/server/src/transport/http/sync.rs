use std::sync::Arc;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use serde::Serialize;

use crate::infrastructure::{
    auth_tokens,
    persistence::{
        apply_workspace_sync_batch, resolve_workspace_sync_target, update_workspace_heartbeat,
        SyncBatchRequest,
    },
};
use crate::runtime::{
    mission_orchestrator::broadcast_mission_delta_by_id, session_registry::SessionRegistry,
};

use super::errors::{api_error, conflict, internal, ApiResult};

#[derive(Debug, Serialize)]
pub struct SyncBatchAckResponse {
    pub acked_through: u64,
}

pub async fn post_sync_batch(
    State(registry): State<Arc<SessionRegistry>>,
    headers: HeaderMap,
    Json(request): Json<SyncBatchRequest>,
) -> ApiResult<SyncBatchAckResponse> {
    let token = extract_bearer_token(&headers).ok_or_else(|| {
        api_error(
            StatusCode::UNAUTHORIZED,
            "missing_bearer_token",
            "Authorization header with Bearer token is required",
        )
    })?;

    let token_id = auth_tokens::resolve_active_token_id(token)
        .map_err(|error| {
            internal(
                "token_lookup_failed",
                format!("token lookup failed: {error}"),
            )
        })?
        .ok_or_else(|| {
            api_error(
                StatusCode::UNAUTHORIZED,
                "invalid_workspace_token",
                "Workspace sync token is invalid or expired",
            )
        })?;

    let db_path = registry.db_path().clone();
    let request_clone = request.clone();
    let token_id_clone = token_id.clone();
    let outcome = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
        let mut conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA synchronous = NORMAL;",
        )?;

        let target = resolve_workspace_sync_target(&conn, &token_id_clone)?
            .ok_or_else(|| anyhow::anyhow!("workspace token is not assigned to a workspace"))?;

        let apply_result =
            match apply_workspace_sync_batch(&mut conn, &target, &request_clone.commands) {
                Ok(result) => result,
                Err(error) => {
                    if error.to_string().contains("sequence gap")
                        || error.to_string().contains("batch overlaps already-acked")
                    {
                        update_workspace_heartbeat(&conn, &target.workspace_id)?;
                    }
                    return Err(error);
                }
            };

        Ok((apply_result, target.workspace_id))
    })
    .await
    .map_err(|error| internal("sync_join_failed", format!("sync join failed: {error}")))?;

    let (apply_result, _workspace_id) = match outcome {
        Ok(result) => result,
        Err(error) => {
            let message = error.to_string();
            if message.contains("workspace token is not assigned") {
                return Err(api_error(
                    StatusCode::UNAUTHORIZED,
                    "workspace_not_found",
                    "Workspace token is not assigned to an active workspace",
                ));
            }
            if message.contains("sequence gap")
                || message.contains("batch overlaps already-acked")
                || message.contains("non-contiguous sequence")
                || message.contains("workspace mismatch")
            {
                return Err(conflict("sync_sequence_conflict", message));
            }
            return Err(internal("sync_apply_failed", message));
        }
    };

    if !request.commands.is_empty() {
        registry.publish_dashboard_snapshot();
    }
    for mission_id in &apply_result.touched_mission_ids {
        broadcast_mission_delta_by_id(&registry, mission_id).await;
    }

    Ok(Json(SyncBatchAckResponse {
        acked_through: apply_result.acked_through,
    }))
}

fn extract_bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{header::AUTHORIZATION, HeaderValue};
    use orbitdock_protocol::{Provider, SessionControlMode};

    use crate::infrastructure::{
        auth_tokens,
        persistence::{SyncCommand, SyncEnvelope, SyncSessionCreateParams},
    };
    use crate::support::test_support::test_env_lock;
    use crate::transport::http::test_support::ensure_test_db;

    fn setup_state_with_workspace() -> (Arc<SessionRegistry>, String) {
        let _guard = test_env_lock().lock().expect("lock shared test env");
        let db_path = ensure_test_db();
        let issued = auth_tokens::issue_token(Some("workspace-sync")).expect("issue token");
        {
            let conn = rusqlite::Connection::open(&db_path).expect("open db");
            conn.execute(
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
            conn.execute(
                "INSERT INTO workspaces (id, mission_issue_id, branch, sync_token)
                 VALUES ('workspace-1', 'mi-1', 'mission/issue-1', ?1)",
                rusqlite::params![issued.id],
            )
            .unwrap();
        }

        let (persist_tx, _persist_rx) = tokio::sync::mpsc::channel(8);
        (
            Arc::new(SessionRegistry::new_with_primary_and_db_path(
                persist_tx, db_path, true,
            )),
            issued.token,
        )
    }

    #[tokio::test]
    async fn post_sync_batch_applies_batch_and_returns_ack() {
        let (state, token) = setup_state_with_workspace();
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
    async fn post_sync_batch_rejects_sequence_gap() {
        let (state, token) = setup_state_with_workspace();
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
}
