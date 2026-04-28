use super::*;

pub(crate) fn snapshot_kind_to_str(kind: TokenUsageSnapshotKind) -> &'static str {
  match kind {
    TokenUsageSnapshotKind::Unknown => "unknown",
    TokenUsageSnapshotKind::ContextTurn => "context_turn",
    TokenUsageSnapshotKind::LifetimeTotals => "lifetime_totals",
    TokenUsageSnapshotKind::Mixed => "mixed",
    TokenUsageSnapshotKind::CompactionReset => "compaction_reset",
  }
}

pub(crate) fn snapshot_kind_from_str(kind: Option<&str>) -> TokenUsageSnapshotKind {
  match kind {
    Some("context_turn") => TokenUsageSnapshotKind::ContextTurn,
    Some("lifetime_totals") => TokenUsageSnapshotKind::LifetimeTotals,
    Some("mixed") => TokenUsageSnapshotKind::Mixed,
    Some("compaction_reset") => TokenUsageSnapshotKind::CompactionReset,
    _ => TokenUsageSnapshotKind::Unknown,
  }
}
