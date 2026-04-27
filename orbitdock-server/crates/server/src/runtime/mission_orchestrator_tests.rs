use super::*;
use crate::domain::mission_control::config::{MissionConfig, ProviderConfig};

fn config_with(
  strategy: &str,
  primary: &str,
  secondary: Option<&str>,
  max_primary: Option<u32>,
) -> MissionConfig {
  MissionConfig {
    provider: ProviderConfig {
      strategy: strategy.to_string(),
      primary: primary.to_string(),
      secondary: secondary.map(|s| s.to_string()),
      max_concurrent: 5,
      max_concurrent_primary: max_primary,
    },
    ..Default::default()
  }
}

#[test]
fn single_always_returns_primary() {
  let config = config_with("single", "claude", None, None);
  let counts = ProviderCounts::new();
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
  assert_eq!(choose_provider(&config, &counts, 5), "claude");
}

#[test]
fn single_ignores_secondary_even_if_set() {
  let config = config_with("single", "claude", Some("codex"), None);
  let counts = ProviderCounts::new();
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
}

#[test]
fn priority_uses_primary_when_under_limit() {
  let config = config_with("priority", "claude", Some("codex"), Some(3));
  let mut counts = ProviderCounts::new();
  counts.increment("claude");
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
}

#[test]
fn priority_overflows_to_secondary_at_limit() {
  let config = config_with("priority", "claude", Some("codex"), Some(2));
  let mut counts = ProviderCounts::new();
  counts.increment("claude");
  counts.increment("claude");
  assert_eq!(choose_provider(&config, &counts, 0), "codex");
}

#[test]
fn priority_falls_back_to_primary_without_secondary() {
  let config = config_with("priority", "claude", None, Some(2));
  let mut counts = ProviderCounts::new();
  counts.increment("claude");
  counts.increment("claude");
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
}

#[test]
fn priority_falls_back_to_primary_without_max_primary() {
  let config = config_with("priority", "claude", Some("codex"), None);
  let mut counts = ProviderCounts::new();
  counts.increment("claude");
  counts.increment("claude");
  counts.increment("claude");
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
}

#[test]
fn round_robin_alternates() {
  let config = config_with("round_robin", "claude", Some("codex"), None);
  let counts = ProviderCounts::new();
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
  assert_eq!(choose_provider(&config, &counts, 1), "codex");
  assert_eq!(choose_provider(&config, &counts, 2), "claude");
  assert_eq!(choose_provider(&config, &counts, 3), "codex");
}

#[test]
fn round_robin_uses_primary_without_secondary() {
  let config = config_with("round_robin", "claude", None, None);
  let counts = ProviderCounts::new();
  assert_eq!(choose_provider(&config, &counts, 0), "claude");
  assert_eq!(choose_provider(&config, &counts, 1), "claude");
}

#[test]
fn unknown_strategy_defaults_to_primary() {
  let config = config_with("banana", "codex", Some("claude"), None);
  let counts = ProviderCounts::new();
  assert_eq!(choose_provider(&config, &counts, 0), "codex");
}
