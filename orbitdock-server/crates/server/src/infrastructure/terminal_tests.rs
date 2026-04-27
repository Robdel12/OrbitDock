use super::*;
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn create_and_receive_output() {
  let service = TerminalService::new();
  let mut rx = service
    .create(
      "test-term-1".to_string(),
      "/tmp".to_string(),
      Some("/bin/sh".to_string()),
      80,
      24,
    )
    .expect("create terminal");

  service
    .write_input("test-term-1", b"echo hello_term\n")
    .expect("write input");

  let mut collected = String::new();
  let found = timeout(Duration::from_secs(5), async {
    while let Ok(chunk) = rx.recv().await {
      collected.push_str(&String::from_utf8_lossy(&chunk));
      if collected.contains("hello_term") {
        return true;
      }
    }
    false
  })
  .await
  .unwrap_or(false);

  assert!(found, "Expected 'hello_term' in output, got: {collected}");

  service.destroy("test-term-1").expect("destroy");
}

#[tokio::test]
async fn resize_does_not_crash() {
  let service = TerminalService::new();
  let _rx = service
    .create("test-resize".to_string(), "/tmp".to_string(), None, 80, 24)
    .expect("create");

  service.resize("test-resize", 120, 40).expect("resize");
  service.destroy("test-resize").expect("destroy");
}

#[tokio::test]
async fn duplicate_id_rejected() {
  let service = TerminalService::new();
  let _rx = service
    .create("dup-id".to_string(), "/tmp".to_string(), None, 80, 24)
    .expect("first create");

  let err = service
    .create("dup-id".to_string(), "/tmp".to_string(), None, 80, 24)
    .expect_err("second create should fail");

  assert_eq!(err, TerminalCreateError::DuplicateId);
  service.destroy("dup-id").expect("cleanup");
}

#[test]
fn build_output_frame_format() {
  let frame = build_output_frame("term-1", b"hello");
  assert_eq!(frame[0], FRAME_TYPE_OUTPUT);
  assert_eq!(frame[1], 6);
  assert_eq!(&frame[2..8], b"term-1");
  assert_eq!(&frame[8..], b"hello");
}

#[test]
fn build_exit_frame_format() {
  let frame = build_exit_frame("t", Some(42));
  assert_eq!(frame[0], FRAME_TYPE_EXITED);
  assert_eq!(frame[1], 1);
  assert_eq!(&frame[2..3], b"t");
  let exit_code = i32::from_le_bytes(frame[3..7].try_into().unwrap());
  assert_eq!(exit_code, 42);
}
