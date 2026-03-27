//! Mission reconciliation: detect stalled sessions and terminal tracker states.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tracing::{info, warn};

use crate::domain::mission_control::config::MissionConfig;
use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::persistence::mission_control::{MissionIssueRow, MissionRow};
use crate::infrastructure::persistence::PersistCommand;
use crate::infrastructure::persistence::{
  load_workspace_record, update_workspace_record, WorkspaceRecordUpdate,
};
use crate::runtime::session_mutations::{end_session, send_continuation_message};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::workspace_dispatch::daytona::destroy_daytona_workspace;
use crate::support::session_time::parse_unix_z;

/// Terminal tracker states — if an issue moves to one of these, stop working.
const TERMINAL_STATES: &[&str] = &["Done", "Canceled", "Cancelled", "Duplicate", "Won't Fix"];

/// Check if a tracker state string is terminal (case-insensitive).
pub(crate) fn is_terminal_tracker_state(state: &str) -> bool {
  TERMINAL_STATES
    .iter()
    .any(|s| s.eq_ignore_ascii_case(state))
}

/// Check if an orchestration state represents an in-progress issue.
pub(crate) fn is_active_orchestration_state(state: &str) -> bool {
  state == "running" || state == "claimed" || state == "provisioning"
}

/// Determine whether a session has stalled based on the last progress timestamp
/// and the configured timeout.
///
/// Returns `Some(elapsed_secs)` if stalled, `None` if not stalled or timestamps
/// cannot be parsed.
pub(crate) fn stall_elapsed_secs(
  last_progress_at: Option<&str>,
  now_unix_secs: u64,
  stall_timeout_secs: u64,
) -> Option<i64> {
  if stall_timeout_secs == 0 {
    return None;
  }

  let progress_at = parse_unix_z(last_progress_at)?;
  let elapsed_secs = now_unix_secs.saturating_sub(progress_at) as i64;
  if elapsed_secs > stall_timeout_secs as i64 {
    Some(elapsed_secs)
  } else {
    None
  }
}

/// Cooldown between continuation nudges for the same issue (5 minutes).
const NUDGE_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(300);

/// Maximum number of nudges before treating the session as stalled.
/// After this many nudges without the session ending on its own, the
/// orchestrator will stop nudging and let stall detection handle cleanup.
const MAX_NUDGE_ATTEMPTS: u32 = 3;

