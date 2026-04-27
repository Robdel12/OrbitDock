use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

/// Which release channel to check for updates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
  #[default]
  Stable,
  Beta,
  Nightly,
}

impl fmt::Display for UpdateChannel {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match self {
      Self::Stable => write!(f, "stable"),
      Self::Beta => write!(f, "beta"),
      Self::Nightly => write!(f, "nightly"),
    }
  }
}

impl FromStr for UpdateChannel {
  type Err = anyhow::Error;

  fn from_str(s: &str) -> Result<Self, Self::Err> {
    match s.to_lowercase().as_str() {
      "stable" => Ok(Self::Stable),
      "beta" => Ok(Self::Beta),
      "nightly" => Ok(Self::Nightly),
      other => anyhow::bail!("Unknown update channel: {other}. Expected stable, beta, or nightly"),
    }
  }
}

impl UpdateChannel {
  /// Resolve the active update channel from an optional override or persisted config.
  pub fn resolve(override_value: Option<&str>) -> anyhow::Result<Self> {
    match override_value {
      Some(s) => s.parse(),
      None => Ok(
        crate::infrastructure::persistence::load_config_value("update_channel")
          .and_then(|v: String| v.parse::<UpdateChannel>().ok())
          .unwrap_or_default(),
      ),
    }
  }
}

pub fn current_platform_release_asset_name() -> anyhow::Result<&'static str> {
  if cfg!(target_os = "macos") {
    Ok("orbitdock-darwin-arm64.zip")
  } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
    Ok("orbitdock-linux-x86_64.zip")
  } else if cfg!(target_os = "linux") && cfg!(target_arch = "aarch64") {
    Ok("orbitdock-linux-aarch64.zip")
  } else {
    anyhow::bail!(
      "Unsupported platform: {} / {}",
      std::env::consts::OS,
      std::env::consts::ARCH
    );
  }
}

/// A single release from the GitHub Releases API.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseInfo {
  pub tag_name: String,
  pub html_url: String,
  pub published_at: Option<String>,
  pub prerelease: bool,
  pub assets: Vec<ReleaseAsset>,
}

impl ReleaseInfo {
  /// Parse the tag into a semver version (strips leading `v`).
  pub fn version(&self) -> Option<semver::Version> {
    let raw = self.tag_name.strip_prefix('v').unwrap_or(&self.tag_name);
    semver::Version::parse(raw).ok()
  }

  pub fn asset_named(&self, asset_name: &str) -> Option<&ReleaseAsset> {
    self.assets.iter().find(|asset| asset.name == asset_name)
  }
}

/// A downloadable asset attached to a release.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseAsset {
  pub name: String,
  pub browser_download_url: String,
  pub size: u64,
}

/// Result of checking whether an update is available.
#[derive(Debug, Clone, Serialize)]
pub struct UpdateCheckResult {
  pub current_version: String,
  pub latest_version: Option<String>,
  pub update_available: bool,
  pub channel: UpdateChannel,
  pub release_url: Option<String>,
}

#[cfg(test)]
#[path = "types_tests.rs"]
mod tests;
