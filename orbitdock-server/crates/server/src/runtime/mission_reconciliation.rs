//! Mission reconciliation: detect stalled sessions and terminal tracker states.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tracing::{info, warn};

use crate::domain::mission_control::config::MissionConfig;
use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::persistence::mission_control::{MissionIssueRow, MissionRow};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_mutations::{end_session, send_continuation_message};
use crate::runtime::session_registry::SessionRegistry;

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
    state == "running" || state == "claimed"
}

/// Determine whether a session has stalled based on the last activity timestamp
/// and the configured timeout.
///
/// Returns `Some(elapsed_secs)` if stalled, `None` if not stalled or timestamps
/// cannot be parsed.
pub(crate) fn stall_elapsed_secs(
    last_activity_at: Option<&str>,
    started_at: Option<&str>,
    now: chrono::DateTime<chrono::Utc>,
    stall_timeout_secs: u64,
) -> Option<i64> {
    if stall_timeout_secs == 0 {
        return None;
    }

    let parsed = last_activity_at
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
        .or_else(|| started_at.and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok()))?;

    let elapsed = now - parsed.with_timezone(&chrono::Utc);
    if elapsed.num_seconds() > stall_timeout_secs as i64 {
        Some(elapsed.num_seconds())
    } else {
        None
    }
}

/// Cooldown between continuation nudges for the same issue (5 minutes).
const NUDGE_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(300);

/// Reconcile a mission's running issues:
/// - Check if tracker state moved to terminal -> mark completed
/// - Check if agent session ended -> mark completed/failed
/// - Check for stalled sessions -> kill + mark failed
pub async fn reconcile_mission(
    registry: &Arc<SessionRegistry>,
    tracker: &Arc<dyn Tracker>,
    mission: &MissionRow,
    existing_issues: &[MissionIssueRow],
    config: &MissionConfig,
    nudge_tracker: &mut HashMap<String, std::time::Instant>,
) {
    let running_issues: Vec<&MissionIssueRow> = existing_issues
        .iter()
        .filter(|i| is_active_orchestration_state(&i.orchestration_state))
        .collect();

    if running_issues.is_empty() {
        return;
    }

    // Track which issues we've already handled via terminal state detection
    let mut handled_issue_ids = HashSet::new();

    // ── Pass 1: Check if tracker state moved to terminal ───────────────
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
                        attempt: None,
                        last_error: None,
                        retry_due_at: None,
                        started_at: None,
                        completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
                    })
                    .await;

                handled_issue_ids.insert(issue_row.issue_id.clone());
            }
        }
    }

    // ── Pass 2: Check if agent session has ended ───────────────────────
    for issue_row in &running_issues {
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
                    attempt: None,
                    last_error: None,
                    retry_due_at: None,
                    started_at: None,
                    completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
                })
                .await;

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
            // Skip if we nudged this issue within the cooldown period
            if let Some(last_nudge) = nudge_tracker.get(&issue_row.issue_id) {
                if now.duration_since(*last_nudge) < NUDGE_COOLDOWN {
                    continue;
                }
            }

            let nudge = format!(
                "The issue {} is still in an active state. \
                 Resume from your current progress. Do not restart from scratch. \
                 Focus on remaining work and do not end your turn while the issue \
                 stays active unless you are blocked.",
                issue_row.issue_identifier,
            );
            if send_continuation_message(registry, session_id, &nudge).await {
                nudge_tracker.insert(issue_row.issue_id.clone(), now);
                info!(
                    component = "mission_control",
                    event = "reconciliation.continuation_nudge",
                    issue_id = %issue_row.issue_id,
                    session_id = %session_id,
                    "Sent continuation nudge to idle session"
                );
                handled_issue_ids.insert(issue_row.issue_id.clone());
            }
        }
    }

    // ── Pass 3: Check for stalled sessions ─────────────────────────────
    let stall_timeout_secs = config.orchestration.stall_timeout;
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
        let now = chrono::Utc::now();
        let Some(elapsed_secs) = stall_elapsed_secs(
            snap.last_activity_at.as_deref(),
            issue_row.started_at.as_deref(),
            now,
            stall_timeout_secs,
        ) else {
            if snap.last_activity_at.is_none() && issue_row.started_at.is_none() {
                warn!(
                    component = "mission_control",
                    event = "reconciliation.no_valid_timestamp",
                    mission_id = %mission.id,
                    issue_id = %issue_row.issue_id,
                    session_id = %session_id,
                    "No valid timestamp for stall detection"
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

            let _ = registry
                .persist()
                .send(PersistCommand::MissionIssueUpdateState {
                    mission_id: mission.id.clone(),
                    issue_id: issue_row.issue_id.clone(),
                    orchestration_state: "failed".to_string(),
                    session_id: None,
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
        let now = chrono::Utc::now();
        let old = (now - chrono::Duration::seconds(600)).to_rfc3339();

        let result = stall_elapsed_secs(Some(&old), None, now, 300);
        assert!(result.is_some());
        let secs = result.unwrap();
        assert!(secs >= 600, "expected >= 600s, got {secs}");
    }

    #[test]
    fn no_stall_when_within_timeout() {
        let now = chrono::Utc::now();
        let recent = (now - chrono::Duration::seconds(60)).to_rfc3339();

        let result = stall_elapsed_secs(Some(&recent), None, now, 300);
        assert!(result.is_none());
    }

    #[test]
    fn stall_falls_back_to_started_at() {
        let now = chrono::Utc::now();
        let old = (now - chrono::Duration::seconds(600)).to_rfc3339();

        // last_activity_at is None, should fall back to started_at
        let result = stall_elapsed_secs(None, Some(&old), now, 300);
        assert!(result.is_some());
    }

    #[test]
    fn stall_prefers_last_activity_over_started_at() {
        let now = chrono::Utc::now();
        let recent = (now - chrono::Duration::seconds(60)).to_rfc3339();
        let old = (now - chrono::Duration::seconds(600)).to_rfc3339();

        // last_activity_at is recent (within timeout), started_at is old
        // Should use last_activity_at and return None (not stalled)
        let result = stall_elapsed_secs(Some(&recent), Some(&old), now, 300);
        assert!(result.is_none());
    }

    #[test]
    fn stall_returns_none_when_no_timestamps() {
        let now = chrono::Utc::now();
        let result = stall_elapsed_secs(None, None, now, 300);
        assert!(result.is_none());
    }

    #[test]
    fn stall_returns_none_when_timeout_is_zero() {
        let now = chrono::Utc::now();
        let old = (now - chrono::Duration::seconds(600)).to_rfc3339();

        let result = stall_elapsed_secs(Some(&old), None, now, 0);
        assert!(result.is_none());
    }

    #[test]
    fn stall_skips_malformed_last_activity_falls_back() {
        let now = chrono::Utc::now();
        let old = (now - chrono::Duration::seconds(600)).to_rfc3339();

        // Malformed last_activity_at, valid started_at
        let result = stall_elapsed_secs(Some("not-a-date"), Some(&old), now, 300);
        assert!(result.is_some());
    }

    #[test]
    fn stall_returns_none_when_both_timestamps_malformed() {
        let now = chrono::Utc::now();
        let result = stall_elapsed_secs(Some("nope"), Some("also-nope"), now, 300);
        assert!(result.is_none());
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
