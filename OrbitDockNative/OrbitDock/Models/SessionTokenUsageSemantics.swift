import Foundation

enum SessionTokenUsageSemantics {
  nonisolated static func effectiveContextInputTokens(
    inputTokens: Int?,
    cachedTokens: Int?,
    snapshotKind: ServerTokenUsageSnapshotKind,
    provider: Provider
  ) -> Int {
    let input = max(inputTokens ?? 0, 0)
    let cached = max(cachedTokens ?? 0, 0)

    switch snapshotKind {
      case .mixedLegacy:
        return input + cached
      case .compactionReset:
        return 0
      case .contextTurn:
        return provider == .claude ? input + cached : input
      case .lifetimeTotals:
        return input
      case .unknown:
        return provider == .codex ? input : input + cached
    }
  }

  nonisolated static func contextFillFraction(
    contextWindow: Int?,
    effectiveContextInputTokens: Int
  ) -> Double {
    guard let contextWindow, contextWindow > 0 else { return 0 }
    guard effectiveContextInputTokens > 0 else { return 0 }
    return min(Double(effectiveContextInputTokens) / Double(contextWindow), 1.0)
  }

  nonisolated static func effectiveCacheHitPercent(
    inputTokens: Int?,
    cachedTokens: Int?,
    snapshotKind: ServerTokenUsageSnapshotKind,
    effectiveContextInputTokens: Int
  ) -> Double {
    let cached = max(cachedTokens ?? 0, 0)
    guard cached > 0 else { return 0 }

    switch snapshotKind {
      case .mixedLegacy:
        guard effectiveContextInputTokens > 0 else { return 0 }
        return Double(cached) / Double(effectiveContextInputTokens) * 100
      case .compactionReset:
        return 0
      case .contextTurn, .lifetimeTotals, .unknown:
        let input = max(inputTokens ?? 0, 0)
        guard input > 0 else { return 0 }
        return Double(cached) / Double(input) * 100
    }
  }

  nonisolated static func hasTokenUsage(
    inputTokens: Int?,
    outputTokens: Int?,
    cachedTokens: Int?
  ) -> Bool {
    (inputTokens ?? 0) > 0 || (outputTokens ?? 0) > 0 || (cachedTokens ?? 0) > 0
  }
}
