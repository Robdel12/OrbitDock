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
