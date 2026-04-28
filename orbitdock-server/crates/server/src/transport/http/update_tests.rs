use axum::{extract::State, Json};
use serde_json::json;

use crate::{
  infrastructure::persistence::{flush_batch_for_test, PersistCommand},
  runtime::session_registry::CachedUpdateStatus,
  transport::http::test_support::new_persist_test_state,
};

use super::*;
use crate::infrastructure::github_releases::types::ReleaseAsset;

fn release(tag_name: &str) -> ReleaseInfo {
  ReleaseInfo {
    tag_name: tag_name.to_string(),
    html_url: "https://example.test/release".to_string(),
    published_at: None,
    prerelease: false,
    assets: vec![ReleaseAsset {
      name: "orbitdock-darwin-arm64.zip".to_string(),
      browser_download_url: "https://example.test/orbitdock.zip".to_string(),
      size: 1,
    }],
  }
}

#[test]
fn resolve_requested_channel_rejects_invalid_override() {
  let error = resolve_requested_channel(Some("betaa"), Some("stable"))
    .expect_err("invalid channel should be rejected");

  assert_eq!(error.0, StatusCode::BAD_REQUEST);
  assert!(error.1.contains("Unknown update channel"));
}

#[test]
fn resolve_requested_channel_falls_back_to_status_channel() {
  let channel = resolve_requested_channel(None, Some("beta")).expect("status channel resolves");
  assert_eq!(channel, UpdateChannel::Beta);
}

#[test]
fn build_upgrade_command_pins_selected_release_tag() {
  let command = build_upgrade_command(
    std::path::Path::new("/tmp/orbitdock"),
    &release("v1.2.3"),
    true,
  );

  let args = command
    .get_args()
    .map(|arg| arg.to_string_lossy().into_owned())
    .collect::<Vec<_>>();

  assert_eq!(
    args,
    vec![
      "upgrade".to_string(),
      "--yes".to_string(),
      "--version".to_string(),
      "v1.2.3".to_string(),
      "--restart".to_string(),
    ]
  );
}

#[tokio::test]
async fn update_status_endpoint_returns_cached_status_and_check_update_reuses_it() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;
  state.set_update_status(CachedUpdateStatus {
    update_available: true,
    latest_version: Some("v1.2.3".to_string()),
    release_url: Some("https://example.test/releases/v1.2.3".to_string()),
    channel: "beta".to_string(),
    checked_at: chrono::Utc::now(),
  });

  let Json(status) = get_update_status(State(state.clone())).await;
  let status = status.expect("cached status should be present");
  assert!(status.update_available);
  assert_eq!(status.latest_version.as_deref(), Some("v1.2.3"));
  assert_eq!(
    status.release_url.as_deref(),
    Some("https://example.test/releases/v1.2.3")
  );
  assert_eq!(status.channel, "beta");

  let Json(response) = check_update(State(state))
    .await
    .expect("check update should succeed");
  assert!(response.error.is_none());
  let response_status = response
    .status
    .expect("check update should reuse cached status");
  assert!(response_status.update_available);
  assert_eq!(response_status.latest_version.as_deref(), Some("v1.2.3"));
}

#[tokio::test]
async fn update_channel_endpoint_reads_persisted_setting() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  crate::infrastructure::crypto::ensure_key();
  flush_batch_for_test(
    &db_path,
    vec![PersistCommand::SetConfig {
      key: "update_channel".to_string(),
      value: "beta".to_string(),
    }],
  )
  .expect("persist update channel fixture");

  let Json(value) = get_update_channel(State(state)).await;
  assert_eq!(value, json!({ "channel": "beta" }));
}
