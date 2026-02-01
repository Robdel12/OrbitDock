//
//  StatsSummary.swift
//  OrbitDock
//
//  Summary stats row for dashboard header
//

import SwiftUI

struct StatsSummary: View {
  let sessions: [Session]

  private var workingCount: Int {
    sessions.filter { SessionDisplayStatus.from($0) == .working }.count
  }

  private var attentionCount: Int {
    sessions.filter { SessionDisplayStatus.from($0) == .attention }.count
  }

  private var todayCount: Int {
    sessions.filter {
      guard let start = $0.startedAt else { return false }
      return Calendar.current.isDateInToday(start)
    }.count
  }

  /// Get cost and tokens from MessageStore (calculated from transcripts)
  private var aggregateStats: (cost: Double, tokens: Int) {
    let allStats = MessageStore.shared.readAllSessionStats()
    let cost = allStats.reduce(0) { $0 + $1.stats.estimatedCostUSD }
    let tokens = allStats.reduce(0) { $0 + $1.stats.inputTokens + $1.stats.outputTokens }
    return (cost, tokens)
  }

  var body: some View {
    let stats = aggregateStats

    HStack(spacing: 12) {
      // Subscription usage card
      SubscriptionUsageCard()

      Divider()
        .frame(height: 40)
        .opacity(0.2)

      StatCard(
        value: "\(workingCount)",
        label: "Working",
        color: workingCount > 0 ? .statusWorking : .secondary
      )

      StatCard(
        value: "\(attentionCount)",
        label: "Attention",
        color: attentionCount > 0 ? .statusAttention : .secondary
      )

      StatCard(
        value: "\(todayCount)",
        label: "Today",
        color: .secondary
      )

      StatCard(
        value: formatCost(stats.cost),
        label: "Cost",
        color: .secondary
      )

      StatCard(
        value: formatTokens(stats.tokens),
        label: "Tokens",
        color: .secondary
      )

      Spacer()
    }
  }

  private func formatCost(_ cost: Double) -> String {
    if cost >= 100 {
      return String(format: "$%.0f", cost)
    } else if cost >= 10 {
      return String(format: "$%.1f", cost)
    }
    return String(format: "$%.2f", cost)
  }

  private func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
      return String(format: "%.1fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
      return String(format: "%.0fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
  }
}

// MARK: - Stat Card

struct StatCard: View {
  let value: String
  let label: String
  let color: Color

  var body: some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(color)

      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)
    }
    .frame(minWidth: 70)
    .padding(.vertical, 12)
    .padding(.horizontal, 16)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

// MARK: - Preview

#Preview {
  StatsSummary(sessions: [
    Session(
      id: "1",
      projectPath: "/Users/rob/Developer/vizzly-cli",
      projectName: "vizzly-cli",
      model: "claude-opus-4-5-20251101",
      status: .active,
      workStatus: .working,
      startedAt: Date(),
      totalTokens: 45_000,
      totalCostUSD: 1.20
    ),
    Session(
      id: "2",
      projectPath: "/Users/rob/Developer/backchannel",
      projectName: "backchannel",
      model: "claude-sonnet-4-20250514",
      status: .active,
      workStatus: .waiting,
      startedAt: Date(),
      totalTokens: 12_000,
      totalCostUSD: 0.12
    ),
    Session(
      id: "3",
      projectPath: "/Users/rob/Developer/docs",
      projectName: "docs",
      model: "claude-haiku-3-5-20241022",
      status: .ended,
      workStatus: .unknown,
      startedAt: Date().addingTimeInterval(-86_400),
      endedAt: Date().addingTimeInterval(-82_800),
      totalTokens: 800_000,
      totalCostUSD: 3.20
    ),
  ])
  .padding(24)
  .background(Color.backgroundPrimary)
}
