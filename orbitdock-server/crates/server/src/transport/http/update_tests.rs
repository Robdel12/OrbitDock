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
