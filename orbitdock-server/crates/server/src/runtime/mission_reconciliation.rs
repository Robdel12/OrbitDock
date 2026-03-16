//! Mission reconciliation: detect stalled sessions and terminal tracker states.

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
/// - Check for stalled sessions (future: kill + retry)
pub async fn reconcile_mission(
    registry: &Arc<SessionRegistry>,
    tracker: &Arc<dyn Tracker>,
    mission: &MissionRow,
    existing_issues: &[MissionIssueRow],
    _config: &MissionConfig,
) {
    let running_issues: Vec<&MissionIssueRow> = existing_issues
        .iter()
        .filter(|i| i.orchestration_state == "running" || i.orchestration_state == "claimed")
        .collect();

    if running_issues.is_empty() {
        return;
    }

    // Fetch current tracker states for running issues
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
            return;
        }
    };

    for issue_row in &running_issues {
        if let Some(tracker_state) = tracker_states.get(&issue_row.issue_id) {
            // Check if the tracker moved to a terminal state
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

                // End the session if running
                if let Some(ref session_id) = issue_row.session_id {
                    end_session(registry, session_id).await;
                }

                let _ = registry
                    .persist()
                    .send(PersistCommand::MissionIssueUpdateState {
                        id: issue_row.id.clone(),
                        orchestration_state: "completed".to_string(),
                        session_id: None,
                        attempt: None,
                        last_error: None,
                        retry_due_at: None,
                        started_at: None,
                        completed_at: Some(Some(chrono::Utc::now().to_rfc3339())),
                    })
                    .await;
            }
        }
    }
}