/// Reconcile a mission's issues:
/// - Check if failed/blocked issues resolved in tracker -> mark completed
/// - Check if running issues' tracker state moved to terminal -> mark completed
/// - Check if agent session ended -> mark completed/failed
/// - Check for stalled sessions -> kill + mark failed
pub async fn reconcile_mission(
  registry: &Arc<SessionRegistry>,
  tracker: &Arc<dyn Tracker>,
  mission: &MissionRow,
  existing_issues: &[MissionIssueRow],
  config: &MissionConfig,
  nudge_tracker: &mut HashMap<String, (std::time::Instant, u32)>,
) {
  // Track which issues we've already handled via terminal state detection
  let mut handled_issue_ids = HashSet::new();

  // ── Pass 0: Recover failed/blocked issues that resolved in tracker ──
  let stuck_issues: Vec<&MissionIssueRow> = existing_issues
    .iter()
    .filter(|i| i.orchestration_state == "failed" || i.orchestration_state == "blocked")
    .collect();

  if !stuck_issues.is_empty() {
    let stuck_ids: Vec<String> = stuck_issues.iter().map(|i| i.issue_id.clone()).collect();
    if let Ok(stuck_states) = tracker.fetch_issue_states(&stuck_ids).await {
      for issue_row in &stuck_issues {
        if let Some(tracker_state) = stuck_states.get(&issue_row.issue_id) {
          if is_terminal_tracker_state(tracker_state) {
            info!(
                component = "mission_control",
                event = "reconciliation.stuck_issue_resolved",
                mission_id = %mission.id,
                issue_id = %issue_row.issue_id,
                previous_state = %issue_row.orchestration_state,
                tracker_state = %tracker_state,
                "Failed/blocked issue resolved in tracker, marking completed"
            );

            let _ = registry
              .persist()
              .send(PersistCommand::MissionIssueUpdateState {
                mission_id: mission.id.clone(),
                issue_id: issue_row.issue_id.clone(),
                orchestration_state: "completed".to_string(),
                session_id: None,
                workspace_id: issue_row.workspace_id.clone(),
                attempt: None,
                last_error: None,
                retry_due_at: None,
                started_at: None,
                completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
              })
              .await;

            maybe_destroy_remote_workspace(registry, issue_row).await;

            handled_issue_ids.insert(issue_row.issue_id.clone());
          }
        }
      }
    }
  }

  // ── Pass 1: Check running issues against tracker ────────────────────
  let running_issues: Vec<&MissionIssueRow> = existing_issues
    .iter()
    .filter(|i| is_active_orchestration_state(&i.orchestration_state))
    .collect();

  if running_issues.is_empty() && handled_issue_ids.is_empty() {
    return;
  }

  if running_issues.is_empty() {
    return;
  }

  let issue_ids: Vec<String> = running_issues.iter().map(|i| i.issue_id.clone()).collect();
  let tracker_states = match tracker.fetch_issue_states(&issue_ids).await {
    Ok(states) => states,
    Err(err) => {
      warn!(
          component = "mission_control",
          event = "reconciliation.tracker_fetch_failed",
          mission_id = %mission.id,
          error = %err,
          "Failed to fetch tracker states for reconciliation"
      );
      std::collections::HashMap::new()
    }
  };
  let stall_timeout_secs = config.orchestration.stall_timeout;

  for issue_row in &running_issues {
    if let Some(tracker_state) = tracker_states.get(&issue_row.issue_id) {
      if is_terminal_tracker_state(tracker_state) {
        info!(
            component = "mission_control",
            event = "reconciliation.terminal_state",
            mission_id = %mission.id,
            issue_id = %issue_row.issue_id,
            tracker_state = %tracker_state,
            "Issue moved to terminal state, marking completed"
        );

        if let Some(ref session_id) = issue_row.session_id {
          end_session(registry, session_id).await;
        }

        let _ = registry
          .persist()
          .send(PersistCommand::MissionIssueUpdateState {
            mission_id: mission.id.clone(),
            issue_id: issue_row.issue_id.clone(),
            orchestration_state: "completed".to_string(),
            session_id: None,
            workspace_id: issue_row.workspace_id.clone(),
            attempt: None,
            last_error: None,
            retry_due_at: None,
            started_at: None,
            completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
          })
          .await;

        maybe_destroy_remote_workspace(registry, issue_row).await;

        handled_issue_ids.insert(issue_row.issue_id.clone());
      }
    }
  }

  // ── Pass 2: Check if agent session has ended ───────────────────────
  for issue_row in &running_issues {
    if let Some(reason) =
      remote_workspace_stall_reason(registry, issue_row, stall_timeout_secs).await
    {
      warn!(
          component = "mission_control",
          event = "reconciliation.workspace_stall_detected",
          mission_id = %mission.id,
          issue_id = %issue_row.issue_id,
          workspace_id = %issue_row.workspace_id.as_deref().unwrap_or(""),
          reason = %reason,
          "Remote workspace heartbeat stalled, marking issue failed"
      );

      if let Some(ref session_id) = issue_row.session_id {
        end_session(registry, session_id).await;
      }

      let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
          mission_id: mission.id.clone(),
          issue_id: issue_row.issue_id.clone(),
          orchestration_state: "failed".to_string(),
          session_id: issue_row.session_id.clone(),
          workspace_id: issue_row.workspace_id.clone(),
          attempt: None,
          last_error: Some(Some(reason.clone())),
          retry_due_at: None,
          started_at: None,
          completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
        })
        .await;

      maybe_destroy_remote_workspace(registry, issue_row).await;
      handled_issue_ids.insert(issue_row.issue_id.clone());
      continue;
    }

    if handled_issue_ids.contains(&issue_row.issue_id) {
      continue;
    }

    let Some(ref session_id) = issue_row.session_id else {
      continue;
    };

    let session_ended = match registry.get_session(session_id) {
      None => true, // Session no longer in registry
      Some(actor) => {
        let snap = actor.snapshot();
        snap.status == orbitdock_protocol::SessionStatus::Ended
          || snap.work_status == orbitdock_protocol::WorkStatus::Ended
      }
    };

    if session_ended {
      info!(
          component = "mission_control",
          event = "reconciliation.session_ended",
          mission_id = %mission.id,
          issue_id = %issue_row.issue_id,
          session_id = %session_id,
          "Agent session ended, marking issue completed"
      );

      let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
          mission_id: mission.id.clone(),
          issue_id: issue_row.issue_id.clone(),
          orchestration_state: "completed".to_string(),
          session_id: None,
          workspace_id: issue_row.workspace_id.clone(),
          attempt: None,
          last_error: None,
          retry_due_at: None,
          started_at: None,
          completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
        })
        .await;

      maybe_destroy_remote_workspace(registry, issue_row).await;

      // Best-effort: move issue to configured completion state in tracker
      if let Err(err) = tracker
        .update_issue_state(&issue_row.issue_id, &config.orchestration.state_on_complete)
        .await
      {
        warn!(
            component = "mission_control",
            event = "reconciliation.tracker_write_failed",
            issue_id = %issue_row.issue_id,
            error = %err,
            "Failed to move issue to completion state in tracker"
        );
      }

      // Best-effort: post completion comment
      if let Err(err) = tracker
        .create_comment(
          &issue_row.issue_id,
          &format!("OrbitDock session `{session_id}` completed successfully."),
        )
        .await
      {
        warn!(
            component = "mission_control",
            event = "reconciliation.tracker_comment_failed",
            issue_id = %issue_row.issue_id,
            error = %err,
            "Failed to post completion comment to tracker"
        );
      }

      handled_issue_ids.insert(issue_row.issue_id.clone());
    }
  }

  // ── Pass 2.5: Continuation nudge for idle sessions ────────────────
  // Clean up completed/handled issues from the nudge tracker
  for issue_row in &running_issues {
    if handled_issue_ids.contains(&issue_row.issue_id) {
      nudge_tracker.remove(&issue_row.issue_id);
    }
  }

  let now = std::time::Instant::now();
  for issue_row in &running_issues {
    if handled_issue_ids.contains(&issue_row.issue_id) {
      continue;
    }

    let Some(ref session_id) = issue_row.session_id else {
      continue;
    };
    let Some(actor) = registry.get_session(session_id) else {
      continue;
    };
    let snap = actor.snapshot();

    if snap.work_status == orbitdock_protocol::WorkStatus::Waiting {
      // Check nudge history for this issue
      if let Some(&(last_nudge, count)) = nudge_tracker.get(&issue_row.issue_id) {
        // Skip if within cooldown
        if now.duration_since(last_nudge) < NUDGE_COOLDOWN {
          continue;
        }
        // Stop nudging after max attempts — let stall detection handle it
        if count >= MAX_NUDGE_ATTEMPTS {
          continue;
        }
      }

      let nudge_count = nudge_tracker
        .get(&issue_row.issue_id)
        .map(|&(_, c)| c)
        .unwrap_or(0);

      let nudge = format!(
        "The issue {} is still in an active state. \
                 Resume from your current progress. Do not restart from scratch. \
                 Focus on remaining work and do not end your turn while the issue \
                 stays active unless you are blocked.",
        issue_row.issue_identifier,
      );
      if send_continuation_message(registry, session_id, &nudge).await {
        nudge_tracker.insert(issue_row.issue_id.clone(), (now, nudge_count + 1));
        info!(
            component = "mission_control",
            event = "reconciliation.continuation_nudge",
            issue_id = %issue_row.issue_id,
            session_id = %session_id,
            nudge_count = nudge_count + 1,
            max_nudges = MAX_NUDGE_ATTEMPTS,
            "Sent continuation nudge to idle session"
        );
        handled_issue_ids.insert(issue_row.issue_id.clone());
      }
    }
  }

  // ── Pass 3: Check for stalled sessions ─────────────────────────────
  if stall_timeout_secs == 0 {
    return;
  }

  for issue_row in &running_issues {
    if handled_issue_ids.contains(&issue_row.issue_id) {
      continue;
    }

    let Some(ref session_id) = issue_row.session_id else {
      continue;
    };

    // Only check sessions that are still alive
    let Some(actor) = registry.get_session(session_id) else {
      continue;
    };

    let snap = actor.snapshot();
    let now_unix_secs = chrono::Utc::now().timestamp().max(0) as u64;
    let Some(elapsed_secs) = stall_elapsed_secs(
      snap.last_progress_at.as_deref(),
      now_unix_secs,
      stall_timeout_secs,
    ) else {
      if snap.last_progress_at.is_none() {
        warn!(
            component = "mission_control",
            event = "reconciliation.no_valid_timestamp",
            mission_id = %mission.id,
            issue_id = %issue_row.issue_id,
            session_id = %session_id,
            "No valid progress timestamp for stall detection"
        );
      }
      continue;
    };

    {
      warn!(
          component = "mission_control",
          event = "reconciliation.stall_detected",
          mission_id = %mission.id,
          issue_id = %issue_row.issue_id,
          session_id = %session_id,
          elapsed_secs = elapsed_secs,
          stall_timeout = stall_timeout_secs,
          "Session stalled, ending and marking failed"
      );

      end_session(registry, session_id).await;

      // Keep session_id so the issue can be resumed from mission control
      let _ = registry
        .persist()
        .send(PersistCommand::MissionIssueUpdateState {
          mission_id: mission.id.clone(),
          issue_id: issue_row.issue_id.clone(),
          orchestration_state: "failed".to_string(),
          session_id: Some(session_id.clone()),
          workspace_id: issue_row.workspace_id.clone(),
          attempt: None,
          last_error: Some(Some(format!(
            "Session stalled after {}s of inactivity",
            elapsed_secs
          ))),
          retry_due_at: None,
          started_at: None,
          completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
        })
        .await;

      maybe_destroy_remote_workspace(registry, issue_row).await;

      // Best-effort: post failure comment
      if let Err(err) = tracker
        .create_comment(
          &issue_row.issue_id,
          &format!(
            "OrbitDock session `{session_id}` stalled after {}s of inactivity and was terminated.",
            elapsed_secs
          ),
        )
        .await
      {
        warn!(
            component = "mission_control",
            event = "reconciliation.tracker_comment_failed",
            issue_id = %issue_row.issue_id,
            error = %err,
            "Failed to post stall comment to tracker"
        );
      }
    }
  }
}

