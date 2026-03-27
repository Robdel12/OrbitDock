use std::sync::Arc;

use tracing::{debug, warn};

use crate::infrastructure::github_releases::client::GitHubReleasesClient;
use crate::infrastructure::github_releases::types::UpdateChannel;
use crate::runtime::session_registry::{CachedUpdateStatus, SessionRegistry};

/// Run a single update check against GitHub Releases.
///
/// When `channel_override` is `Some`, that channel is used directly (avoiding
/// a config read that may race with an in-flight persistence write).
/// Returns `Err` on network/API failures so callers can surface them.
pub async fn run_update_check(
  state: &Arc<SessionRegistry>,
  channel_override: Option<UpdateChannel>,
) -> anyhow::Result<()> {
  if !state.claim_update_check() {
    debug!(
      component = "update_checker",
      "Check already in flight, skipping"
    );
    return Ok(());
  }

  let result = async {
    let channel =
      channel_override.unwrap_or_else(|| UpdateChannel::resolve(None).unwrap_or_default());
    let client = GitHubReleasesClient::new();
    client.check_for_update(channel).await
  }
  .await;

  state.release_update_check();

  let check = result?;

  let previously_known = state.update_status().and_then(|s| s.latest_version);

  let cached = CachedUpdateStatus {
    update_available: check.update_available,
    latest_version: check.latest_version.clone(),
    release_url: check.release_url.clone(),
    channel: check.channel.to_string(),
    checked_at: chrono::Utc::now(),
  };
  state.set_update_status(cached);

  // Broadcast only when a *new* version is first detected
  if check.update_available && check.latest_version != previously_known {
    if let (Some(latest), Some(url)) = (&check.latest_version, &check.release_url) {
      debug!(
        component = "update_checker",
        latest = %latest,
        "Broadcasting update notification"
      );
      state.broadcast_to_list(orbitdock_protocol::ServerMessage::UpdateAvailable {
        current_version: check.current_version.clone(),
        latest_version: latest.clone(),
        release_url: url.clone(),
        channel: check.channel.to_string(),
      });
    }
  }

  Ok(())
}

/// Spawn a one-shot update check after a short startup delay.
pub fn spawn_startup_check(state: Arc<SessionRegistry>) {
  tokio::spawn(async move {
    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
    if let Err(e) = run_update_check(&state, None).await {
      warn!(component = "update_checker", error = %e, "Startup update check failed");
    }
  });
}

/// Trigger an activity-based update check if enough time has passed.
pub fn maybe_trigger_check(state: &Arc<SessionRegistry>) {
  if state.should_recheck_update() {
    let s = state.clone();
    tokio::spawn(async move {
      if let Err(e) = run_update_check(&s, None).await {
        warn!(component = "update_checker", error = %e, "Activity update check failed");
      }
    });
  }
}
