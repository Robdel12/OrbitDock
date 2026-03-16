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

  private func makeSession(
    id: String,
    model: String,
    totalTokens: Int,
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
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: true,
      showsInMissionControl: true,
      needsAttention: false,
      isReady: false,
      allowsUserNotifications: true
    )
  }
}
