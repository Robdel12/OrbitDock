//! Worktree health assessment and auto-prune lifecycle.
//!
//! Pure health assessment is separated from I/O so it can be tested without
//! a database or filesystem. The health check cycle runs periodically in the
//! background.

use std::time::Duration;

use orbitdock_protocol::WorktreeStatus;

// ---------------------------------------------------------------------------
// Pure health assessment
// ---------------------------------------------------------------------------

/// Result of assessing a worktree's health.
#[allow(dead_code)] // Used by health check cycle
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeHealthAssessment {
    pub current_status: WorktreeStatus,
    pub recommended_status: WorktreeStatus,
    pub reason: String,
    pub should_prune: bool,
}

/// Assess the health of a worktree and recommend a status transition.
///
/// This is a **pure function** — no I/O, fully deterministic, easy to test.
/// Times are Unix epoch seconds to avoid external dependencies.
///
/// Status transitions:
/// - Has active sessions → `Active`
/// - No sessions, within TTL → `Orphaned`
/// - No sessions, beyond TTL → `Stale` (with `should_prune = auto_prune`)
/// - Disk gone → `Removed` (any state)
/// - Terminal states (`Removed`, `Removing`) → no-op
#[allow(dead_code)] // Used by health check cycle (background scheduler)
pub fn assess_worktree_health(
    current_status: WorktreeStatus,
    disk_present: bool,
    active_session_count: u32,
    last_session_ended_at_epoch: Option<i64>,
    auto_prune: bool,
    stale_ttl: Duration,
    now_epoch: i64,
) -> WorktreeHealthAssessment {
    // Terminal states: no transitions
    if matches!(
        current_status,
        WorktreeStatus::Removed | WorktreeStatus::Removing
    ) {
        return WorktreeHealthAssessment {
            current_status,
            recommended_status: current_status,
            reason: "terminal state".to_string(),
            should_prune: false,
        };
    }

    // Disk gone → Removed regardless of other state
    if !disk_present {
        return WorktreeHealthAssessment {
            current_status,
            recommended_status: WorktreeStatus::Removed,
            reason: "disk no longer present".to_string(),
            should_prune: false,
        };
    }

    // Has active sessions → Active
    if active_session_count > 0 {
        return WorktreeHealthAssessment {
            current_status,
            recommended_status: WorktreeStatus::Active,
            reason: format!("{active_session_count} active session(s)"),
            should_prune: false,
        };
    }

    // No active sessions — check TTL
    let ttl_secs = stale_ttl.as_secs() as i64;
    match last_session_ended_at_epoch {
        Some(ended_at) => {
            let elapsed = now_epoch - ended_at;
            if elapsed > ttl_secs {
                WorktreeHealthAssessment {
                    current_status,
                    recommended_status: WorktreeStatus::Stale,
                    reason: format!("no sessions for {elapsed}s"),
                    should_prune: auto_prune,
                }
            } else {
                WorktreeHealthAssessment {
                    current_status,
                    recommended_status: WorktreeStatus::Orphaned,
                    reason: "no active sessions, within TTL".to_string(),
                    should_prune: false,
                }
            }
        }
        None => {
            // No last_session_ended_at — stays Orphaned (no TTL to compare)
            WorktreeHealthAssessment {
                current_status,
                recommended_status: WorktreeStatus::Orphaned,
                reason: "no sessions, no end timestamp".to_string(),
                should_prune: false,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_768_478_400; // 2026-01-15T12:00:00Z

    fn ttl_24h() -> Duration {
        Duration::from_secs(86400)
    }

    #[test]
    fn active_stays_active_with_sessions() {
        let result =
            assess_worktree_health(WorktreeStatus::Active, true, 2, None, true, ttl_24h(), NOW);
        assert_eq!(result.recommended_status, WorktreeStatus::Active);
        assert!(!result.should_prune);
    }

    #[test]
    fn active_becomes_orphaned_no_sessions_within_ttl() {
        let ended = NOW - 6 * 3600; // 6 hours ago
        let result = assess_worktree_health(
            WorktreeStatus::Active,
            true,
            0,
            Some(ended),
            true,
            ttl_24h(),
            NOW,
        );
        assert_eq!(result.recommended_status, WorktreeStatus::Orphaned);
        assert!(!result.should_prune);
    }

    #[test]
    fn orphaned_becomes_stale_beyond_ttl() {
        let ended = NOW - 30 * 3600; // 30 hours ago
        let result = assess_worktree_health(
            WorktreeStatus::Orphaned,
            true,
            0,
            Some(ended),
            true,
            ttl_24h(),
            NOW,
        );
        assert_eq!(result.recommended_status, WorktreeStatus::Stale);
        assert!(result.should_prune);
    }

    #[test]
    fn stale_auto_prune_false_does_not_prune() {
        let ended = NOW - 48 * 3600; // 48 hours ago
        let result = assess_worktree_health(
            WorktreeStatus::Stale,
            true,
            0,
            Some(ended),
            false,
            ttl_24h(),
            NOW,
        );
        assert_eq!(result.recommended_status, WorktreeStatus::Stale);
        assert!(!result.should_prune);
    }

    #[test]
    fn any_state_disk_gone_becomes_removed() {
        for status in [
            WorktreeStatus::Active,
            WorktreeStatus::Orphaned,
            WorktreeStatus::Stale,
        ] {
            let result = assess_worktree_health(status, false, 0, None, true, ttl_24h(), NOW);
            assert_eq!(result.recommended_status, WorktreeStatus::Removed);
            assert!(!result.should_prune);
        }
    }

    #[test]
    fn terminal_states_are_idempotent() {
        for status in [WorktreeStatus::Removed, WorktreeStatus::Removing] {
            let result = assess_worktree_health(status, true, 3, None, true, ttl_24h(), NOW);
            assert_eq!(result.recommended_status, status);
            assert!(!result.should_prune);
        }
    }

    #[test]
    fn no_last_session_ended_stays_orphaned() {
        let result =
            assess_worktree_health(WorktreeStatus::Active, true, 0, None, true, ttl_24h(), NOW);
        assert_eq!(result.recommended_status, WorktreeStatus::Orphaned);
        assert!(!result.should_prune);
    }

    #[test]
    fn disk_gone_overrides_active_sessions() {
        let result = assess_worktree_health(
            WorktreeStatus::Active,
            false,
            5,
            None,
            false,
            ttl_24h(),
            NOW,
        );
        assert_eq!(result.recommended_status, WorktreeStatus::Removed);
    }
}
