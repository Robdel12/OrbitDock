//! Virtual PTY service for streaming bash tool output.
//!
//! Unlike the real PTY service in `terminal.rs`, this service doesn't spawn
//! processes. Instead, it accepts raw bytes from connector events (Codex tool
//! output) and broadcasts them to subscribed clients using the same binary
//! frame protocol as interactive terminals.
//!
//! This enables live terminal rendering of bash command output in tool cards
//! without spawning redundant shell processes.

use std::sync::Arc;

use dashmap::DashMap;
use tokio::sync::broadcast;
use tracing::{debug, info};

/// Maximum size of the replay buffer per tool session.
/// Late-joining clients receive this buffer on attach.
const MAX_REPLAY_BUFFER_BYTES: usize = 1024 * 1024; // 1MB

/// Broadcast channel capacity for output chunks.
const OUTPUT_CHANNEL_CAPACITY: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolPtyEvent {
  Output(Vec<u8>),
  Exited { exit_code: Option<i32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolPtyStatus {
  Running,
  Exited { exit_code: Option<i32> },
}

struct ToolPtySession {
  #[allow(dead_code)] // Used for debugging and future session isolation
  session_id: String,
  event_tx: broadcast::Sender<ToolPtyEvent>,
  replay_buffer: Vec<u8>,
  status: ToolPtyStatus,
  pending_carriage_return: bool,
}

impl ToolPtySession {
  fn new(session_id: String) -> Self {
    let (event_tx, _) = broadcast::channel(OUTPUT_CHANNEL_CAPACITY);
    Self {
      session_id,
      event_tx,
      replay_buffer: Vec::new(),
      status: ToolPtyStatus::Running,
      pending_carriage_return: false,
    }
  }

  fn append_output(&mut self, bytes: &[u8]) {
    let bytes = normalize_virtual_pty_output(bytes, &mut self.pending_carriage_return);
    let _ = self.event_tx.send(ToolPtyEvent::Output(bytes.clone()));
    self.append_to_replay_buffer(&bytes);
  }

  fn append_to_replay_buffer(&mut self, bytes: &[u8]) {
    self.replay_buffer.extend_from_slice(bytes);
    if self.replay_buffer.len() > MAX_REPLAY_BUFFER_BYTES {
      let excess = self.replay_buffer.len() - MAX_REPLAY_BUFFER_BYTES;
      self.replay_buffer.drain(..excess);
    }
  }
}

fn normalize_virtual_pty_output(bytes: &[u8], pending_carriage_return: &mut bool) -> Vec<u8> {
  let mut normalized = Vec::with_capacity(bytes.len());
  for &byte in bytes {
    match byte {
      b'\n' if *pending_carriage_return => {
        normalized.push(b'\n');
        *pending_carriage_return = false;
      }
      b'\n' => {
        normalized.extend_from_slice(b"\r\n");
        *pending_carriage_return = false;
      }
      byte => {
        normalized.push(byte);
        *pending_carriage_return = byte == b'\r';
      }
    }
  }
  normalized
}

/// Service for managing virtual PTY sessions for tool output streaming.
#[derive(Clone, Default)]
pub struct ToolPtyService {
  sessions: Arc<DashMap<String, ToolPtySession>>,
}

impl ToolPtyService {
  pub fn new() -> Self {
    Self::default()
  }

  /// Create a new tool PTY session for streaming command output.
  ///
  /// Returns a broadcast receiver for output chunks. The first subscriber
  /// typically uses this; late joiners should use `subscribe()` to get
  /// the replay buffer as well.
  pub fn create_for_tool(
    &self,
    tool_id: String,
    session_id: String,
  ) -> broadcast::Receiver<ToolPtyEvent> {
    info!(
      component = "tool_pty",
      event = "tool_pty.created",
      tool_id = %tool_id,
      session_id = %session_id,
      "Tool PTY session created"
    );

    let session = ToolPtySession::new(session_id);
    let rx = session.event_tx.subscribe();
    self.sessions.insert(tool_id, session);
    rx
  }

  /// Feed raw output bytes into the tool's PTY session.
  ///
  /// Bytes are broadcast to all active subscribers and buffered for replay.
  pub fn feed_output(&self, tool_id: &str, bytes: &[u8]) {
    if let Some(mut session) = self.sessions.get_mut(tool_id) {
      session.append_output(bytes);
    } else {
      debug!(
        component = "tool_pty",
        event = "tool_pty.feed_output.no_session",
        tool_id = %tool_id,
        "Attempted to feed output to non-existent tool PTY session"
      );
    }
  }

  /// Subscribe to an existing tool PTY session.
  ///
  /// Returns the current replay buffer and a receiver for future output.
  /// Use this for late-joining clients that need to catch up on output.
  pub fn subscribe(
    &self,
    session_id: &str,
    tool_id: &str,
  ) -> Option<(Vec<u8>, ToolPtyStatus, broadcast::Receiver<ToolPtyEvent>)> {
    self.sessions.get(tool_id).and_then(|session| {
      if session.session_id != session_id {
        return None;
      }
      let replay = session.replay_buffer.clone();
      let status = session.status;
      let rx = session.event_tx.subscribe();
      Some((replay, status, rx))
    })
  }

  /// Get just the replay buffer without subscribing.
  ///
  /// Useful for completed tools where streaming isn't needed.
  #[allow(dead_code)] // Will be used for completed tool replay without streaming
  pub fn get_replay_buffer(&self, tool_id: &str) -> Option<Vec<u8>> {
    self.sessions.get(tool_id).map(|s| s.replay_buffer.clone())
  }

  /// Get the session ID associated with a tool PTY.
  #[allow(dead_code)] // Useful for debugging and session isolation
  pub fn get_session_id(&self, tool_id: &str) -> Option<String> {
    self.sessions.get(tool_id).map(|s| s.session_id.clone())
  }

  /// Get the current status of a tool PTY session.
  #[cfg_attr(not(test), allow(dead_code))]
  pub fn status(&self, tool_id: &str) -> Option<ToolPtyStatus> {
    self.sessions.get(tool_id).map(|s| s.status)
  }

  /// Mark a tool as exited. Keeps the session alive for replay.
  pub fn mark_exited(&self, tool_id: &str, exit_code: Option<i32>) {
    if let Some(mut session) = self.sessions.get_mut(tool_id) {
      session.status = ToolPtyStatus::Exited { exit_code };
      let _ = session.event_tx.send(ToolPtyEvent::Exited { exit_code });
      info!(
        component = "tool_pty",
        event = "tool_pty.exited",
        tool_id = %tool_id,
        exit_code = ?exit_code,
        "Tool PTY session marked as exited"
      );
    }
  }

  /// Mark a tool as exited and immediately destroy its runtime PTY session.
  ///
  /// Completed tools render from persisted transcript output, so the PTY
  /// service only needs to keep state alive while the command is running.
  pub fn finish(&self, tool_id: &str, exit_code: Option<i32>) {
    self.mark_exited(tool_id, exit_code);
    self.destroy(tool_id);
  }

  /// Check if a tool PTY session exists.
  #[allow(dead_code)] // Will be used for session cleanup logic
  pub fn exists(&self, tool_id: &str) -> bool {
    self.sessions.contains_key(tool_id)
  }

  /// Remove a tool PTY session entirely.
  ///
  /// Call this after a grace period to allow late expansion of completed tools.
  pub fn destroy(&self, tool_id: &str) {
    if self.sessions.remove(tool_id).is_some() {
      debug!(
        component = "tool_pty",
        event = "tool_pty.destroyed",
        tool_id = %tool_id,
        "Tool PTY session destroyed"
      );
    }
  }

  /// Get the number of active subscribers for a tool PTY.
  #[allow(dead_code)] // Will be used for monitoring and cleanup decisions
  pub fn subscriber_count(&self, tool_id: &str) -> usize {
    self
      .sessions
      .get(tool_id)
      .map(|s| s.event_tx.receiver_count())
      .unwrap_or(0)
  }

  /// Clean up old exited sessions based on a predicate.
  #[allow(dead_code)] // Will be used for periodic session cleanup
  pub fn cleanup_if<F>(&self, mut should_remove: F)
  where
    F: FnMut(&str, &ToolPtyStatus) -> bool,
  {
    let to_remove: Vec<String> = self
      .sessions
      .iter()
      .filter(|entry| should_remove(entry.key(), &entry.value().status))
      .map(|entry| entry.key().clone())
      .collect();

    for tool_id in to_remove {
      self.destroy(&tool_id);
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[tokio::test]
  async fn create_and_feed_output() {
    let service = ToolPtyService::new();
    let mut rx = service.create_for_tool("tool-1".to_string(), "session-1".to_string());

    service.feed_output("tool-1", b"hello ");
    service.feed_output("tool-1", b"world\n");

    // Subscriber should receive both chunks
    let chunk1 = rx.recv().await.unwrap();
    assert_eq!(chunk1, ToolPtyEvent::Output(b"hello ".to_vec()));

    let chunk2 = rx.recv().await.unwrap();
    assert_eq!(chunk2, ToolPtyEvent::Output(b"world\r\n".to_vec()));
  }

  #[tokio::test]
  async fn late_subscriber_gets_replay() {
    let service = ToolPtyService::new();
    let _initial_rx = service.create_for_tool("tool-2".to_string(), "session-2".to_string());

    // Feed some output before the late subscriber joins
    service.feed_output("tool-2", b"line 1\n");
    service.feed_output("tool-2", b"line 2\n");

    // Late subscriber
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

    // Feed more than MAX_REPLAY_BUFFER_BYTES
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
}
