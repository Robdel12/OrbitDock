use std::sync::atomic::Ordering;

use super::*;
use crate::runtime::session_broadcasts::invalidated_surfaces;
use crate::support::snapshot_compaction::sanitize_server_message_for_transport;
use orbitdock_protocol::{ServerMessage, SessionSurface};

const EVENT_LOG_CAPACITY: usize = 1000;
const DEFAULT_BROADCAST_CAPACITY: usize = 512;

pub(super) fn broadcast_capacity() -> usize {
  std::env::var("ORBITDOCK_BROADCAST_CAPACITY")
    .ok()
    .and_then(|v| v.parse().ok())
    .unwrap_or(DEFAULT_BROADCAST_CAPACITY)
}

fn is_session_ended(msg: &ServerMessage) -> bool {
  matches!(msg, ServerMessage::SessionEnded { .. })
}

impl SessionHandle {
  /// Emit active-session and archive invalidations from the current snapshot.
  /// Use after `refresh_snapshot()` in code paths that change session state
  /// without going through `broadcast()` (e.g. transition effects that only
  /// produce Persist ops with no Emit).
  pub fn emit_dashboard_update(&self) {
    if let (
      Some(ref list_tx),
      Some(ref sessions_summary_revision),
      Some(ref dashboard_revision),
      Some(ref library_revision),
    ) = (
      &self.list_tx,
      &self.sessions_summary_revision,
      &self.dashboard_revision,
      &self.library_revision,
    ) {
      let sessions_summary_revision = sessions_summary_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::SessionsSummaryInvalidated {
        revision: sessions_summary_revision,
      });
      let library_revision = library_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ArchivedSessionsInvalidated {
        revision: library_revision,
      });
      let revision = dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ActiveSessionsInvalidated { revision });
    }
  }

  /// Broadcast a message to all subscribers
  pub fn broadcast(&mut self, msg: orbitdock_protocol::ServerMessage) {
    self.revision += 1;
    let rev = self.revision;
    let msg = sanitize_server_message_for_transport(msg);

    self.push_event_log_message(&msg, rev);
    let _ = self.broadcast_tx.send(msg.clone());
    let session_id = self.state.id().to_string();
    for surface in invalidated_surfaces(&msg) {
      let invalidation = ServerMessage::SessionSurfaceInvalidated {
        session_id: session_id.clone(),
        surface: *surface,
        revision: rev,
      };
      self.push_event_log_message(&invalidation, rev);
      let _ = self.broadcast_tx.send(invalidation);
    }
    self.refresh_snapshot();

    if is_session_ended(&msg) {
      self.emit_dashboard_removed();
    } else {
      self.emit_dashboard_update();
    }
  }

  pub fn broadcast_surface_invalidations(&mut self, surfaces: &[SessionSurface]) {
    if surfaces.is_empty() {
      return;
    }

    self.revision += 1;
    let rev = self.revision;
    let session_id = self.state.id().to_string();

    for surface in surfaces {
      let invalidation = ServerMessage::SessionSurfaceInvalidated {
        session_id: session_id.clone(),
        surface: *surface,
        revision: rev,
      };
      self.push_event_log_message(&invalidation, rev);
      let _ = self.broadcast_tx.send(invalidation);
    }

    self.refresh_snapshot();
    self.emit_dashboard_update();
  }

  fn push_event_log_message(&mut self, msg: &ServerMessage, revision: u64) {
    if let Ok(json) = serialize_with_revision(msg, revision) {
      self.event_log.push_back((revision, json));
      if self.event_log.len() > EVENT_LOG_CAPACITY {
        self.event_log.pop_front();
      }
    }
  }

  fn emit_dashboard_removed(&self) {
    if let (
      Some(ref list_tx),
      Some(ref sessions_summary_revision),
      Some(ref dashboard_revision),
      Some(ref library_revision),
    ) = (
      &self.list_tx,
      &self.sessions_summary_revision,
      &self.dashboard_revision,
      &self.library_revision,
    ) {
      let sessions_summary_revision = sessions_summary_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::SessionsSummaryInvalidated {
        revision: sessions_summary_revision,
      });
      let library_revision = library_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ArchivedSessionsInvalidated {
        revision: library_revision,
      });
      let revision = dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
      let _ = list_tx.send(ServerMessage::ActiveSessionsInvalidated { revision });
    }
  }

  /// Replay events since a given revision.
  /// Returns `None` if the gap is too large (caller should send a retained snapshot fallback).
  pub fn replay_since(&self, since_revision: u64) -> Option<Vec<String>> {
    let Some(oldest) = self.event_log.front().map(|(rev, _)| *rev) else {
      return (since_revision == self.revision).then(Vec::new);
    };
    if oldest > since_revision + 1 {
      return None; // Gap too large, need a retained snapshot fallback.
    }
    let events: Vec<String> = self
      .event_log
      .iter()
      .filter(|(rev, _)| *rev > since_revision)
      .map(|(_, json)| json.clone())
      .collect();
    Some(events)
  }
}

/// Serialize a ServerMessage with a revision field injected at the top level
fn serialize_with_revision(
  msg: &orbitdock_protocol::ServerMessage,
  revision: u64,
) -> Result<String, serde_json::Error> {
  let mut val = serde_json::to_value(msg)?;
  if let Some(obj) = val.as_object_mut() {
    obj.insert("revision".to_string(), serde_json::json!(revision));
  }
  serde_json::to_string(&val)
}
