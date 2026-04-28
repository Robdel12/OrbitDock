use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct NormalizedUsageLedgerEntry {
  pub billable_input_tokens: u64,
  pub billable_output_tokens: u64,
  pub cache_read_tokens: u64,
  pub cache_write_tokens: u64,
  pub context_input_tokens: u64,
  pub context_window: u64,
}

pub(crate) fn normalize_usage_for_ledger(
  previous: Option<&TokenUsage>,
  current: &TokenUsage,
  snapshot_kind: TokenUsageSnapshotKind,
) -> NormalizedUsageLedgerEntry {
  let prev_input = previous.map(|usage| usage.input_tokens).unwrap_or(0);
  let prev_output = previous.map(|usage| usage.output_tokens).unwrap_or(0);
  let prev_cached = previous.map(|usage| usage.cached_tokens).unwrap_or(0);

  match snapshot_kind {
    TokenUsageSnapshotKind::ContextTurn => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens.saturating_sub(prev_input),
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens.saturating_sub(prev_cached),
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::LifetimeTotals => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens.saturating_sub(prev_input),
      billable_output_tokens: current.output_tokens.saturating_sub(prev_output),
      cache_read_tokens: current.cached_tokens.saturating_sub(prev_cached),
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::Mixed => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens,
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens,
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens.saturating_add(current.cached_tokens),
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::CompactionReset => NormalizedUsageLedgerEntry {
      billable_input_tokens: 0,
      billable_output_tokens: current.output_tokens.saturating_sub(prev_output),
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      context_input_tokens: 0,
      context_window: current.context_window,
    },
    TokenUsageSnapshotKind::Unknown => NormalizedUsageLedgerEntry {
      billable_input_tokens: current.input_tokens,
      billable_output_tokens: current.output_tokens,
      cache_read_tokens: current.cached_tokens,
      cache_write_tokens: 0,
      context_input_tokens: current.input_tokens,
      context_window: current.context_window,
    },
  }
}
