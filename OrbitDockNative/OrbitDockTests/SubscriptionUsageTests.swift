@testable import OrbitDock
import Foundation
import Testing

struct SubscriptionUsageTests {
  @Test func windowsIncludeClaudeBucketsInProviderOrder() {
    let usage = SubscriptionUsage(
      fiveHour: .init(utilization: 11, resetsAt: nil, windowDuration: 5 * 3_600),
      sevenDay: .init(utilization: 49, resetsAt: nil, windowDuration: 7 * 24 * 3_600),
      sevenDaySonnet: .init(utilization: 2, resetsAt: nil, windowDuration: 7 * 24 * 3_600),
      sevenDayOpus: .init(utilization: 1, resetsAt: nil, windowDuration: 7 * 24 * 3_600),
      fetchedAt: Date(),
      rateLimitTier: "default_claude_max_5x"
    )

    #expect(usage.windows.map(\.id) == ["claude-session", "claude-all-models", "claude-sonnet", "claude-opus"])
    #expect(usage.windows.map(\.label) == ["Session", "All", "Sonnet", "Opus"])
  }

  @Test func windowsSkipMissingClaudeBuckets() {
    let usage = SubscriptionUsage(
      fiveHour: .init(utilization: 11, resetsAt: nil, windowDuration: 5 * 3_600),
      sevenDay: nil,
      sevenDaySonnet: .init(utilization: 2, resetsAt: nil, windowDuration: 7 * 24 * 3_600),
      sevenDayOpus: nil,
      fetchedAt: Date(),
      rateLimitTier: "default_claude_max_5x"
    )

    #expect(usage.windows.map(\.id) == ["claude-session", "claude-sonnet"])
  }
}