async fn maybe_destroy_remote_workspace(
  registry: &Arc<SessionRegistry>,
  issue_row: &MissionIssueRow,
) {
  let Some(workspace_id) = issue_row.workspace_id.as_deref() else {
    return;
  };

  if let Err(error) = destroy_daytona_workspace(registry.clone(), workspace_id).await {
    warn!(
      component = "mission_control",
      event = "reconciliation.workspace_destroy_failed",
      issue_id = %issue_row.issue_id,
      workspace_id = %workspace_id,
      error = %error,
      "Failed to destroy remote workspace"
    );
  }
}

async fn remote_workspace_stall_reason(
  registry: &Arc<SessionRegistry>,
  issue_row: &MissionIssueRow,
  stall_timeout_secs: u64,
) -> Option<String> {
  let workspace_id = issue_row.workspace_id.as_ref()?.clone();
  let db_path = registry.db_path().clone();
  let workspace = tokio::task::spawn_blocking(move || {
    let conn = rusqlite::Connection::open(&db_path).ok()?;
    load_workspace_record(&conn, &workspace_id).ok().flatten()
  })
  .await
  .ok()
  .flatten()?;

  let now_unix_secs = chrono::Utc::now().timestamp().max(0) as u64;
  let reference = workspace
    .last_heartbeat_at
    .as_deref()
    .or(Some(workspace.created_at.as_str()));

  let elapsed_secs = elapsed_timestamp_secs(reference, now_unix_secs)?;
  if stall_timeout_secs == 0 || elapsed_secs <= stall_timeout_secs as i64 {
    return None;
  }

  let _ = tokio::task::spawn_blocking({
    let db_path = registry.db_path().clone();
    let workspace_id = workspace.id.clone();
    move || {
      let conn = rusqlite::Connection::open(db_path).ok()?;
      update_workspace_record(
        &conn,
        &WorkspaceRecordUpdate {
          id: &workspace_id,
          external_id: None,
          status: "failed",
          connection_info: None,
          ready: false,
          destroyed: false,
        },
      )
      .ok()?;
      Some(())
    }
  })
  .await;

  Some(format!(
    "Remote workspace heartbeat stalled after {}s of inactivity",
    elapsed_secs
  ))
}

