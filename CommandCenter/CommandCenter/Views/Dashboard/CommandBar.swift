//
//  CommandBar.swift
//  OrbitDock
//
//  Mission control command bar - rich stats strip at top of dashboard
//  Shows subscription usage, today's activity, and all-time totals
//

import SwiftUI

struct CommandBar: View {
  let sessions: [Session]

  /// Calculate today's stats
  private var todayStats: TodayStats {
    let calendar = Calendar.current
    let todaySessions = sessions.filter {
      guard let start = $0.startedAt else { return false }
      return calendar.isDateInToday(start)
    }

    // Get session IDs that started today
    let todayIds = Set(todaySessions.map(\.id))

    // Get stats for today's sessions from MessageStore
    let allStats = MessageStore.shared.readAllSessionStats()
    let todayStatsFiltered = allStats.filter { todayIds.contains($0.sessionId) }

    let cost = todayStatsFiltered.reduce(0) { $0 + $1.stats.estimatedCostUSD }
    let tokens = todayStatsFiltered.reduce(0) { $0 + $1.stats.inputTokens + $1.stats.outputTokens }

    return TodayStats(
      sessionCount: todaySessions.count,
      cost: cost,
      tokens: tokens
    )
  }

  /// All-time aggregate stats
  private var allTimeStats: AllTimeStats {
    let allStats = MessageStore.shared.readAllSessionStats()
    let totalCost = allStats.reduce(0) { $0 + $1.stats.estimatedCostUSD }
    let totalTokens = allStats.reduce(0) { $0 + $1.stats.inputTokens + $1.stats.outputTokens }
    return AllTimeStats(
      sessionCount: sessions.count,
      cost: totalCost,
      tokens: totalTokens
    )
  }

  /// Model distribution for the mini chart
  private var modelDistribution: ModelDistribution {
    var opus = 0
    var sonnet = 0
    var haiku = 0

    for session in sessions {
      guard let model = session.model?.lowercased() else { continue }
      if model.contains("opus") { opus += 1 }
      else if model.contains("sonnet") { sonnet += 1 }
      else if model.contains("haiku") { haiku += 1 }
    }

    return ModelDistribution(opus: opus, sonnet: sonnet, haiku: haiku)
  }

  var body: some View {
    HStack(spacing: 0) {
      // Subscription Usage - Hero section
      SubscriptionUsagePanel()

      verticalDivider

      // Today's Activity
      TodayPanel(stats: todayStats)

      verticalDivider

      // All-Time Totals
      AllTimePanel(stats: allTimeStats, modelDistribution: modelDistribution)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 20)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.6))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(0.3), lineWidth: 1)
        )
    )
  }

  private var verticalDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(0.3))
      .frame(width: 1)
      .padding(.vertical, 4)
      .padding(.horizontal, 20)
  }
}

// MARK: - Data Models

private struct TodayStats {
  let sessionCount: Int
  let cost: Double
  let tokens: Int
}

private struct AllTimeStats {
  let sessionCount: Int
  let cost: Double
  let tokens: Int
}

private struct ModelDistribution {
  let opus: Int
  let sonnet: Int
  let haiku: Int

  var total: Int {
    opus + sonnet + haiku
  }

  var opusPercent: Double {
    total > 0 ? Double(opus) / Double(total) : 0
  }

  var sonnetPercent: Double {
    total > 0 ? Double(sonnet) / Double(total) : 0
  }

  var haikuPercent: Double {
    total > 0 ? Double(haiku) / Double(total) : 0
  }
}

// MARK: - Subscription Usage Panel

private struct SubscriptionUsagePanel: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Section label
      HStack(spacing: 6) {
        Image(systemName: "gauge.with.needle")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("RATE LIMITS")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.tertiary)
          .tracking(0.5)

        // Plan badge inline with header
        if let plan = service.usage?.planName {
          Text(plan)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accent.opacity(0.12), in: Capsule())
        }
      }

      if let usage = service.usage {
        HStack(spacing: 16) {
          // 5-hour window
          RateLimitCard(
            window: usage.fiveHour,
            label: "5-Hour",
            shortLabel: "5h"
          )

          // 7-day window
          if let sevenDay = usage.sevenDay {
            RateLimitCard(
              window: sevenDay,
              label: "7-Day",
              shortLabel: "7d"
            )
          }
        }
      } else if service.isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading...")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .frame(height: 60)
      } else {
        Text("—")
          .foregroundStyle(.quaternary)
      }
    }
  }
}

