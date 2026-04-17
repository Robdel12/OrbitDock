use std::sync::atomic::Ordering;

use orbitdock_protocol::MissionsSnapshot;
use rusqlite::Connection;
use tracing::warn;

use super::SessionRegistry;

impl SessionRegistry {
  /// Send a manual trigger to force an immediate poll for a mission.
  pub async fn trigger_mission(&self, mission_id: String) {
    let _ = self.mission_trigger_tx.send(mission_id).await;
  }

  /// Take the trigger receiver (called once by the orchestrator at startup).
  pub fn take_mission_trigger_rx(&self) -> Option<tokio::sync::mpsc::Receiver<String>> {
    self.mission_trigger_rx.lock().unwrap().take()
  }

  pub fn current_missions_snapshot(&self) -> MissionsSnapshot {
    let rows = match Connection::open(&self.db_path) {
      Ok(conn) => match crate::infrastructure::persistence::load_missions_with_counts(&conn) {
        Ok(rows) => rows,
        Err(error) => {
          warn!(
              component = "mission_control",
              event = "missions.snapshot.load_failed",
              error = %error,
              "Failed to build missions snapshot from persistence"
          );
          Vec::new()
        }
      },
      Err(error) => {
        warn!(
            component = "mission_control",
            event = "missions.snapshot.load_failed",
            error = %error,
            "Failed to build missions snapshot from persistence"
        );
        Vec::new()
      }
    };
    let orchestrator_running = self.is_orchestrator_running();
    let missions = rows
      .into_iter()
      .map(|(row, (active, queued, completed, failed))| {
        crate::transport::http::mission_control::summary_from_row(
          &row,
          active,
          queued,
          completed,
          failed,
          orchestrator_running,
        )
      })
      .collect();

    MissionsSnapshot {
      revision: self.mission_revision.load(Ordering::Relaxed),
      missions,
    }
  }

  pub fn current_missions_revision(&self) -> u64 {
    self.mission_revision.load(Ordering::Relaxed)
  }

  pub fn publish_mission_invalidation(&self, mission_id: &str) {
    let revision = self.mission_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::MissionInvalidated {
        mission_id: mission_id.to_string(),
        revision,
      });
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::MissionsInvalidated { revision });
  }
}
