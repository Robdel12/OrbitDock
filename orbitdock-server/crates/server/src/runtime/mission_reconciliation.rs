//! Mission reconciliation: detect stalled sessions and terminal tracker states.

use std::collections::HashSet;
use std::sync::Arc;

use tracing::{info, warn};

use crate::domain::mission_control::config::MissionConfig;
use crate::domain::mission_control::tracker::Tracker;
use crate::infrastructure::persistence::mission_control::{MissionIssueRow, MissionRow};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_mutations::end_session;
use crate::runtime::session_registry::SessionRegistry;

/// Terminal tracker states — if an issue moves to one of these, stop working.
const TERMINAL_STATES: &[&str] = &["Done", "Canceled", "Cancelled", "Duplicate", "Won't Fix"];

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
) {
    let running_issues: Vec<&MissionIssueRow> = existing_issues
        .iter()
        .filter(|i| i.orchestration_state == "running" || i.orchestration_state == "claimed")
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
            if TERMINAL_STATES
                .iter()
                .any(|s| s.eq_ignore_ascii_case(tracker_state))
            {
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

            handled_issue_ids.insert(issue_row.issue_id.clone());
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
        // Use last_activity_at from session, fall back to started_at from issue row
        let last_active = snap
            .last_activity_at
            .as_deref()
            .or(issue_row.started_at.as_deref());

        let Some(ts) = last_active else {
            continue;
        };

        let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(ts) else {
            continue;
        };

        let elapsed = chrono::Utc::now() - parsed.with_timezone(&chrono::Utc);
        if elapsed.num_seconds() > stall_timeout_secs as i64 {
            warn!(
                component = "mission_control",
                event = "reconciliation.stall_detected",
                mission_id = %mission.id,
                issue_id = %issue_row.issue_id,
                session_id = %session_id,
                elapsed_secs = elapsed.num_seconds(),
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
                        elapsed.num_seconds()
                    ))),
                    retry_due_at: None,
                    started_at: None,
                    completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
                })
                .await;
        }
    }
}
