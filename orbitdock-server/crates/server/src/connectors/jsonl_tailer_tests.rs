use std::collections::HashMap;
use std::io::Write;

use super::{JsonlTailer, PersistedFileState};

#[test]
fn read_appended_lines_buffers_partial_line_until_completed() {
  let tmp_dir = std::env::temp_dir().join(format!(
    "orbitdock-jsonl-tailer-partial-{}",
    std::process::id()
  ));
  let _ = std::fs::remove_dir_all(&tmp_dir);
  std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
  let path = tmp_dir.join("rollout.jsonl");
  let mut tailer = JsonlTailer::new(HashMap::new());
  std::fs::write(&path, b"{\"type\":\"session_meta\"").expect("write partial line");
  let lines = tailer
    .read_appended_lines(&path)
    .expect("read initial partial line");
  assert!(lines.is_empty(), "partial line should stay buffered");

  std::fs::OpenOptions::new()
    .append(true)
    .open(&path)
    .expect("reopen rollout file")
    .write_all(b"}\n")
    .expect("complete line");

  let lines = tailer
    .read_appended_lines(&path)
    .expect("read completed line");
  assert_eq!(lines, vec!["{\"type\":\"session_meta\"}".to_string()]);

  let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn checkpoint_seed_resumes_from_stored_offset() {
  let tmp_dir = std::env::temp_dir().join(format!(
    "orbitdock-jsonl-tailer-resume-{}",
    std::process::id()
  ));
  let _ = std::fs::remove_dir_all(&tmp_dir);
  std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
  let path = tmp_dir.join("rollout.jsonl");
  std::fs::write(
    &path,
    b"{\"type\":\"session_meta\"}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\n",
  )
  .expect("write rollout file");

  let first_line_len = "{\"type\":\"session_meta\"}\n".len() as u64;
  let mut tailer = JsonlTailer::new(HashMap::from([(
    path.to_string_lossy().to_string(),
    PersistedFileState {
      offset: first_line_len,
      session_id: Some("session-1".to_string()),
      project_path: Some("/tmp/repo".to_string()),
      model_provider: Some("codex".to_string()),
      ignore_existing: Some(false),
    },
  )]));

  let lines = tailer
    .read_appended_lines(&path)
    .expect("read from stored offset");
  assert_eq!(
    lines,
    vec!["{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}".to_string()]
  );

  let checkpoint = tailer
    .checkpoint_snapshot(path.to_string_lossy().as_ref())
    .expect("checkpoint snapshot");
  assert_eq!(
    checkpoint.offset,
    std::fs::metadata(&path).expect("stat rollout").len()
  );

  let _ = std::fs::remove_dir_all(&tmp_dir);
}