fn elapsed_timestamp_secs(value: Option<&str>, now_unix_secs: u64) -> Option<i64> {
  let raw = value?;
  if let Some(unix_z) = parse_unix_z(Some(raw)) {
    return Some(now_unix_secs.saturating_sub(unix_z) as i64);
  }

  if let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(raw) {
    let ts = parsed.timestamp().max(0) as u64;
    return Some(now_unix_secs.saturating_sub(ts) as i64);
  }

  if let Ok(parsed) = chrono::NaiveDateTime::parse_from_str(raw, "%Y-%m-%d %H:%M:%S") {
    let ts = parsed.and_utc().timestamp().max(0) as u64;
    return Some(now_unix_secs.saturating_sub(ts) as i64);
  }

  None
}

#[cfg(test)]
mod tests {
  use super::*;

  // ── is_terminal_tracker_state ─────────────────────────────────────

  #[test]
  fn terminal_states_recognized_exact_case() {
    assert!(is_terminal_tracker_state("Done"));
    assert!(is_terminal_tracker_state("Canceled"));
    assert!(is_terminal_tracker_state("Cancelled"));
    assert!(is_terminal_tracker_state("Duplicate"));
    assert!(is_terminal_tracker_state("Won't Fix"));
  }

  #[test]
  fn terminal_states_recognized_case_insensitive() {
    assert!(is_terminal_tracker_state("done"));
    assert!(is_terminal_tracker_state("DONE"));
    assert!(is_terminal_tracker_state("canceled"));
    assert!(is_terminal_tracker_state("CANCELLED"));
    assert!(is_terminal_tracker_state("duplicate"));
    assert!(is_terminal_tracker_state("won't fix"));
    assert!(is_terminal_tracker_state("WON'T FIX"));
  }

