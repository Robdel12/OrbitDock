use super::{execute_with_stream, ShellCancelStatus, ShellOutcome, ShellService, ShellStartError};
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn execute_with_stream_completes_successfully() {
  let result = execute_with_stream("printf 'hello'", "/tmp", 5, None).await;
  assert_eq!(result.stdout, "hello");
  assert_eq!(result.exit_code, Some(0));
  assert_eq!(result.outcome, ShellOutcome::Completed);
}

#[tokio::test]
async fn execute_with_stream_times_out() {
  let result = execute_with_stream("sleep 2", "/tmp", 1, None).await;
  assert_eq!(result.exit_code, None);
  assert_eq!(result.outcome, ShellOutcome::TimedOut);
  assert!(result.stderr.contains("timed out"));
}

#[tokio::test]
async fn shell_service_can_cancel_running_command() {
  let service = ShellService::new();
  let request_id = "req-cancel".to_string();
  let session_id = "sess-cancel".to_string();

  let execution = service
    .start(
      request_id.clone(),
      session_id.clone(),
      "sleep 30".to_string(),
      "/tmp".to_string(),
      60,
    )
    .expect("start");

  assert_eq!(
    service.cancel(&session_id, &request_id),
    ShellCancelStatus::Canceled
  );

  let result = timeout(Duration::from_secs(3), execution.completion_rx)
    .await
    .expect("completion timeout")
    .expect("completion result");
  assert_eq!(result.outcome, ShellOutcome::Canceled);
  assert!(result.stderr.contains("canceled"));
}

#[tokio::test]
async fn shell_service_rejects_duplicate_request_id() {
  let service = ShellService::new();
  let request_id = "req-dup".to_string();

  let _first = service
    .start(
      request_id.clone(),
      "sess-a".to_string(),
      "sleep 10".to_string(),
      "/tmp".to_string(),
      30,
    )
    .expect("first start");

  let second = service.start(
    request_id,
    "sess-b".to_string(),
    "echo nope".to_string(),
    "/tmp".to_string(),
    30,
  );
  assert_eq!(second.err(), Some(ShellStartError::DuplicateRequestId));
}
