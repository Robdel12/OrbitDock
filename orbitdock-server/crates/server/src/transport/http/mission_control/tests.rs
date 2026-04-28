use std::{
  fs,
  path::{Path, PathBuf},
};

use axum::{extract::Path as AxumPath, extract::State, Json};
use orbitdock_protocol::Provider;
use rusqlite::{params, Connection};

use crate::{
  infrastructure::persistence::{flush_batch_for_test, load_config_value, PersistCommand},
  transport::http::test_support::new_persist_test_state,
};

use super::{
  create_mission, delete_linear_key, delete_mission, get_mission, get_tracker_keys, list_missions,
  set_linear_key, slugify_mission_name, update_mission, update_mission_defaults,
  CreateMissionRequest, UpdateMissionRequest,
};
use super::{defaults::UpdateMissionDefaultsRequest, tracker_keys::SetLinearKeyRequest};

fn make_git_repo_root() -> PathBuf {
  let repo_root = std::env::temp_dir().join(format!(
    "orbitdock-mission-control-{}",
    orbitdock_protocol::new_id()
  ));
  fs::create_dir_all(repo_root.join(".git")).expect("create git repo root");
  repo_root
}

fn load_mission_row(
  db_path: &Path,
  mission_id: &str,
) -> Option<(String, bool, bool, Option<String>, String)> {
  let conn = Connection::open(db_path).expect("open mission test db");
  conn
    .query_row(
      "SELECT name, enabled, paused, mission_file_path, provider FROM missions WHERE id = ?1",
      params![mission_id],
      |row| {
        let name: String = row.get(0)?;
        let enabled: i64 = row.get(1)?;
        let paused: i64 = row.get(2)?;
        let mission_file_path = row.get(3)?;
        let provider = row.get(4)?;
        Ok((name, enabled != 0, paused != 0, mission_file_path, provider))
      },
    )
    .ok()
}

fn spawn_persist_consumer(
  mut persist_rx: tokio::sync::mpsc::Receiver<PersistCommand>,
  db_path: PathBuf,
) -> tokio::task::JoinHandle<()> {
  tokio::spawn(async move {
    let mut batch = Vec::new();

    while let Some(command) = persist_rx.recv().await {
      match command {
        PersistCommand::Flush { ack } => {
          let flush_result = if !batch.is_empty() {
            flush_batch_for_test(&db_path, std::mem::take(&mut batch)).map(|_| ())
          } else {
            Ok(())
          };
          let _ = ack.send(());
          flush_result.expect("flush mission persistence batch");
        }
        other => batch.push(other),
      }
    }

    if !batch.is_empty() {
      flush_batch_for_test(&db_path, batch).expect("flush trailing mission persistence batch");
    }
  })
}

#[test]
fn slugify_mission_name_normalizes_user_visible_inputs() {
  let cases = [
    ("My Mission", "my-mission"),
    ("OrbitDock (v2)", "orbitdock-v2"),
    ("  test  ", "test"),
    ("a---b", "a-b"),
    ("café project", "café-project"),
    ("simple", "simple"),
    ("", ""),
    ("OrbitDock GitHub", "orbitdock-github"),
    ("hello@world.com #1", "hello-world-com-1"),
    ("---!!!---", ""),
  ];
  for (input, expected) in cases {
    assert_eq!(slugify_mission_name(input), expected, "input: {input:?}");
  }
}

