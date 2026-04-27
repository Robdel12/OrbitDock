use super::*;

#[test]
fn compute_delay_matches_expected_curve() {
  let cases = [
    (0, Duration::from_millis(0)),
    (1, Duration::from_secs(10)),
    (2, Duration::from_secs(20)),
    (3, Duration::from_secs(40)),
  ];
  for (attempt, expected) in cases {
    assert_eq!(compute_delay(attempt, 300_000), expected);
  }
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
