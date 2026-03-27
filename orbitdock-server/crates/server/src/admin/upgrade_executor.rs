use std::fs;
use std::io::{Read as IoRead, Write as IoWrite};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use crate::infrastructure::github_releases::client::GitHubReleasesClient;
use crate::infrastructure::github_releases::types::{ReleaseAsset, UpdateChannel};
use crate::infrastructure::paths::upgrade_tmp_dir;
use crate::VERSION;

pub struct UpgradeOptions {
  pub channel_override: Option<String>,
  pub target_version: Option<String>,
  pub force: bool,
  pub yes: bool,
  pub restart: bool,
}

const LAUNCHD_PLIST: &str = "Library/LaunchAgents/com.orbitdock.server.plist";
const SYSTEMD_UNIT: &str = ".config/systemd/user/orbitdock-server.service";

pub fn execute_upgrade(opts: UpgradeOptions) -> anyhow::Result<()> {
  let runtime = tokio::runtime::Runtime::new()?;
  runtime.block_on(execute_upgrade_async(opts))
}

async fn execute_upgrade_async(opts: UpgradeOptions) -> anyhow::Result<()> {
  let channel = UpdateChannel::resolve(opts.channel_override.as_deref())?;

  let current_exe = std::env::current_exe()?.canonicalize()?;
  let install_dir = default_install_dir();

  if !current_exe.starts_with(&install_dir) && !opts.force {
    anyhow::bail!(
      "Binary is at {} which is outside the standard install location ({}). \
       Use --force to upgrade anyway.",
      current_exe.display(),
      install_dir.display()
    );
  }

  let client = GitHubReleasesClient::new();
  let release = if let Some(ref tag) = opts.target_version {
    let tag_with_v = if tag.starts_with('v') {
      tag.clone()
    } else {
      format!("v{tag}")
    };
    client.fetch_release_by_tag(&tag_with_v).await?
  } else {
    client.fetch_latest_release(channel).await?
  };

  let release = match release {
    Some(r) => r,
    None => {
      println!("✓ No releases found for channel: {channel}");
      return Ok(());
    }
  };

  let current = semver::Version::parse(VERSION)?;
  let skip = match release.version() {
    Some(ref latest) => !opts.force && latest <= &current,
    None => false,
  };

  if skip {
    println!("✓ Already up to date (v{VERSION}, channel: {channel})");
    return Ok(());
  }

  let asset_name = platform_asset_name()?;
  let checksum_name = format!("{asset_name}.sha256");

  let zip_asset = release
    .assets
    .iter()
    .find(|a| a.name == asset_name)
    .ok_or_else(|| {
      anyhow::anyhow!(
        "No server binary asset '{asset_name}' found on release {}. \
         This release may not include server binaries.",
        release.tag_name
      )
    })?;

  let checksum_asset = release.assets.iter().find(|a| a.name == checksum_name);

  println!(
    "→ Upgrade: v{VERSION} → {} (channel: {channel})",
    release.tag_name
  );
  println!("  Asset: {asset_name} ({} MB)", zip_asset.size / 1_000_000);

  if !opts.yes {
    print!("  Continue? [y/N] ");
    std::io::stdout().flush()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    if !input.trim().eq_ignore_ascii_case("y") {
      println!("  Cancelled.");
      return Ok(());
    }
  }

  let tmp_dir = upgrade_tmp_dir();
  if tmp_dir.exists() {
    fs::remove_dir_all(&tmp_dir)?;
  }
  fs::create_dir_all(&tmp_dir)?;

  let zip_path = tmp_dir.join(&asset_name);
  let checksum_path = tmp_dir.join(&checksum_name);

  // Download zip and checksum concurrently
  println!("  Downloading {asset_name}...");
  let http = client.http();
  match checksum_asset {
    Some(cs_asset) => {
      let (zip_result, cs_result) = tokio::join!(
        stream_download(http, zip_asset, &zip_path),
        stream_download(http, cs_asset, &checksum_path),
      );
      zip_result?;
      cs_result?;
    }
    None => {
      stream_download(http, zip_asset, &zip_path).await?;
    }
  }

  if checksum_path.exists() {
    print!("  Verifying checksum...");
    verify_checksum(&zip_path, &checksum_path)?;
    println!(" ✓");
  } else {
    println!("  ⚠ No checksum file available — skipping verification");
  }

  print!("  Extracting...");
  let extracted_binary = extract_binary(&zip_path, &tmp_dir)?;
  println!(" ✓");

  let backup_path = current_exe.with_extension("bak");
  print!("  Swapping binary...");

  #[cfg(unix)]
  {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&extracted_binary, fs::Permissions::from_mode(0o755))?;
  }

  if backup_path.exists() {
    fs::remove_file(&backup_path)?;
  }
  fs::rename(&current_exe, &backup_path)?;

  if let Err(e) = fs::rename(&extracted_binary, &current_exe) {
    let _ = fs::rename(&backup_path, &current_exe);
    anyhow::bail!("Failed to install new binary: {e}");
  }
  println!(" ✓");

  print!("  Verifying new binary...");
  let output = std::process::Command::new(&current_exe)
    .arg("--version")
    .output()?;

  if !output.status.success() {
    let _ = fs::rename(&backup_path, &current_exe);
    anyhow::bail!("New binary failed --version check, rolled back to previous version");
  }
  println!(" ✓");

  let _ = fs::remove_dir_all(&tmp_dir);

  println!(
    "\n✓ Upgraded to {} (backup at {})",
    release.tag_name,
    backup_path.display()
  );

  if opts.restart {
    attempt_service_restart()?;
  } else {
    print_restart_guidance();
  }

  Ok(())
}

