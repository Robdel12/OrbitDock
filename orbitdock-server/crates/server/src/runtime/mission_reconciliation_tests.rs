use super::*;

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

#[test]
fn terminal_states_covers_expected_set() {
  let expected = vec!["Done", "Canceled", "Cancelled", "Duplicate", "Won't Fix"];
  assert_eq!(TERMINAL_STATES.len(), expected.len());
  for state in &expected {
    assert!(
      TERMINAL_STATES.contains(state),
      "Expected TERMINAL_STATES to contain {state:?}"
    );
  }
}
