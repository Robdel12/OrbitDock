use std::time::Duration;

/// Compute exponential backoff delay for a retry attempt.
///
/// Formula: min(10_000 * 2^min(attempt-1, 10), max_backoff_ms)
/// Attempt 1 → 10s, attempt 2 → 20s, attempt 3 → 40s, ...
///
/// Used by the retry queue to calculate backoff between attempts.
#[allow(dead_code)]
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
mod tests {
    use super::*;

    #[test]
    fn attempt_zero_is_immediate() {
        assert_eq!(compute_delay(0, 300_000), Duration::from_millis(0));
    }

    #[test]
    fn attempt_one_is_10s() {
        assert_eq!(compute_delay(1, 300_000), Duration::from_secs(10));
    }

    #[test]
    fn attempt_two_is_20s() {
        assert_eq!(compute_delay(2, 300_000), Duration::from_secs(20));
    }

    #[test]
    fn attempt_three_is_40s() {
        assert_eq!(compute_delay(3, 300_000), Duration::from_secs(40));
    }

    #[test]
    fn respects_max_backoff() {
        let delay = compute_delay(20, 60_000);
        assert_eq!(delay, Duration::from_millis(60_000));
    }

    #[test]
    fn exponent_capped_at_10() {
        let d10 = compute_delay(11, u64::MAX);
        let d20 = compute_delay(21, u64::MAX);
        assert_eq!(d10, d20);
    }
}
