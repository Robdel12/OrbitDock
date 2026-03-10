import Foundation
import Testing
@testable import OrbitDock

struct StatusBarStatsTests {
  private let costCalculator = TokenCostCalculator(
    prices: [
      "claude-opus-4": ModelPrice(
        inputCostPerToken: 1.0,
        outputCostPerToken: 2.0,
        cacheReadInputTokenCost: 0.5,
        cacheCreationInputTokenCost: 4.0
      ),
      "gpt-5": ModelPrice(
        inputCostPerToken: 3.0,
        outputCostPerToken: 4.0,
        cacheReadInputTokenCost: nil,
        cacheCreationInputTokenCost: nil
      ),
    ]
  )

  @Test func fromAggregatesUsageAndCostByModelWithoutSharedPricingService() {
    let sessions = [
      makeSession(
        id: "claude-1",
        model: "claude-opus-4",
        inputTokens: 10,
        outputTokens: 5,
        cachedTokens: 4
      ),
      makeSession(
        id: "gpt-1",
        model: "gpt-5",
        inputTokens: 2,
        outputTokens: 3,
        cachedTokens: 0
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    #expect(stats.sessionCount == 2)
    #expect(stats.tokens == 20)
    #expect(stats.cost == 40)
    #expect(stats.costByModel.map(\.model) == ["Opus", "GPT-5"])
    #expect(stats.costByModel.map(\.cost) == [22, 18])
  }

  @Test func fromFallsBackToTotalTokensWhenServerUsageIsMissing() {
    let sessions = [
      makeSession(
        id: "legacy",
        model: "claude-opus-4",
        totalTokens: 7
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    #expect(stats.tokens == 7)
    #expect(stats.cost == 14)
    #expect(stats.costByModel.map(\.model) == ["Opus"])
    #expect(stats.costByModel.map(\.cost) == [14])
  }

  private func makeSession(
    id: String,
    model: String,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedTokens: Int? = nil,
    totalTokens: Int = 0
  ) -> Session {
    Session(
      id: id,
      endpointId: UUID(),
      endpointName: "Local",
      projectPath: "/tmp/\(id)",
      projectName: id,
      model: model,
      status: .active,
      workStatus: .waiting,
      totalTokens: totalTokens,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens
    )
  }
}
