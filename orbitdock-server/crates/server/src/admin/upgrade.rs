use crate::infrastructure::github_releases::client::GitHubReleasesClient;
use crate::infrastructure::github_releases::types::UpdateChannel;

pub fn check_for_update(json_output: bool, channel_override: Option<String>) -> anyhow::Result<()> {
  let channel = UpdateChannel::resolve(channel_override.as_deref())?;

  let runtime = tokio::runtime::Runtime::new()?;
  let result = runtime.block_on(async {
    let client = GitHubReleasesClient::new();
    client.check_for_update(channel).await
  })?;

  if json_output {
    println!("{}", serde_json::to_string_pretty(&result)?);
    return Ok(());
  }

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
