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
use tracing::debug;

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
    debug!(
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
  #[cfg(test)]
  pub fn get_replay_buffer(&self, tool_id: &str) -> Option<Vec<u8>> {
    self.sessions.get(tool_id).map(|s| s.replay_buffer.clone())
  }

  /// Get the current status of a tool PTY session.
  #[cfg(test)]
  pub fn status(&self, tool_id: &str) -> Option<ToolPtyStatus> {
    self.sessions.get(tool_id).map(|s| s.status)
  }

  /// Mark a tool as exited. Keeps the session alive for replay.
  pub fn mark_exited(&self, tool_id: &str, exit_code: Option<i32>) {
    if let Some(mut session) = self.sessions.get_mut(tool_id) {
      session.status = ToolPtyStatus::Exited { exit_code };
      let _ = session.event_tx.send(ToolPtyEvent::Exited { exit_code });
      debug!(
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
  #[cfg(test)]
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
}

#[cfg(test)]
#[path = "tool_pty_tests.rs"]
mod tests;