#[tokio::test]
async fn create_update_delete_mission_workflow_persists_and_round_trips() {
  let (state, persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let _writer = spawn_persist_consumer(persist_rx, db_path.clone());
  let repo_root = make_git_repo_root();
  let repo_root_str = repo_root.to_string_lossy().into_owned();

  let Json(created) = create_mission(
    State(state.clone()),
    Json(CreateMissionRequest {
      name: "Mission Alpha".to_string(),
      repo_root: repo_root_str.clone(),
      tracker_kind: "linear".to_string(),
      provider: " Claude ".to_string(),
    }),
  )
  .await
  .expect("create mission should succeed");

  assert_eq!(created.name, "Mission Alpha");
  assert_eq!(created.repo_root, repo_root_str);
  assert_eq!(created.provider_strategy, "single");
  assert_eq!(created.primary_provider, Provider::Claude);
  assert_eq!(created.mission_file_path.as_deref(), Some("MISSION.md"));

  let Json(snapshot) = list_missions(State(state.clone()))
    .await
    .expect("list missions should succeed");
  assert_eq!(snapshot.missions.len(), 1);
  assert_eq!(snapshot.missions[0].id, created.id);
  assert_eq!(snapshot.missions[0].name, "Mission Alpha");
  assert_eq!(
    snapshot.missions[0].mission_file_path.as_deref(),
    Some("MISSION.md")
  );

  let Json(detail) = get_mission(State(state.clone()), AxumPath(created.id.clone()))
    .await
    .expect("get mission should succeed");
  assert_eq!(detail.summary.id, created.id);
  assert_eq!(detail.summary.name, "Mission Alpha");
  assert_eq!(
    detail.summary.mission_file_path.as_deref(),
    Some("MISSION.md")
  );
  assert!(!detail.mission_file_exists);
  assert!(detail.issues.is_empty());

  let Json(updated) = update_mission(
    State(state.clone()),
    AxumPath(created.id.clone()),
    Json(UpdateMissionRequest {
      name: Some("Mission Beta".to_string()),
      enabled: Some(false),
      paused: Some(true),
      mission_file_path: Some(Some("MISSION-beta.md".to_string())),
    }),
  )
  .await
  .expect("update mission should succeed");

  assert_eq!(updated.summary.id, created.id);
  assert_eq!(updated.summary.name, "Mission Beta");
  assert!(!updated.summary.enabled);
  assert!(updated.summary.paused);
  assert_eq!(
    updated.summary.mission_file_path.as_deref(),
    Some("MISSION-beta.md")
  );

  let stored_after_update =
    load_mission_row(&db_path, &created.id).expect("mission should be persisted after update");
  assert_eq!(stored_after_update.0, "Mission Beta");
  assert!(!stored_after_update.1);
  assert!(stored_after_update.2);
  assert_eq!(stored_after_update.3.as_deref(), Some("MISSION-beta.md"));
  assert_eq!(stored_after_update.4, "claude");

  let Json(remaining) = delete_mission(State(state.clone()), AxumPath(created.id.clone()))
    .await
    .expect("delete mission should succeed");
  assert!(remaining.missions.is_empty());

  assert!(load_mission_row(&db_path, &created.id).is_none());
}

#[tokio::test]
async fn create_mission_rejects_invalid_provider_without_persisting() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let repo_root = make_git_repo_root();
  let repo_root_str = repo_root.to_string_lossy().into_owned();

  let error = create_mission(
    State(state),
    Json(CreateMissionRequest {
      name: "Broken Mission".to_string(),
      repo_root: repo_root_str.clone(),
      tracker_kind: "linear".to_string(),
      provider: "not-a-real-provider".to_string(),
    }),
  )
  .await
  .unwrap_err();

  assert_eq!(error.0, axum::http::StatusCode::BAD_REQUEST);
  assert_eq!(error.1.code, "invalid_provider");

  let conn = Connection::open(&db_path).expect("open mission test db");
  let count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM missions WHERE repo_root = ?1",
      params![repo_root_str],
      |row| row.get(0),
    )
    .expect("count missions for repo root");
  assert_eq!(count, 0);
}

#[tokio::test]
async fn delete_linear_key_removes_global_config_and_updates_status() {
  let (state, persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  crate::infrastructure::crypto::ensure_key();
  let _writer = spawn_persist_consumer(persist_rx, db_path.clone());
  let env_key_present = std::env::var("LINEAR_API_KEY")
    .ok()
    .map(|value| !value.trim().is_empty())
    .unwrap_or(false);

  let Json(saved) = set_linear_key(
    State(state.clone()),
    Json(SetLinearKeyRequest {
      key: "lin_test_key".to_string(),
    }),
  )
  .await
  .expect("set linear key should succeed");
  assert!(saved.configured);
  assert_eq!(
    load_config_value("linear_api_key").as_deref(),
    Some("lin_test_key")
  );

  let Json(status) = get_tracker_keys().await;
  assert!(status.linear.configured);
  assert_eq!(status.linear.source.as_deref(), Some("settings"));

  let Json(deleted) = delete_linear_key(State(state.clone()))
    .await
    .expect("delete linear key should succeed");
  assert!(!deleted.configured);
  assert!(load_config_value("linear_api_key").is_none());

  let Json(status) = get_tracker_keys().await;
  if env_key_present {
    assert!(status.linear.configured);
    assert_eq!(status.linear.source.as_deref(), Some("env"));
  } else {
    assert!(!status.linear.configured);
    assert_eq!(status.linear.source, None);
  }
}

#[tokio::test]
async fn clearing_secondary_mission_default_returns_authoritative_state() {
  let (state, persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  crate::infrastructure::crypto::ensure_key();
  let _writer = spawn_persist_consumer(persist_rx, db_path.clone());

  let Json(saved) = update_mission_defaults(
    State(state.clone()),
    Json(UpdateMissionDefaultsRequest {
      provider_strategy: Some("dual".to_string()),
      primary_provider: Some("claude".to_string()),
      secondary_provider: Some(Some("codex".to_string())),
    }),
  )
  .await
  .expect("set mission defaults should succeed");
  assert_eq!(saved.secondary_provider.as_deref(), Some("codex"));

  let Json(cleared) = update_mission_defaults(
    State(state.clone()),
    Json(UpdateMissionDefaultsRequest {
      provider_strategy: None,
      primary_provider: None,
      secondary_provider: Some(Some(String::new())),
    }),
  )
  .await
  .expect("clear mission secondary default should succeed");

  assert_eq!(cleared.provider_strategy, "dual");
  assert_eq!(cleared.primary_provider, "claude");
  assert_eq!(cleared.secondary_provider, None);
  assert!(load_config_value("mission_default_secondary").is_none());
}
