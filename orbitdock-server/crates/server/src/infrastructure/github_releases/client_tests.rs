use super::*;

fn release(tag: &str, prerelease: bool) -> GitHubRelease {
  release_with_assets(tag, prerelease, &[])
}

fn release_with_assets(tag: &str, prerelease: bool, assets: &[&str]) -> GitHubRelease {
  GitHubRelease {
    tag_name: tag.to_string(),
    html_url: format!("https://github.com/{REPO_SLUG}/releases/tag/{tag}"),
    published_at: None,
    prerelease,
    assets: assets
      .iter()
      .map(|name| GitHubAsset {
        name: (*name).to_string(),
        browser_download_url: format!("https://example.com/{name}"),
        size: 1,
      })
      .collect(),
  }
}

#[test]
fn stable_matches_non_prerelease() {
  assert!(matches_channel(
    &release("v0.7.0", false),
    UpdateChannel::Stable
  ));
  assert!(!matches_channel(
    &release("v0.7.0-beta.1", true),
    UpdateChannel::Stable
  ));
}

#[test]
fn beta_matches_beta_prerelease() {
  assert!(matches_channel(
    &release("v0.7.0-beta.1", true),
    UpdateChannel::Beta
  ));
  assert!(!matches_channel(
    &release("v0.7.0", false),
    UpdateChannel::Beta
  ));
  assert!(!matches_channel(
    &release("nightly", true),
    UpdateChannel::Beta
  ));
}

#[test]
fn nightly_matches_nightly() {
  assert!(matches_channel(
    &release("nightly", true),
    UpdateChannel::Nightly
  ));
  assert!(matches_channel(
    &release("v0.7.0-nightly.20260327", true),
    UpdateChannel::Nightly
  ));
  assert!(!matches_channel(
    &release("v0.7.0", false),
    UpdateChannel::Nightly
  ));
}

#[test]
fn stable_update_check() {
  let current = semver::Version::new(0, 6, 0);
  let newer = semver::Version::new(0, 7, 0);
  let older = semver::Version::new(0, 5, 0);
  let same = semver::Version::new(0, 6, 0);
  let beta = semver::Version::parse("0.7.0-beta.1").unwrap();

  assert!(is_update(&current, &newer, UpdateChannel::Stable));
  assert!(!is_update(&current, &older, UpdateChannel::Stable));
  assert!(!is_update(&current, &same, UpdateChannel::Stable));
  assert!(!is_update(&current, &beta, UpdateChannel::Stable));
}

#[test]
fn beta_update_check() {
  let current = semver::Version::new(0, 6, 0);
  let beta = semver::Version::parse("0.7.0-beta.1").unwrap();

  assert!(is_update(&current, &beta, UpdateChannel::Beta));
}

#[test]
fn latest_matching_release_skips_binary_less_tags() {
  let releases = vec![
    release("v0.7.0", false),
    release_with_assets("v0.6.1", false, &["orbitdock-darwin-arm64.zip"]),
  ];

  let selected = latest_matching_release(
    &releases,
    UpdateChannel::Stable,
    "orbitdock-darwin-arm64.zip",
  )
  .unwrap();

  assert_eq!(selected.tag_name, "v0.6.1");
}

#[test]
fn latest_matching_release_returns_none_when_no_installable_asset_exists() {
  let releases = vec![release("v0.7.0", false), release("v0.6.1", false)];

  let selected = latest_matching_release(
    &releases,
    UpdateChannel::Stable,
    "orbitdock-darwin-arm64.zip",
  );

  assert!(selected.is_none());
}