// MARK: - Rate Limit Card (Redesigned)

private struct RateLimitCard: View {
  let window: SubscriptionUsage.Window
  let label: String
  let shortLabel: String

  private var value: Double { window.utilization }
  private var projected: Double { window.projectedAtReset }

  /// Format reset time
  private var resetsAtFormatted: String? {
    guard let resetsAt = window.resetsAt else { return nil }
    let formatter = DateFormatter()
    if shortLabel == "7d", !Calendar.current.isDateInToday(resetsAt) {
      formatter.dateFormat = "EEE h:mm a"
    } else {
      formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: resetsAt)
  }

  /// Time until reset
  private var timeUntilReset: TimeInterval {
    guard let resetsAt = window.resetsAt else { return .infinity }
    return resetsAt.timeIntervalSinceNow
  }

  /// Color for current usage
  private var usageColor: Color {
    if value >= 90 { return .statusError }
    if value >= 70 { return .statusWaiting }
    return .accent
  }

  /// Color for projected usage
  private var projectedColor: Color {
    if projected >= 100 { return .statusError }
    if projected >= 90 { return .statusWaiting }
    return .statusSuccess
  }

  /// Color for reset time based on urgency
  private var resetTimeColor: Color {
    if timeUntilReset < 15 * 60 { return .statusError }
    if timeUntilReset < 60 * 60 { return .statusWaiting }
    return .secondary.opacity(0.5)
  }

  /// Will exceed limit?
  private var willExceed: Bool { projected > 95 }

  /// Status message
  private var statusMessage: String {
    if projected >= 100 { return "Maxing out!" }
    if projected >= 90 { return "Heavy pace" }
    if projected >= 70 { return "Moderate" }
    return "On track"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Top row: Label + Current usage
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(shortLabel)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)

        // Current usage - hero number
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text("\(Int(value))")
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(usageColor)
          Text("%")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(usageColor.opacity(0.7))
        }
      }

      // Progress bar with projection
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          // Background
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          // Projected (behind current)
          if projected > value {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(projectedColor.opacity(willExceed ? 0.4 : 0.25))
              .frame(width: geo.size.width * min(1, projected / 100))
          }

          // Current usage
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(usageColor)
            .frame(width: geo.size.width * min(1, value / 100))
        }
      }
      .frame(maxWidth: 140)
      .frame(height: 5)

      // Bottom row: Status + Reset time
      HStack(spacing: 6) {
        if willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9))
            .foregroundStyle(Color.statusError)
        }

        Text(statusMessage)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(projectedColor)
          .fixedSize()

        if projected > value + 5, projected < 100 {
          Text("→ \(Int(projected))%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(projectedColor.opacity(0.8))
        }

        if let resetTime = resetsAtFormatted {
          Text("@ \(resetTime)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(resetTimeColor)
        }
      }
    }
  }
}

// MARK: - Today Panel

private struct TodayPanel: View {
  let stats: TodayStats

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section label
      HStack(spacing: 6) {
        Image(systemName: "sun.max.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.statusWaiting)

        Text("TODAY")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.tertiary)
          .tracking(0.5)
      }

