use super::*;
use chrono::{DateTime, Utc};
use std::fs;
use std::process::Command;

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
fn prune_old_logs_removes_old_rotated_logs() {
  let tmp = tempfile::tempdir().expect("create temp dir");
  let log_dir = tmp.path();
  let old_log = log_dir.join("server.log.2026-03-20");

  fs::write(&old_log, "old").unwrap();
  set_mtime(
    &old_log,
    SystemTime::now() - LOG_MAX_AGE - Duration::from_secs(24 * 60 * 60),
  );

  prune_old_logs(log_dir);

  assert!(!old_log.exists());
}

#[test]
fn prune_old_logs_caps_total_rotated_size() {
  let tmp = tempfile::tempdir().expect("create temp dir");
  let log_dir = tmp.path();

  let oldest = log_dir.join("server.log.2026-03-27-10");
  let newest = log_dir.join("server.log.2026-03-27-11");
  fs::write(
    &oldest,
    vec![b'a'; (ROTATED_SERVER_LOG_MAX_BYTES / 2 + 1024) as usize],
  )
  .unwrap();
  fs::write(
    &newest,
    vec![b'b'; (ROTATED_SERVER_LOG_MAX_BYTES / 2 + 1024) as usize],
  )
  .unwrap();

  set_mtime(&oldest, SystemTime::now() - Duration::from_secs(120));
  set_mtime(&newest, SystemTime::now() - Duration::from_secs(60));

  prune_old_logs(log_dir);

  assert!(!oldest.exists());
  assert!(newest.exists());
}

fn set_mtime(path: &std::path::Path, time: SystemTime) {
  let timestamp = DateTime::<Utc>::from(time)
    .format("%Y%m%d%H%M.%S")
    .to_string();
  let status = Command::new("touch")
    .arg("-t")
    .arg(timestamp)
    .arg(path)
    .status()
    .expect("touch should run");
  assert!(status.success(), "touch should succeed");
}

#[test]
fn truncate_root_logs_caps_large_files() {
  let tmp = tempfile::tempdir().expect("create temp dir");
  let data_dir = tmp.path();

  fs::write(data_dir.join("small.log"), "tiny").unwrap();

  let big_content = vec![b'x'; (ROOT_LOG_MAX_BYTES + 1) as usize];
  fs::write(data_dir.join("big.log"), &big_content).unwrap();

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
