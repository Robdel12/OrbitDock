pub(crate) fn chrono_now() -> String {
  use std::time::{SystemTime, UNIX_EPOCH};

  let duration = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default();

  // Format as ISO 8601
  let secs = duration.as_secs();
  time_to_iso8601(secs)
}

/// Convert Unix timestamp to ISO 8601 string
fn time_to_iso8601(secs: u64) -> String {
  // Simple implementation - for production use chrono crate
  let days_since_epoch = secs / 86400;
  let time_of_day = secs % 86400;

  let hours = time_of_day / 3600;
  let minutes = (time_of_day % 3600) / 60;
  let seconds = time_of_day % 60;

  // Calculate year, month, day from days since epoch (1970-01-01)
  let mut days = days_since_epoch as i64;
  let mut year = 1970i64;

  loop {
    let days_in_year = if is_leap_year(year) { 366 } else { 365 };
    if days < days_in_year {
      break;
    }
    days -= days_in_year;
    year += 1;
  }

  let mut month = 1;
  let days_in_months = if is_leap_year(year) {
    [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  } else {
    [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  };

  for days_in_month in days_in_months {
    if days < days_in_month {
      break;
    }
    days -= days_in_month;
    month += 1;
  }

  let day = days + 1;

  format!(
    "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
    year, month, day, hours, minutes, seconds
  )
}

fn is_leap_year(year: i64) -> bool {
  (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
}
