use reqwest::{Client, Response};
use tracing::debug;

use super::types::{
  current_platform_release_asset_name, ReleaseAsset, ReleaseInfo, UpdateChannel, UpdateCheckResult,
};
use crate::VERSION;

const REPO_SLUG: &str = "Robdel12/OrbitDock";

/// Lightweight client for the GitHub Releases REST API.
///
/// No authentication required — OrbitDock is a public repo.
/// Unauthenticated rate limit: 60 requests/hour.
pub struct GitHubReleasesClient {
  http: Client,
}

/// Raw release object from the GitHub API (only the fields we need).
#[derive(Clone, serde::Deserialize)]
struct GitHubRelease {
  tag_name: String,
  html_url: String,
  published_at: Option<String>,
  prerelease: bool,
  assets: Vec<GitHubAsset>,
}

#[derive(Clone, serde::Deserialize)]
struct GitHubAsset {
  name: String,
  browser_download_url: String,
  size: u64,
}

impl From<GitHubRelease> for ReleaseInfo {
  fn from(r: GitHubRelease) -> Self {
    ReleaseInfo {
      tag_name: r.tag_name,
      html_url: r.html_url,
      published_at: r.published_at,
      prerelease: r.prerelease,
      assets: r
        .assets
        .into_iter()
        .map(|a| ReleaseAsset {
          name: a.name,
          browser_download_url: a.browser_download_url,
          size: a.size,
        })
        .collect(),
    }
  }
}

fn check_rate_limit(resp: &Response) -> anyhow::Result<()> {
  let remaining = resp
    .headers()
    .get("x-ratelimit-remaining")
    .and_then(|v| v.to_str().ok())
    .and_then(|v| v.parse::<u64>().ok());

  let reset = resp
    .headers()
    .get("x-ratelimit-reset")
    .and_then(|v| v.to_str().ok())
    .and_then(|v| v.parse::<u64>().ok());

  if let Some(rem) = remaining {
    if rem < 10 {
      tracing::warn!(
        component = "github_releases",
        remaining = rem,
        reset_epoch = reset.unwrap_or(0),
        "GitHub API rate limit nearly exhausted"
      );
    }
  }

  if resp.status() == reqwest::StatusCode::FORBIDDEN {
    if let Some(rem) = remaining {
      if rem == 0 {
        let reset_msg = reset
          .map(|r| format!(" (resets at epoch {r})"))
          .unwrap_or_default();
        anyhow::bail!("GitHub API rate limit exceeded{reset_msg}");
      }
    }
  }

  Ok(())
}

impl GitHubReleasesClient {
  pub fn new() -> Self {
    Self {
      http: Client::new(),
    }
  }

  /// Access the inner HTTP client (for asset downloads).
  pub fn http(&self) -> &Client {
    &self.http
  }

  /// Fetch the latest release matching the given channel.
  pub async fn fetch_latest_release(
    &self,
    channel: UpdateChannel,
  ) -> anyhow::Result<Option<ReleaseInfo>> {
    let url = format!("https://api.github.com/repos/{REPO_SLUG}/releases");

    let resp = self
      .http
      .get(&url)
      .header("User-Agent", format!("orbitdock/{VERSION}"))
      .header("Accept", "application/vnd.github+json")
      .query(&[("per_page", "30")])
      .send()
      .await?;

    check_rate_limit(&resp)?;

    let status = resp.status();
    if !status.is_success() {
      let text = resp.text().await.unwrap_or_default();
      anyhow::bail!("GitHub API returned {status}: {text}");
    }

    let releases: Vec<GitHubRelease> = resp.json().await?;
    let required_asset_name = current_platform_release_asset_name()?;
    let matching = latest_matching_release(&releases, channel, required_asset_name);

    debug!(
      component = "github_releases",
      channel = %channel,
      required_asset_name,
      release = matching.map(|release| release.tag_name.as_str()).unwrap_or("none"),
      "Selected latest installable release"
    );

    Ok(matching.cloned().map(ReleaseInfo::from))
  }

  /// Fetch a specific release by tag name (e.g. "v0.6.0").
  pub async fn fetch_release_by_tag(&self, tag: &str) -> anyhow::Result<Option<ReleaseInfo>> {
    let url = format!("https://api.github.com/repos/{REPO_SLUG}/releases/tags/{tag}");

    let resp = self
      .http
      .get(&url)
      .header("User-Agent", format!("orbitdock/{VERSION}"))
      .header("Accept", "application/vnd.github+json")
      .send()
      .await?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
      return Ok(None);
    }

    check_rate_limit(&resp)?;

    let status = resp.status();
    if !status.is_success() {
      let text = resp.text().await.unwrap_or_default();
      anyhow::bail!("GitHub API returned {status}: {text}");
    }

    let r: GitHubRelease = resp.json().await?;
    Ok(Some(ReleaseInfo::from(r)))
  }

  /// Check whether an update is available for the current binary.
  pub async fn check_for_update(
    &self,
    channel: UpdateChannel,
  ) -> anyhow::Result<UpdateCheckResult> {
    let current = semver::Version::parse(VERSION)
      .map_err(|e| anyhow::anyhow!("Failed to parse current version '{VERSION}': {e}"))?;

    let latest_release = self.fetch_latest_release(channel).await?;

    let (update_available, latest_version, release_url) = match &latest_release {
      Some(release) => {
        let available = match release.version() {
          Some(latest_ver) => is_update(&current, &latest_ver, channel),
          None if channel == UpdateChannel::Nightly => true,
          None => false,
        };

        (
          available,
          Some(release.tag_name.clone()),
          Some(release.html_url.clone()),
        )
      }
      None => (false, None, None),
    };

    debug!(
      component = "github_releases",
      current = %current,
      latest = latest_version.as_deref().unwrap_or("none"),
      channel = %channel,
      update_available,
      "Update check complete"
    );

    Ok(UpdateCheckResult {
      current_version: current.to_string(),
      latest_version,
      update_available,
      channel,
      release_url,
    })
  }
}

fn latest_matching_release<'a>(
  releases: &'a [GitHubRelease],
  channel: UpdateChannel,
  required_asset_name: &str,
) -> Option<&'a GitHubRelease> {
  releases.iter().find(|release| {
    matches_channel(release, channel)
      && release
        .assets
        .iter()
        .any(|asset| asset.name == required_asset_name)
  })
}

fn matches_channel(release: &GitHubRelease, channel: UpdateChannel) -> bool {
  match channel {
    UpdateChannel::Stable => !release.prerelease,
    UpdateChannel::Beta => release.prerelease && release.tag_name.contains("-beta"),
    UpdateChannel::Nightly => {
      release.tag_name == "nightly" || (release.prerelease && release.tag_name.contains("-nightly"))
    }
  }
}

fn is_update(current: &semver::Version, latest: &semver::Version, channel: UpdateChannel) -> bool {
  match channel {
    UpdateChannel::Stable => latest > current && latest.pre.is_empty(),
    UpdateChannel::Beta | UpdateChannel::Nightly => latest > current,
  }
}

#[cfg(test)]
mod tests {
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
}
