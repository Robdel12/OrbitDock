use std::time::Duration;

/// Compute exponential backoff delay for a retry attempt.
///
/// Formula: min(10_000 * 2^min(attempt-1, 10), max_backoff_ms)
/// Attempt 1 → 10s, attempt 2 → 20s, attempt 3 → 40s, ...
///
/// Used by the retry queue to calculate backoff between attempts.
pub(crate) fn compute_delay(attempt: u32, max_backoff_ms: u64) -> Duration {
  if attempt == 0 {
    return Duration::from_millis(0);
  }
  let exponent = std::cmp::min(attempt.saturating_sub(1), 10);
  let base_ms = 10_000u64.saturating_mul(1u64 << exponent);
  let clamped = std::cmp::min(base_ms, max_backoff_ms);
  Duration::from_millis(clamped)
}

#[cfg(test)]
#[path = "retry_tests.rs"]
mod tests;
