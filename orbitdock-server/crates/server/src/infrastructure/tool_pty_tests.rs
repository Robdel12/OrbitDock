use super::*;

#[tokio::test]
async fn create_and_feed_output() {
  let service = ToolPtyService::new();
  let mut rx = service.create_for_tool("tool-1".to_string(), "session-1".to_string());

  service.feed_output("tool-1", b"hello ");
  service.feed_output("tool-1", b"world\n");

  let chunk1 = rx.recv().await.unwrap();
  assert_eq!(chunk1, ToolPtyEvent::Output(b"hello ".to_vec()));

  let chunk2 = rx.recv().await.unwrap();
  assert_eq!(chunk2, ToolPtyEvent::Output(b"world\r\n".to_vec()));
}

#[tokio::test]
async fn late_subscriber_gets_replay() {
  let service = ToolPtyService::new();
  let _initial_rx = service.create_for_tool("tool-2".to_string(), "session-2".to_string());

  service.feed_output("tool-2", b"line 1\n");
  service.feed_output("tool-2", b"line 2\n");

  let (replay, status, _rx) = service.subscribe("session-2", "tool-2").unwrap();
  assert_eq!(replay, b"line 1\r\nline 2\r\n");
  assert_eq!(status, ToolPtyStatus::Running);
}

#[tokio::test]
async fn output_normalizes_bare_lf_without_breaking_crlf_across_chunks() {
  let service = ToolPtyService::new();
  let mut rx = service.create_for_tool("tool-lines".to_string(), "session-lines".to_string());

  service.feed_output("tool-lines", b"one\n");
  service.feed_output("tool-lines", b"two\r");
  service.feed_output("tool-lines", b"\n");
  service.feed_output("tool-lines", b"\rthree");

  assert_eq!(
    rx.recv().await.unwrap(),
    ToolPtyEvent::Output(b"one\r\n".to_vec())
  );
  assert_eq!(
    rx.recv().await.unwrap(),
    ToolPtyEvent::Output(b"two\r".to_vec())
  );
  assert_eq!(
    rx.recv().await.unwrap(),
    ToolPtyEvent::Output(b"\n".to_vec())
  );
  assert_eq!(
    rx.recv().await.unwrap(),
    ToolPtyEvent::Output(b"\rthree".to_vec())
  );

  let replay = service.get_replay_buffer("tool-lines").unwrap();
  assert_eq!(replay, b"one\r\ntwo\r\n\rthree");
}

#[test]
fn subscribe_rejects_session_mismatch() {
  let service = ToolPtyService::new();
  let _rx = service.create_for_tool("tool-x".to_string(), "session-a".to_string());

  assert!(service.subscribe("session-b", "tool-x").is_none());
}

#[test]
fn replay_buffer_trimming() {
  let service = ToolPtyService::new();
  let _rx = service.create_for_tool("tool-3".to_string(), "session-3".to_string());

  let chunk = vec![b'x'; MAX_REPLAY_BUFFER_BYTES + 1000];
  service.feed_output("tool-3", &chunk);

  let replay = service.get_replay_buffer("tool-3").unwrap();
  assert_eq!(replay.len(), MAX_REPLAY_BUFFER_BYTES);
}

#[test]
fn mark_exited_and_status() {
  let service = ToolPtyService::new();
  let _rx = service.create_for_tool("tool-4".to_string(), "session-4".to_string());

  assert_eq!(service.status("tool-4"), Some(ToolPtyStatus::Running));

  service.mark_exited("tool-4", Some(0));
  assert_eq!(
    service.status("tool-4"),
    Some(ToolPtyStatus::Exited { exit_code: Some(0) })
  );
}

#[tokio::test]
async fn exited_event_is_broadcast_in_band() {
  let service = ToolPtyService::new();
  let mut rx = service.create_for_tool("tool-5".to_string(), "session-5".to_string());

  service.mark_exited("tool-5", Some(7));

  let event = rx.recv().await.unwrap();
  assert_eq!(event, ToolPtyEvent::Exited { exit_code: Some(7) });
}

#[tokio::test]
async fn finish_broadcasts_exit_and_destroys_session() {
  let service = ToolPtyService::new();
  let mut rx = service.create_for_tool("tool-6".to_string(), "session-6".to_string());

  service.finish("tool-6", Some(0));

  let event = rx.recv().await.unwrap();
  assert_eq!(event, ToolPtyEvent::Exited { exit_code: Some(0) });
  assert!(!service.exists("tool-6"));
  assert!(matches!(
    rx.recv().await,
    Err(tokio::sync::broadcast::error::RecvError::Closed)
  ));
}
