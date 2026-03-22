import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct StatusBarStatsTests {
  private let costCalculator = TokenCostCalculator(prices: [:])

  @Test func fromAggregatesRootSafeUsageAndCostByModel() {
    let sessions = [
      makeSession(
        id: "claude-1",
        model: "claude-opus-4",
        totalTokens: 15,
        totalCostUSD: 22
      ),
      makeSession(
        id: "gpt-1",
        model: "gpt-5",
        totalTokens: 5,
        totalCostUSD: 18
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

  @Test func fromIgnoresUnknownModelsButKeepsTotals() {
    let sessions = [
      makeSession(
        id: "custom-1",
        model: "openai",
        totalTokens: 7,
        totalCostUSD: 14
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    #expect(stats.tokens == 7)
    #expect(stats.cost == 14)
    #expect(stats.costByModel.isEmpty)
  }

  @Test func fromFallsBackToEstimatedCostWhenRootCostIsMissing() {
    let sessions = [
      makeSession(
        id: "gpt-1",
        model: "gpt-5",
        totalTokens: 1_000_000,
        totalCostUSD: 0
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    #expect(stats.tokens == 1_000_000)
    #expect(stats.cost > 0)
    #expect(stats.costByModel.map(\.model) == ["GPT-5"])
    #expect(stats.costByModel.first?.cost == stats.cost)
  }

  @Test func fromUsesGranularTokenBreakdownForCost() {
    // When input/output breakdown is available, cost should reflect
    // the different rates for input vs output tokens.
    let inputCount = 500_000
    let outputCount = 500_000
    let cachedCount = 100_000

    let sessions = [
      makeSession(
        id: "claude-1",
        model: "claude-sonnet-4",
        totalTokens: inputCount + outputCount,
        inputTokens: inputCount,
        outputTokens: outputCount,
        cachedTokens: cachedCount,
        totalCostUSD: 0
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    // With the fallback calculator (no prices loaded), defaults are:
    // input: $3/M, output: $15/M, cache_read: $0.30/M
    let expectedInput = Double(inputCount) / 1_000_000 * 3.0
    let expectedOutput = Double(outputCount) / 1_000_000 * 15.0
    let expectedCache = Double(cachedCount) / 1_000_000 * 0.30
    let expectedCost = expectedInput + expectedOutput + expectedCache

    #expect(stats.tokens == inputCount + outputCount)
    #expect(abs(stats.cost - expectedCost) < 0.001)
  }

  @Test func fromFallsBackToLegacyWhenNoBreakdown() {
    // When input/output are both 0 (legacy server), falls back to
    // treating totalTokens as input.
    let sessions = [
      makeSession(
        id: "claude-1",
        model: "claude-sonnet-4",
        totalTokens: 1_000_000,
        inputTokens: 0,
        outputTokens: 0,
        cachedTokens: 0,
        totalCostUSD: 0
      ),
    ]

    let stats = StatusBarStats.from(
      sessions: sessions,
      costCalculator: costCalculator
    )

    // Legacy fallback: all tokens treated as input at $3/M
    let expectedCost = Double(1_000_000) / 1_000_000 * 3.0
    #expect(abs(stats.cost - expectedCost) < 0.001)
  }

  private func makeSession(
    id: String,
    model: String,
    totalTokens: Int,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cachedTokens: Int = 0,
    totalCostUSD: Double
  ) -> RootSessionNode {
    RootSessionNode(
      sessionId: id,
      sessionRef: SessionRef(endpointId: UUID(), sessionId: id),
      endpointName: "Local",
      endpointConnectionStatus: .connected,
      provider: .codex,
      status: .active,
      workStatus: .working,
      attentionReason: .none,
      listStatus: .working,
      displayStatus: .working,
      title: id,
      titleSortKey: id.lowercased(),
      searchText: id,
      customName: nil,
      contextLine: nil,
      projectPath: "/tmp/\(id)",
      projectName: id,
      projectKey: "/tmp/\(id)",
      branch: nil,
      model: model,
      startedAt: nil,
      lastActivityAt: nil,
      unreadCount: 0,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: nil,
      isWorktree: false,
      worktreeId: nil,
      codexIntegrationMode: .direct,
      claudeIntegrationMode: nil,
      effort: nil,
      missionId: nil,
      issueIdentifier: nil,
      totalTokens: totalTokens,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      totalCostUSD: totalCostUSD,
      isActive: true,
      showsInMissionControl: true,
      needsAttention: false,
      isReady: false,
      allowsUserNotifications: true
    )
  }
}
