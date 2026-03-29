//! Housekeeping — prunes stale logs, temporary files, and unbounded DB tables.

use std::path::Path;
use std::time::{Duration, SystemTime};

use rusqlite::{params, Connection};
use tracing::{info, warn};

/// Maximum age for rotated log files before they get deleted.
const LOG_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60); // 7 days

/// Maximum age for root-level `.log` files (cli.log, hooks.log, etc.)
/// These are written by external processes and never rotated, so we truncate
/// them when they exceed this age since last modification.
const ROOT_LOG_MAX_AGE: Duration = Duration::from_secs(3 * 24 * 60 * 60); // 3 days

/// Maximum size for root-level `.log` files before truncation (10 MB).
const ROOT_LOG_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Usage events older than this are pruned. The rolled-up `usage_session_state`
/// table retains the summary — granular events are only useful short-term.
const USAGE_EVENTS_MAX_AGE_DAYS: u32 = 30;

/// Messages from ended sessions older than this are deleted. The session row
/// itself is kept (for dashboard history) but the conversation payload is freed.
const ENDED_SESSION_MESSAGE_MAX_AGE_DAYS: u32 = 60;

/// Run all housekeeping tasks. Safe to call on every startup.
pub fn run_housekeeping() {
  let data_dir = crate::infrastructure::paths::data_dir();
  let log_dir = crate::infrastructure::paths::log_dir();

  prune_old_logs(&log_dir);
  truncate_root_logs(&data_dir);
  prune_usage_events();
  prune_old_session_messages();
  prune_orphaned_images();
}

/// Delete rotated log files in `logs/` older than `LOG_MAX_AGE`.
fn prune_old_logs(log_dir: &Path) {
  let entries = match std::fs::read_dir(log_dir) {
    Ok(entries) => entries,
    Err(_) => return,
  };

  let cutoff = SystemTime::now() - LOG_MAX_AGE;

  for entry in entries.filter_map(Result::ok) {
    let path = entry.path();
    if !path.is_file() {
      continue;
    }

    // Only prune rotated files (e.g. server.log.2026-03-21) — skip the
    // active log which has no date suffix.
    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if file_name == "server.log" {
      continue;
    }

    let modified = match entry.metadata().and_then(|m| m.modified()) {
      Ok(t) => t,
      Err(_) => continue,
    };

    if modified < cutoff {
      let _ = std::fs::remove_file(&path);
    }
  }
}

/// Truncate root-level `.log` files that are too old or too large.
/// These files (cli.log, hooks.log, codex-server.log, etc.) are written by
/// external processes that don't rotate, so we cap them here.
fn truncate_root_logs(data_dir: &Path) {
  let entries = match std::fs::read_dir(data_dir) {
    Ok(entries) => entries,
    Err(_) => return,
  };

  let age_cutoff = SystemTime::now() - ROOT_LOG_MAX_AGE;

  for entry in entries.filter_map(Result::ok) {
    let path = entry.path();
    if !path.is_file() {
      continue;
    }

    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    if !file_name.ends_with(".log") {
      continue;
    }

    let metadata = match entry.metadata() {
      Ok(m) => m,
      Err(_) => continue,
    };

    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let too_old = modified < age_cutoff;
    let too_large = metadata.len() > ROOT_LOG_MAX_BYTES;

    if too_old || too_large {
      if let Err(error) = std::fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(&path)
      {
        warn!(
          component = "housekeeping",
          event = "housekeeping.root_log_truncate_error",
          path = %path.display(),
          error = %error,
          "Failed to truncate root log file"
        );
      }
    }
  }
}

/// Delete usage_events older than `USAGE_EVENTS_MAX_AGE_DAYS`.
fn prune_usage_events() {
  let db_path = crate::infrastructure::paths::db_path();
  if !db_path.exists() {
    return;
  }

  let conn = match Connection::open(&db_path) {
    Ok(c) => c,
    Err(_) => return,
  };
  let _ = conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  );

  let cutoff = format!("-{USAGE_EVENTS_MAX_AGE_DAYS} days");
  match conn.execute(
    "DELETE FROM usage_events WHERE observed_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?1)",
    params![cutoff],
  ) {
    Ok(deleted) if deleted > 0 => {
      info!(
        component = "housekeeping",
        event = "housekeeping.usage_events_pruned",
        deleted,
        "Pruned old usage events"
      );
    }
    _ => {}
  }
}

