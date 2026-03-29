use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::infrastructure::github_releases::client::GitHubReleasesClient;
use crate::infrastructure::github_releases::types::{
  current_platform_release_asset_name, ReleaseInfo, UpdateChannel,
};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

/// GET /api/server/update-status — returns the cached update check result (no network call).
pub async fn get_update_status(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<Option<orbitdock_protocol::UpdateStatus>> {
  Json(state.update_status())
}

#[derive(Serialize)]
pub struct CheckUpdateResponse {
  #[serde(flatten)]
  status: Option<orbitdock_protocol::UpdateStatus>,
  #[serde(skip_serializing_if = "Option::is_none")]
  error: Option<String>,
}

/// POST /api/server/check-update — triggers a fresh check (5-min debounce).
/// Returns the check result or an error message if the check failed.
pub async fn check_update(
  State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<CheckUpdateResponse>, (StatusCode, String)> {
  if state.should_recheck_update_manual() {
    if let Err(e) = crate::runtime::background::update_checker::run_update_check(&state, None).await
    {
      return Ok(Json(CheckUpdateResponse {
        status: state.update_status(),
        error: Some(e.to_string()),
      }));
    }
  }

  Ok(Json(CheckUpdateResponse {
    status: state.update_status(),
    error: None,
  }))
}

#[derive(Deserialize)]
pub struct SetUpdateChannelRequest {
  channel: String,
}

/// PUT /api/server/update-channel — sets the channel and triggers a re-check.
/// Passes the new channel directly to the checker to avoid racing the config write.
pub async fn set_update_channel(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetUpdateChannelRequest>,
) -> Result<Json<CheckUpdateResponse>, (StatusCode, String)> {
  let channel: UpdateChannel = body
    .channel
    .parse()
    .map_err(|e: anyhow::Error| (StatusCode::BAD_REQUEST, e.to_string()))?;

  // Persist the channel preference
  let _ = state
    .persist()
    .send(PersistCommand::SetConfig {
      key: "update_channel".to_string(),
      value: channel.to_string(),
    })
    .await;

  // Pass channel directly — don't re-read from DB (avoids race with batched writes)
  let error =
    match crate::runtime::background::update_checker::run_update_check(&state, Some(channel)).await
    {
      Ok(()) => None,
      Err(e) => Some(e.to_string()),
    };

  Ok(Json(CheckUpdateResponse {
    status: state.update_status(),
    error,
  }))
}

/// GET /api/server/update-channel — returns the current update channel.
pub async fn get_update_channel() -> Json<serde_json::Value> {
  let channel = UpdateChannel::resolve(None).unwrap_or_default();
  Json(serde_json::json!({ "channel": channel.to_string() }))
}

fn default_restart_requested() -> bool {
  true
}

#[derive(Debug, Deserialize)]
pub struct StartUpgradeRequest {
  #[serde(default = "default_restart_requested")]
  restart: bool,
  #[serde(default)]
  channel: Option<String>,
  #[serde(default)]
  version: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct StartUpgradeResponse {
  pub accepted: bool,
  pub restart_requested: bool,
  pub channel: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub target_version: Option<String>,
  pub message: String,
}

fn resolve_requested_channel(
  requested_channel: Option<&str>,
  status_channel: Option<&str>,
) -> Result<UpdateChannel, (StatusCode, String)> {
  match requested_channel {
    Some(channel) => channel
      .parse()
      .map_err(|error: anyhow::Error| (StatusCode::BAD_REQUEST, error.to_string())),
    None => UpdateChannel::resolve(status_channel).map_err(|error| {
      (
        StatusCode::INTERNAL_SERVER_ERROR,
        format!("failed to resolve active update channel: {error}"),
      )
    }),
  }
}

fn build_upgrade_command(
  current_exe: &std::path::Path,
  target_release: &ReleaseInfo,
  restart_requested: bool,
) -> std::process::Command {
  let mut command = std::process::Command::new(current_exe);
  command
    .arg("upgrade")
    .arg("--yes")
    .arg("--version")
    .arg(target_release.tag_name.as_str())
    .stdin(std::process::Stdio::null())
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::null());

  if restart_requested {
    command.arg("--restart");
  }

  command
}

/// POST /api/server/start-upgrade — spawns the existing CLI upgrade flow in a
/// detached child process so the current server can keep serving until the
/// upgrader swaps the binary and restarts the service.
pub async fn start_upgrade(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<StartUpgradeRequest>,
) -> Result<Json<StartUpgradeResponse>, (StatusCode, String)> {
  let channel = resolve_requested_channel(
    body.channel.as_deref(),
    state
      .update_status()
      .as_ref()
      .map(|status| status.channel.as_str()),
  )?;

  let current_exe = std::env::current_exe().map_err(|error| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      format!("failed to resolve current binary path: {error}"),
    )
  })?;
  let standard_install_dir = dirs::home_dir()
    .map(|home| home.join(".orbitdock"))
    .unwrap_or_else(|| std::path::PathBuf::from("/usr/local"));

  if !current_exe.starts_with(&standard_install_dir) {
    return Err((
      StatusCode::CONFLICT,
      format!(
        "OrbitDock is running from {} instead of the standard install directory ({}). Upgrade it manually on the host machine.",
        current_exe.display(),
        standard_install_dir.display()
      ),
    ));
  }

  let required_asset_name = current_platform_release_asset_name().map_err(|error| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      format!("failed to resolve current platform asset: {error}"),
    )
  })?;

  let client = GitHubReleasesClient::new();
  let selected_release = if let Some(version) = body.version.as_deref() {
    let normalized_tag = if version.starts_with('v') {
      version.to_string()
    } else {
      format!("v{version}")
    };

    let release = client
      .fetch_release_by_tag(&normalized_tag)
      .await
      .map_err(|error| {
        (
          StatusCode::BAD_GATEWAY,
          format!("failed to look up release {normalized_tag}: {error}"),
        )
      })?;

    let release = release.ok_or_else(|| {
      (
        StatusCode::NOT_FOUND,
        format!("release {normalized_tag} was not found on GitHub Releases"),
      )
    })?;

    if release.asset_named(required_asset_name).is_none() {
      return Err((
        StatusCode::CONFLICT,
        format!(
          "Release {} does not include the server binary '{}' for this platform.",
          release.tag_name, required_asset_name
        ),
      ));
    }

    Some(release)
  } else {
    let release = client
      .fetch_latest_release(channel)
      .await
      .map_err(|error| {
        (
          StatusCode::BAD_GATEWAY,
          format!("failed to check installable releases for channel {channel}: {error}"),
        )
      })?;

    let release = release.ok_or_else(|| {
      (
        StatusCode::CONFLICT,
        format!(
          "No installable OrbitDock server release is available for the {} channel on this platform.",
          channel
        ),
      )
    })?;

    Some(release)
  };

  let target_release = selected_release.ok_or_else(|| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      "failed to resolve installable release".to_string(),
    )
  })?;

  let child = build_upgrade_command(&current_exe, &target_release, body.restart)
    .spawn()
    .map_err(|error| {
      (
        StatusCode::INTERNAL_SERVER_ERROR,
        format!("failed to start background upgrade: {error}"),
      )
    })?;

  info!(
    component = "update",
    event = "api.server.start_upgrade",
    pid = child.id(),
    restart_requested = body.restart,
    channel = %channel,
    "Spawned background server upgrade"
  );

  Ok(Json(StartUpgradeResponse {
    accepted: true,
    restart_requested: body.restart,
    channel: channel.to_string(),
    target_version: Some(target_release.tag_name.clone()),
    message: if body.restart {
      "Upgrade started. OrbitDock will try to restart the service automatically when the new binary is installed.".to_string()
    } else {
      "Upgrade started. Restart the OrbitDock server process after the new binary is installed."
        .to_string()
    },
  }))
}

#[cfg(test)]
mod tests {
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
}