      HStack(spacing: 20) {
        // Sessions
        StatBlock(
          value: "\(stats.sessionCount)",
          label: "sessions",
          icon: "cpu"
        )

        // Cost
        StatBlock(
          value: formatCost(stats.cost),
          label: "spent",
          icon: "dollarsign.circle"
        )

        // Tokens
        StatBlock(
          value: formatTokens(stats.tokens),
          label: "tokens",
          icon: "textformat"
        )
      }
    }
  }

  private func formatCost(_ cost: Double) -> String {
    if cost >= 100 {
      return String(format: "$%.0f", cost)
    } else if cost >= 10 {
      return String(format: "$%.1f", cost)
    } else if cost >= 1 {
      return String(format: "$%.2f", cost)
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

// MARK: - All Time Panel

private struct AllTimePanel: View {
  let stats: AllTimeStats
  let modelDistribution: ModelDistribution

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section label
      HStack(spacing: 6) {
        Image(systemName: "tray.full.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.accent.opacity(0.7))

        Text("TRACKED")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.tertiary)
          .tracking(0.5)
      }

      HStack(spacing: 20) {
        // Total cost
        StatBlock(
          value: formatCost(stats.cost),
          label: "total",
          icon: "dollarsign.circle.fill",
          color: .statusSuccess
        )

        // Total tokens
        StatBlock(
          value: formatTokens(stats.tokens),
          label: "tokens",
          icon: "textformat.abc"
        )

        // Sessions
        StatBlock(
          value: "\(stats.sessionCount)",
          label: "sessions",
          icon: "cpu.fill"
        )

        // Model distribution mini chart
        if modelDistribution.total > 0 {
          ModelDistributionChart(distribution: modelDistribution)
        }
      }
    }
  }

  private func formatCost(_ cost: Double) -> String {
    if cost >= 1_000 {
      return String(format: "$%.1fK", cost / 1_000)
    } else if cost >= 100 {
      return String(format: "$%.0f", cost)
    } else if cost >= 10 {
      return String(format: "$%.1f", cost)
    }
    return String(format: "$%.2f", cost)
  }

  private func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000_000 {
      return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
    } else if tokens >= 1_000_000 {
      return String(format: "%.0fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
      return String(format: "%.0fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
  }
}

// MARK: - Stat Block

private struct StatBlock: View {
  let value: String
  let label: String
  let icon: String
  var color: Color = .primary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Value
      Text(value)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .foregroundStyle(color.opacity(0.9))

      // Label with icon
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .medium))
        Text(label)
          .font(.system(size: 9, weight: .medium))
      }
      .foregroundStyle(.tertiary)
    }
  }
}

// MARK: - Model Distribution Chart

private struct ModelDistributionChart: View {
  let distribution: ModelDistribution

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Section label
      Text("MODELS")
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(.quaternary)
        .tracking(0.5)

      // Legend with counts - vertical stack for clarity
      VStack(alignment: .leading, spacing: 4) {
        if distribution.opus > 0 {
          modelRow(name: "Opus", count: distribution.opus, color: .modelOpus)
        }
        if distribution.sonnet > 0 {
          modelRow(name: "Sonnet", count: distribution.sonnet, color: .modelSonnet)
        }
        if distribution.haiku > 0 {
          modelRow(name: "Haiku", count: distribution.haiku, color: .modelHaiku)
        }
      }
    }
  }

  private func modelRow(name: String, count: Int, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(name)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)

      Text("\(count)")
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 24) {
    CommandBar(sessions: [
      Session(
        id: "1",
        projectPath: "/path/a",
        projectName: "project-a",
        model: "claude-opus-4-5-20251101",
        status: .active,
        workStatus: .working,
        startedAt: Date()
      ),
      Session(
        id: "2",
        projectPath: "/path/b",
        projectName: "project-b",
        model: "claude-sonnet-4-20250514",
        status: .active,
        workStatus: .waiting,
        startedAt: Date()
      ),
      Session(
        id: "3",
        projectPath: "/path/c",
        projectName: "project-c",
        model: "claude-sonnet-4-20250514",
        status: .ended,
        workStatus: .unknown,
        startedAt: Date().addingTimeInterval(-86_400)
      ),
      Session(
        id: "4",
        projectPath: "/path/d",
        projectName: "project-d",
        model: "claude-haiku-3-5-20241022",
        status: .ended,
        workStatus: .unknown,
        startedAt: Date().addingTimeInterval(-172_800)
      ),
    ])
  }
  .padding(24)
  .background(Color.backgroundPrimary)
  .frame(width: 900)
}
