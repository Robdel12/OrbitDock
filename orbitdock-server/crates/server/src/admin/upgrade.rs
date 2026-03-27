use crate::infrastructure::github_releases::client::GitHubReleasesClient;
use crate::infrastructure::github_releases::types::UpdateChannel;
use crate::infrastructure::persistence::load_config_value;

/// Check for available updates and print the result.
///
/// This is an admin command — it runs before the server starts and exits
/// immediately after printing.
pub fn check_for_update(json_output: bool, channel_override: Option<String>) -> anyhow::Result<()> {
  let channel = match channel_override {
    Some(ref s) => s.parse::<UpdateChannel>()?,
    None => load_config_value("update_channel")
      .and_then(|v: String| v.parse::<UpdateChannel>().ok())
      .unwrap_or_default(),
  };

  let runtime = tokio::runtime::Runtime::new()?;
  let result = runtime.block_on(async {
    let client = GitHubReleasesClient::new();
    client.check_for_update(channel).await
  })?;

  if json_output {
    println!("{}", serde_json::to_string_pretty(&result)?);
    return Ok(());
  }

  // Human-friendly output
  println!("→ Checking for updates (channel: {})...", result.channel);

  if result.update_available {
    println!(
      "✓ Update available: v{} → {}",
      result.current_version,
      result.latest_version.as_deref().unwrap_or("unknown")
    );
    if let Some(url) = &result.release_url {
      println!("  {url}");
    }
  } else {
    println!(
      "✓ Already up to date (v{}, channel: {})",
      result.current_version, result.channel
    );
  }

  Ok(())
}