fn platform_asset_name() -> anyhow::Result<String> {
  let name = if cfg!(target_os = "macos") {
    "orbitdock-darwin-arm64.zip"
  } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
    "orbitdock-linux-x86_64.zip"
  } else if cfg!(target_os = "linux") && cfg!(target_arch = "aarch64") {
    "orbitdock-linux-aarch64.zip"
  } else {
    anyhow::bail!(
      "Unsupported platform: {} / {}",
      std::env::consts::OS,
      std::env::consts::ARCH
    );
  };
  Ok(name.to_string())
}

fn default_install_dir() -> PathBuf {
  dirs::home_dir()
    .map(|h| h.join(".orbitdock"))
    .unwrap_or_else(|| PathBuf::from("/usr/local"))
}

/// Stream a release asset to disk without buffering the entire response in memory.
async fn stream_download(
  http: &reqwest::Client,
  asset: &ReleaseAsset,
  dest: &Path,
) -> anyhow::Result<()> {
  let resp = http
    .get(&asset.browser_download_url)
    .header("User-Agent", format!("orbitdock/{VERSION}"))
    .send()
    .await?;

  if !resp.status().is_success() {
    anyhow::bail!("Failed to download {}: HTTP {}", asset.name, resp.status());
  }

  let mut file = tokio::fs::File::create(dest).await?;
  let mut stream = resp.bytes_stream();
  use futures::StreamExt;
  while let Some(chunk) = stream.next().await {
    let chunk = chunk?;
    file.write_all(&chunk).await?;
  }
  file.flush().await?;

  Ok(())
}

fn verify_checksum(zip_path: &Path, checksum_path: &Path) -> anyhow::Result<()> {
  let expected_raw = fs::read_to_string(checksum_path)?;
  let expected = expected_raw
    .split_whitespace()
    .next()
    .ok_or_else(|| anyhow::anyhow!("Empty checksum file"))?
    .to_lowercase();

  let mut file = fs::File::open(zip_path)?;
  let mut hasher = Sha256::new();
  let mut buf = [0u8; 8192];
  loop {
    let n = file.read(&mut buf)?;
    if n == 0 {
      break;
    }
    hasher.update(&buf[..n]);
  }
  let actual = format!("{:x}", hasher.finalize());

  if actual != expected {
    anyhow::bail!(
      "Checksum mismatch!\n  Expected: {expected}\n  Actual:   {actual}\n\
       The download may be corrupted. Aborting upgrade."
    );
  }

  Ok(())
}

fn extract_binary(zip_path: &Path, dest_dir: &Path) -> anyhow::Result<PathBuf> {
  let file = fs::File::open(zip_path)?;
  let mut archive = zip::ZipArchive::new(file)?;

  let binary_name = "orbitdock";
  let out_path = dest_dir.join(binary_name);

  for i in 0..archive.len() {
    let mut entry = archive.by_index(i)?;
    let name = entry.name().to_string();

    if name == binary_name || name.ends_with(&format!("/{binary_name}")) {
      let mut out_file = fs::File::create(&out_path)?;
      std::io::copy(&mut entry, &mut out_file)?;
      return Ok(out_path);
    }
  }

  anyhow::bail!(
    "Archive does not contain an '{binary_name}' binary. Found: {}",
    (0..archive.len())
      .filter_map(|i| archive.by_index(i).ok().map(|e| e.name().to_string()))
      .collect::<Vec<_>>()
      .join(", ")
  )
}

fn service_plist_path() -> Option<PathBuf> {
  dirs::home_dir().map(|h| h.join(LAUNCHD_PLIST))
}

fn service_unit_path() -> Option<PathBuf> {
  dirs::home_dir().map(|h| h.join(SYSTEMD_UNIT))
}

fn print_restart_guidance() {
  if cfg!(target_os = "macos") {
    if let Some(ref p) = service_plist_path() {
      if p.exists() {
        println!("\nTo restart the service:");
        println!("  launchctl kickstart -k gui/$(id -u)/com.orbitdock.server");
        return;
      }
    }
  }

  if cfg!(target_os = "linux") {
    if let Some(ref p) = service_unit_path() {
      if p.exists() {
        println!("\nTo restart the service:");
        println!("  systemctl --user restart orbitdock-server");
        return;
      }
    }
  }

  println!("\nRestart your `orbitdock start` process to use the new version.");
}

fn attempt_service_restart() -> anyhow::Result<()> {
  if cfg!(target_os = "macos") {
    if let Some(ref p) = service_plist_path() {
      if p.exists() {
        println!("  Restarting launchd service...");
        let uid = unsafe { libc::geteuid() };
        let status = std::process::Command::new("launchctl")
          .args([
            "kickstart",
            "-k",
            &format!("gui/{uid}/com.orbitdock.server"),
          ])
          .status()?;
        if status.success() {
          println!("  ✓ Service restarted");
          return Ok(());
        }
        println!("  ⚠ launchctl returned non-zero, you may need to restart manually");
        return Ok(());
      }
    }
  }

  if cfg!(target_os = "linux") {
    if let Some(ref p) = service_unit_path() {
      if p.exists() {
        println!("  Restarting systemd service...");
        let status = std::process::Command::new("systemctl")
          .args(["--user", "restart", "orbitdock-server"])
          .status()?;
        if status.success() {
          println!("  ✓ Service restarted");
          return Ok(());
        }
        println!("  ⚠ systemctl returned non-zero, you may need to restart manually");
        return Ok(());
      }
    }
  }

  println!("  No service detected — restart your `orbitdock start` process manually.");
  Ok(())
}
