//! Centralized work_status transition helpers.
//!
//! Every work_status change in the system MUST go through one of these
//! functions. They guarantee: mutate in-memory → persist to DB → broadcast
//! to subscribers (session + dashboard) in that order.

use orbitdock_protocol::{StateChanges, WorkStatus};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::support::session_time::chrono_now;

/// Transition a session's work_status with guaranteed persist + broadcast.
///
/// This is the primary entry point. All providers (Claude, Codex) and all
/// routing modes (Direct, Passive) must use this instead of ad-hoc
/// `ApplyDelta` or `set_work_status` calls.
pub(crate) async fn transition_work_status(
  actor: &SessionActorHandle,
  session_id: &str,
  next_status: WorkStatus,
  extra_changes: Option<StateChanges>,
) {
  let now = chrono_now();
  let mut changes = extra_changes.unwrap_or_default();
  changes.work_status = Some(next_status);
  if changes.last_activity_at.is_none() {
    changes.last_activity_at = Some(now.clone());
  }

  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(changes),
      persist_op: Some(PersistCommand::SessionUpdate {
        id: session_id.to_string(),
        status: None,
        work_status: Some(next_status),
        control_mode: None,
        lifecycle_state: None,
        last_activity_at: Some(now),
        last_progress_at: None,
      }),
    })
    .await;
}

/// Map a WorkStatus to its canonical attention_reason for persistence.
///
/// Returns `Option<Option<String>>` matching the double-Option convention:
/// outer `Some` = "update this field", inner value = the new DB value.
/// `None` (outer) = "don't touch this field" (used for Ended).
pub(crate) fn attention_reason_for_status(status: WorkStatus) -> Option<Option<String>> {
  match status {
    WorkStatus::Working => Some(Some("none".to_string())),
    WorkStatus::Permission => Some(Some("awaitingApproval".to_string())),
    WorkStatus::Question => Some(Some("awaitingQuestion".to_string())),
    WorkStatus::Waiting | WorkStatus::Reply => Some(Some("awaitingReply".to_string())),
    WorkStatus::Ended => None,
  }
}