  #[test]
  fn non_terminal_states_rejected() {
    assert!(!is_terminal_tracker_state("In Progress"));
    assert!(!is_terminal_tracker_state("Todo"));
    assert!(!is_terminal_tracker_state("In Review"));
    assert!(!is_terminal_tracker_state("Backlog"));
    assert!(!is_terminal_tracker_state(""));
    assert!(!is_terminal_tracker_state("Doing"));
  }

  // ── is_active_orchestration_state ─────────────────────────────────

  #[test]
  fn active_states_recognized() {
    assert!(is_active_orchestration_state("running"));
    assert!(is_active_orchestration_state("claimed"));
    assert!(is_active_orchestration_state("provisioning"));
  }

  #[test]
  fn non_active_states_rejected() {
    assert!(!is_active_orchestration_state("queued"));
    assert!(!is_active_orchestration_state("retry_queued"));
    assert!(!is_active_orchestration_state("completed"));
    assert!(!is_active_orchestration_state("failed"));
    assert!(!is_active_orchestration_state(""));
  }

  // ── stall_elapsed_secs ────────────────────────────────────────────

  #[test]
  fn stall_detected_when_past_timeout() {
    let now = chrono::Utc::now().timestamp() as u64;
    let old = format!("{}Z", now - 600);

    let result = stall_elapsed_secs(Some(&old), now, 300);
    assert!(result.is_some());
    let secs = result.unwrap();
    assert!(secs >= 600, "expected >= 600s, got {secs}");
  }

  #[test]
  fn no_stall_when_within_timeout() {
    let now = chrono::Utc::now().timestamp() as u64;
    let recent = format!("{}Z", now - 60);

    let result = stall_elapsed_secs(Some(&recent), now, 300);
    assert!(result.is_none());
  }

  #[test]
  fn stall_returns_none_when_no_timestamps() {
    let now = chrono::Utc::now().timestamp() as u64;
    let result = stall_elapsed_secs(None, now, 300);
    assert!(result.is_none());
  }

  #[test]
  fn stall_returns_none_when_timeout_is_zero() {
    let now = chrono::Utc::now().timestamp() as u64;
    let old = format!("{}Z", now - 600);

    let result = stall_elapsed_secs(Some(&old), now, 0);
    assert!(result.is_none());
  }

  #[test]
  fn stall_returns_none_when_timestamp_malformed() {
    let now = chrono::Utc::now().timestamp() as u64;
    let result = stall_elapsed_secs(Some("not-a-timestamp"), now, 300);
    assert!(result.is_none());
  }

  #[test]
  fn elapsed_timestamp_secs_supports_sqlite_datetime() {
    let now = chrono::NaiveDate::from_ymd_opt(2026, 3, 27)
      .unwrap()
      .and_hms_opt(12, 0, 0)
      .unwrap()
      .and_utc()
      .timestamp() as u64;

    let result = elapsed_timestamp_secs(Some("2026-03-27 11:55:00"), now);
    assert_eq!(result, Some(300));
  }

  // ── TERMINAL_STATES constant ──────────────────────────────────────

  #[test]
  fn terminal_states_covers_expected_set() {
    // Verify the constant contains exactly the expected states
    let expected = vec!["Done", "Canceled", "Cancelled", "Duplicate", "Won't Fix"];
    assert_eq!(TERMINAL_STATES.len(), expected.len());
    for state in &expected {
      assert!(
        TERMINAL_STATES.contains(state),
        "Expected TERMINAL_STATES to contain {state:?}"
      );
    }
  }
}