/// Delete messages from ended sessions older than `ENDED_SESSION_MESSAGE_MAX_AGE_DAYS`.
/// Keeps the session row for history/dashboard but frees the heavy conversation payload.
fn prune_old_session_messages() {
  let db_path = crate::infrastructure::paths::db_path();
  if !db_path.exists() {
    return;
  }

  let conn = match Connection::open(&db_path) {
    Ok(c) => c,
    Err(_) => return,
  };
  let _ = conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  );

  let cutoff = format!("-{ENDED_SESSION_MESSAGE_MAX_AGE_DAYS} days");
  match conn.execute(
    "DELETE FROM messages WHERE session_id IN (
       SELECT id FROM sessions
       WHERE lifecycle_state = 'ended'
         AND ended_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?1)
     )",
    params![cutoff],
  ) {
    Ok(deleted) if deleted > 0 => {
      info!(
        component = "housekeeping",
        event = "housekeeping.old_session_messages_pruned",
        deleted,
        "Pruned messages from ended sessions older than {ENDED_SESSION_MESSAGE_MAX_AGE_DAYS} days"
      );
    }
    _ => {}
  }
}

/// Remove image attachment directories for sessions whose messages have been pruned.
fn prune_orphaned_images() {
  let images_dir = crate::infrastructure::paths::images_dir();
  let db_path = crate::infrastructure::paths::db_path();

  if !images_dir.exists() || !db_path.exists() {
    return;
  }

  let conn = match Connection::open(&db_path) {
    Ok(c) => c,
    Err(_) => return,
  };
  let _ = conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  );

  let entries = match std::fs::read_dir(&images_dir) {
    Ok(entries) => entries,
    Err(_) => return,
  };

  let mut removed = 0u64;
  for entry in entries.filter_map(Result::ok) {
    let path = entry.path();
    if !path.is_dir() {
      continue;
    }

    let session_id = match path.file_name().and_then(|n| n.to_str()) {
      Some(name) => name.to_string(),
      None => continue,
    };

    // If no messages remain for this session, the images are orphaned.
    let has_messages: bool = conn
      .query_row(
        "SELECT EXISTS(SELECT 1 FROM messages WHERE session_id = ?1 LIMIT 1)",
        params![session_id],
        |row| row.get(0),
      )
      .unwrap_or(true); // default to keeping on error

    if !has_messages && std::fs::remove_dir_all(&path).is_ok() {
      removed += 1;
    }
  }

  if removed > 0 {
    info!(
      component = "housekeeping",
      event = "housekeeping.orphaned_images_pruned",
      removed,
      "Removed orphaned image directories"
    );
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::fs;

  #[test]
  fn prune_old_logs_preserves_active_log() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let log_dir = tmp.path();

    fs::write(log_dir.join("server.log"), "active").unwrap();
    fs::write(log_dir.join("server.log.2026-03-27"), "recent").unwrap();

    prune_old_logs(log_dir);

    assert!(log_dir.join("server.log").exists());
    assert!(log_dir.join("server.log.2026-03-27").exists());
  }

  #[test]
  fn truncate_root_logs_caps_large_files() {
    let tmp = tempfile::tempdir().expect("create temp dir");
    let data_dir = tmp.path();

    // Small log — should survive
    fs::write(data_dir.join("small.log"), "tiny").unwrap();

    // Large log — should be truncated
    let big_content = vec![b'x'; (ROOT_LOG_MAX_BYTES + 1) as usize];
    fs::write(data_dir.join("big.log"), &big_content).unwrap();

    // Non-log file — should be ignored
    let big_non_log = vec![b'y'; (ROOT_LOG_MAX_BYTES + 1) as usize];
    fs::write(data_dir.join("big.json"), &big_non_log).unwrap();

    truncate_root_logs(data_dir);

    assert_eq!(
      fs::read_to_string(data_dir.join("small.log")).unwrap(),
      "tiny"
    );
    assert_eq!(fs::metadata(data_dir.join("big.log")).unwrap().len(), 0);
    assert!(fs::metadata(data_dir.join("big.json")).unwrap().len() > ROOT_LOG_MAX_BYTES);
  }
}
