import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct StatusBarStatsTests {
  @Test func resolveUsesAuthoritativeSummaryWhenAvailable() {
    let summary = ServerUsageSummarySnapshotPayload(
      today: ServerUsageSummaryBucketPayload(
        sessionCount: 2,
        distinctSessionCount: 2,
        totalTokens: 1_234,
        inputTokens: 800,
        outputTokens: 434,
        cachedTokens: 120,
        totalCostUSD: 8.5,
        costByModel: [
          ServerUsageSummaryModelCostPayload(model: "GPT-5", costUSD: 5.0),
          ServerUsageSummaryModelCostPayload(model: "Opus", costUSD: 3.5),
        ]
      ),
      allTime: ServerUsageSummaryBucketPayload(
        sessionCount: 4,
        distinctSessionCount: 4,
        totalTokens: 8_765,
        inputTokens: 5_000,
        outputTokens: 3_765,
        cachedTokens: 600,
        totalCostUSD: 27.25,
        costByModel: [
          ServerUsageSummaryModelCostPayload(model: "GPT-5", costUSD: 14.0),
          ServerUsageSummaryModelCostPayload(model: "Opus", costUSD: 13.25),
        ]
      )
    )

    let resolved = StatusBarStats.resolve(
      summary: summary
    )

    #expect(resolved.today.sessionCount == 2)
    #expect(resolved.today.tokens == 1_234)
    #expect(resolved.today.cost == 8.5)
    #expect(resolved.today.costByModel.map { $0.model } == ["GPT-5", "Opus"])
    #expect(resolved.allTime.sessionCount == 4)
    #expect(resolved.allTime.tokens == 8_765)
    #expect(resolved.allTime.cost == 27.25)
  }

  @Test func resolveReturnsEmptyStatsWithoutSummary() {
    let resolved = StatusBarStats.resolve(summary: nil)

    #expect(resolved.today.sessionCount == 0)
    #expect(resolved.today.tokens == 0)
    #expect(resolved.today.cost == 0)
    #expect(resolved.allTime.sessionCount == 0)
    #expect(resolved.allTime.tokens == 0)
    #expect(resolved.allTime.cost == 0)
  }
}
