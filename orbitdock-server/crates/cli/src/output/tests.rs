use chrono::TimeZone;

use super::{relative_time_label_at, truncate};

#[test]
fn truncate_preserves_short_strings() {
  assert_eq!(truncate("OrbitDock", 20), "OrbitDock");
}

#[test]
fn relative_time_label_supports_rfc3339_and_unix_z_formats() {
  let now = chrono::Utc
    .with_ymd_and_hms(2026, 3, 26, 18, 0, 0)
    .single()
    .expect("valid now");

  assert_eq!(
    relative_time_label_at(now, Some("2026-03-26T17:45:00Z")),
    Some("15m ago".to_string())
  );
  assert_eq!(
    relative_time_label_at(now, Some("1774547100Z")),
    Some("15m ago".to_string())
  );
}
