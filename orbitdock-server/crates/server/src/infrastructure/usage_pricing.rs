use orbitdock_protocol::{Provider, TokenUsage};

pub(crate) const USAGE_PRICING_SOURCE: &str = "orbitdock_builtin";
pub(crate) const USAGE_PRICING_VERSION: &str = "2026-04-backbone-v1";

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct UsagePricingSnapshot {
  pub source: &'static str,
  pub version: &'static str,
  pub model_key: Option<String>,
  pub input_cost_per_token: f64,
  pub output_cost_per_token: f64,
  pub cache_read_cost_per_token: f64,
  pub cache_write_cost_per_token: f64,
}

fn snapshot(
  model_key: &str,
  input_cost_per_token: f64,
  output_cost_per_token: f64,
  cache_read_cost_per_token: f64,
  cache_write_cost_per_token: f64,
) -> UsagePricingSnapshot {
  UsagePricingSnapshot {
    source: USAGE_PRICING_SOURCE,
    version: USAGE_PRICING_VERSION,
    model_key: Some(model_key.to_string()),
    input_cost_per_token,
    output_cost_per_token,
    cache_read_cost_per_token,
    cache_write_cost_per_token,
  }
}

pub(crate) fn pricing_snapshot(provider: Provider, model: Option<&str>) -> UsagePricingSnapshot {
  let normalized = model.unwrap_or_default().trim().to_ascii_lowercase();

  if normalized.contains("opus") {
    return snapshot(
      "claude-opus-4",
      15.0 / 1_000_000.0,
      75.0 / 1_000_000.0,
      1.875 / 1_000_000.0,
      18.75 / 1_000_000.0,
    );
  }

  if normalized.contains("sonnet") {
    return snapshot(
      "claude-sonnet-4",
      3.0 / 1_000_000.0,
      15.0 / 1_000_000.0,
      0.30 / 1_000_000.0,
      3.75 / 1_000_000.0,
    );
  }

  if normalized.contains("haiku") {
    return snapshot(
      "claude-3-5-haiku",
      0.8 / 1_000_000.0,
      4.0 / 1_000_000.0,
      0.08 / 1_000_000.0,
      1.0 / 1_000_000.0,
    );
  }

  if normalized.contains("gpt-5") || matches!(provider, Provider::Codex) {
    return snapshot("gpt-5", 2.0 / 1_000_000.0, 10.0 / 1_000_000.0, 0.0, 0.0);
  }

  snapshot(
    "claude-sonnet-4",
    3.0 / 1_000_000.0,
    15.0 / 1_000_000.0,
    0.30 / 1_000_000.0,
    3.75 / 1_000_000.0,
  )
}

pub(crate) fn estimate_cost_usd(
  pricing: &UsagePricingSnapshot,
  input_tokens: u64,
  output_tokens: u64,
  cache_read_tokens: u64,
  cache_write_tokens: u64,
) -> f64 {
  input_tokens as f64 * pricing.input_cost_per_token
    + output_tokens as f64 * pricing.output_cost_per_token
    + cache_read_tokens as f64 * pricing.cache_read_cost_per_token
    + cache_write_tokens as f64 * pricing.cache_write_cost_per_token
}

pub(crate) fn estimate_session_cost(
  provider: Provider,
  model: Option<&str>,
  usage: &TokenUsage,
) -> f64 {
  let pricing = pricing_snapshot(provider, model);
  estimate_cost_usd(
    &pricing,
    usage.input_tokens,
    usage.output_tokens,
    usage.cached_tokens,
    0,
  )
}
