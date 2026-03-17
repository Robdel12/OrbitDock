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
                // Ended status is obvious. Also treat Waiting/Reply work_status
                // as "ended" for mission purposes — the agent finished its turn
                // and is idle (no longer actively working on the issue).
                snap.status == orbitdock_protocol::SessionStatus::Ended
                    || matches!(
                        snap.work_status,
                        orbitdock_protocol::WorkStatus::Waiting
                            | orbitdock_protocol::WorkStatus::Ended
                    )
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
                    "Failed to move issue to Done in tracker"
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
        // Use last_activity_at from session, fall back to started_at from issue row.
        // Try parsing each — skip malformed session timestamps and try the fallback.
        let parsed = snap
            .last_activity_at
            .as_deref()
            .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
            .or_else(|| {
                issue_row
                    .started_at
                    .as_deref()
                    .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
            });

        let Some(parsed) = parsed else {
            warn!(
                component = "mission_control",
                event = "reconciliation.no_valid_timestamp",
                mission_id = %mission.id,
                issue_id = %issue_row.issue_id,
                session_id = %session_id,
                last_activity_at = ?snap.last_activity_at,
                started_at = ?issue_row.started_at,
                "No valid timestamp for stall detection"
            );
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

            // Best-effort: post failure comment
            if let Err(err) = tracker
                .create_comment(
                    &issue_row.issue_id,
                    &format!(
                        "OrbitDock session `{session_id}` stalled after {}s of inactivity and was terminated.",
                        elapsed.num_seconds()
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
