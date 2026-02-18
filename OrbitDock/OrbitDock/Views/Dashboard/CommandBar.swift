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
  @State private var showDetails = false

  /// Calculate today's stats
  private var todayStats: DetailedStats {
    let calendar = Calendar.current
    let todaySessions = sessions.filter {
      guard let start = $0.startedAt else { return false }
      return calendar.isDateInToday(start)
    }
    return DetailedStats.from(sessions: todaySessions)
  }

  /// All-time aggregate stats
  private var trackedStats: DetailedStats {
    DetailedStats.from(sessions: sessions)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Always-visible compact stats + usage bar
      HStack(spacing: 0) {
        // Left: Today headline cost + supporting stats
        HStack(spacing: 5) {
          Text("TODAY")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(1.0)

          Text(formatCostCompact(todayStats.cost))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textPrimary)

          compactStat(value: "\(todayStats.sessionCount)", label: "sessions")
          compactStat(value: formatCompactTokens(todayStats.tokens), label: "tokens")
        }

        thinDivider

        // Center: All-time
        HStack(spacing: 5) {
          Text("ALL")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
            .tracking(1.0)

          Text(formatCostCompact(trackedStats.cost))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textPrimary)

          compactStat(value: "\(trackedStats.sessionCount)", label: "sessions")
          compactStat(value: formatCompactTokens(trackedStats.tokens), label: "tokens")
        }

        Spacer(minLength: 16)

        // Right: Usage gauges (always visible)
        UsageGaugesPanel()

        // Details toggle
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showDetails.toggle()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(showDetails ? Color.accent : Color.white.opacity(0.42))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Toggle detailed breakdown")
      }
      .padding(.horizontal, 2)
      .padding(.vertical, 10)

      // Expandable detail panels
      if showDetails {
        HStack(alignment: .top, spacing: 16) {
          StatsDetailPanel(
            stats: todayStats,
            title: "Today",
            icon: "sun.max.fill",
            accentColor: .statusWaiting
          )
          .frame(maxWidth: .infinity)

          StatsDetailPanel(
            stats: trackedStats,
            title: "All-Time",
            icon: "tray.full.fill",
            accentColor: .accent
          )
          .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.4))
        )
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetails)
  }

  private func compactStat(value: String, label: String) -> some View {
    HStack(spacing: 3) {
      Text(value)
        .font(.system(size: TypeScale.subhead, weight: .bold, design: .rounded))
        .foregroundStyle(.primary.opacity(0.85))
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
  }

  private func formatCostCompact(_ cost: Double) -> String {
    if cost >= 1_000 { return String(format: "$%.1fK", cost / 1_000) }
    if cost >= 100 { return String(format: "$%.0f", cost) }
    if cost >= 10 { return String(format: "$%.1f", cost) }
    return String(format: "$%.2f", cost)
  }

  private func formatCompactTokens(_ value: Int) -> String {
    if value <= 0 { return "0" }
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
  }

  private var thinDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(0.25))
      .frame(width: 1)
      .padding(.vertical, 4)
      .padding(.horizontal, 12)
  }
}

// MARK: - Usage Gauges Panel (integrated into command bar)

private struct UsageGaugesPanel: View {
  let registry = UsageServiceRegistry.shared

  var body: some View {
    HStack(spacing: 16) {
      ForEach(registry.allProviders) { provider in
        ProviderGaugeMini(
          provider: provider,
          windows: registry.windows(for: provider),
          isLoading: registry.isLoading(for: provider)
        )
      }
    }
  }
}

private struct ProviderGaugeMini: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Provider header
      HStack(spacing: 5) {
        Image(systemName: provider.icon)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.code, weight: .bold))
          .foregroundStyle(.primary)
      }

      if !windows.isEmpty {
        HStack(spacing: 12) {
          ForEach(windows) { window in
            MiniGauge(window: window, provider: provider)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Text("—")
          .font(.system(size: 11))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(minWidth: 160)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(provider.accentColor.opacity(0.06))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(provider.accentColor.opacity(0.10), lineWidth: 1)
        )
    )
  }
}

private struct MiniGauge: View {
  let window: RateLimitWindow
  let provider: Provider

  private var usageColor: Color {
    provider.color(for: window.utilization)
  }

  private var projectedColor: Color {
    if window.projectedAtReset >= 100 { return .statusError }
    if window.projectedAtReset >= 90 { return .statusWaiting }
    return .statusSuccess
  }

  private var paceLabel: String {
    switch window.paceStatus {
      case .critical: "Critical!"
      case .exceeding: "Heavy"
      case .borderline: "Moderate"
      case .onTrack: "On track"
      case .relaxed: "Light"
      case .unknown: ""
    }
  }

  private var showProjection: Bool {
    window.projectedAtReset > window.utilization + 5
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Label + percentage
      HStack(spacing: 6) {
        Text(window.label)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)
      }
      .lineLimit(1)

      // Progress bar with projection
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.primary.opacity(0.1))

          // Projected (behind current)
          if showProjection {
            RoundedRectangle(cornerRadius: 2)
              .fill(projectedColor.opacity(0.3))
              .frame(width: geo.size.width * min(1, window.projectedAtReset / 100))
          }

          RoundedRectangle(cornerRadius: 2)
            .fill(usageColor)
            .frame(width: geo.size.width * min(1, window.utilization / 100))
        }
      }
      .frame(width: 70, height: 5)

      // Pace + projection
      HStack(spacing: 4) {
        if !paceLabel.isEmpty {
          Text(paceLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(projectedColor)
        }

        if showProjection {
          Text("→\(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(projectedColor.opacity(0.8))
        }
      }
      .lineLimit(1)
    }
  }
}

// MARK: - Data Models

private struct DetailedStats {
  let sessionCount: Int
  let cost: Double
  let tokens: Int

  // Token breakdown
  let inputTokens: Int
  let outputTokens: Int
  let cacheReadTokens: Int
  let cacheCreationTokens: Int

  /// Cost by model
  let costByModel: [(model: String, cost: Double, color: Color)]

  /// Calculated
  var inputCost: Double {
    // Approximate - actual cost is per-model
    Double(inputTokens) / 1_000_000 * 3.0
  }

  var outputCost: Double {
    Double(outputTokens) / 1_000_000 * 15.0
  }

  var cacheSavings: Double {
    // Cache reads cost ~90% less than regular input
    // Savings = (cacheReadTokens * normalInputCost) - (cacheReadTokens * cacheReadCost)
    let normalCost = Double(cacheReadTokens) / 1_000_000 * 3.0
    let actualCost = Double(cacheReadTokens) / 1_000_000 * 0.30
    return normalCost - actualCost
  }

  static func from(
    sessions: [Session]
  ) -> DetailedStats {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var cost = 0.0
    var costByModel: [String: Double] = [:]

    for session in sessions {
      let stats = usageStats(for: session)

      inputTokens += stats.inputTokens
      outputTokens += stats.outputTokens
      cacheReadTokens += stats.cacheReadTokens
      cacheCreationTokens += stats.cacheCreationTokens

      let rawModel = session.model ?? stats.model
      let sessionCost = ModelPricingService.shared.calculateCost(
        model: rawModel,
        inputTokens: stats.inputTokens,
        outputTokens: stats.outputTokens,
        cacheReadTokens: stats.cacheReadTokens,
        cacheCreationTokens: stats.cacheCreationTokens
      )
      cost += sessionCost

      if let model = normalizeModelName(rawModel) {
        costByModel[model, default: 0] += sessionCost
      }
    }

    let tokens = inputTokens + outputTokens

    // Sort by cost descending, map to tuples with colors
    let sortedCosts = costByModel.sorted { $0.value > $1.value }.map {
      (model: $0.key, cost: $0.value, color: colorForModel($0.key))
    }

    return DetailedStats(
      sessionCount: sessions.count,
      cost: cost,
      tokens: tokens,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheCreationTokens: cacheCreationTokens,
      costByModel: sortedCosts
    )
  }

  private static func usageStats(
    for session: Session
  ) -> TranscriptUsageStats {
    var stats = TranscriptUsageStats()
    stats.model = session.model

    let input = session.inputTokens ?? 0
    let output = session.outputTokens ?? 0
    let cached = session.cachedTokens ?? 0
    let context = session.contextWindow ?? 0
    let hasServerUsage = input > 0 || output > 0 || cached > 0 || context > 0

    if hasServerUsage {
      stats.inputTokens = input
      stats.outputTokens = output
      stats.cacheReadTokens = cached
      stats.contextUsed = context
      return stats
    }

    // Legacy fallback for rows that only stored total token count.
    if session.totalTokens > 0 {
      stats.outputTokens = session.totalTokens
    }

    return stats
  }

  private static func normalizeModelName(_ model: String?) -> String? {
    guard let model = model?.lowercased(), !model.isEmpty else { return nil }
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    if model.hasPrefix("gpt-") {
      let version = model.dropFirst(4).split(separator: "-").first ?? ""
      return "GPT-\(version)"
    }
    if model == "openai" { return nil }
    return nil // Skip unknown models
  }

  private static func colorForModel(_ model: String) -> Color {
    switch model {
      case "Opus": return .modelOpus
      case "Sonnet": return .modelSonnet
      case "Haiku": return .modelHaiku
      default:
        if model.hasPrefix("GPT") { return .providerCodex }
        return .secondary
    }
  }
}

// MARK: - Stats Detail Panel (expandable breakdown)

private struct StatsDetailPanel: View {
  let stats: DetailedStats
  let title: String
  let icon: String
  let accentColor: Color

  private var totalModelCost: Double {
    stats.costByModel.reduce(0) { $0 + $1.cost }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section header connecting to parent
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(accentColor)

        Text(title.uppercased())
          .font(.system(size: 8, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
          .tracking(0.5)

        Text("breakdown")
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      HStack(alignment: .top, spacing: 12) {
        // Cost by model card
        if !stats.costByModel.isEmpty {
          DetailCard(icon: "cpu.fill", title: "Cost by Model", accentColor: accentColor) {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(stats.costByModel.prefix(4), id: \.model) { item in
                HStack(spacing: 8) {
                  // Model name with color dot
                  HStack(spacing: 6) {
                    Circle()
                      .fill(item.color)
                      .frame(width: 8, height: 8)

                    Text(item.model)
                      .font(.system(size: 11, weight: .medium))
                      .foregroundStyle(.primary)
                  }
                  .frame(width: 70, alignment: .leading)

                  // Progress bar
                  GeometryReader { geo in
                    ZStack(alignment: .leading) {
                      RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))

                      RoundedRectangle(cornerRadius: 2)
                        .fill(item.color.opacity(0.8))
                        .frame(width: geo.size.width * min(1, item.cost / max(totalModelCost, 1)))
                    }
                  }
                  .frame(width: 60, height: 6)

                  // Cost
                  Text(formatCost(item.cost))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 50, alignment: .trailing)
                }
              }
            }
          }
        }

        // Token breakdown card
        DetailCard(icon: "arrow.left.arrow.right", title: "Tokens", accentColor: accentColor) {
          HStack(spacing: 16) {
            TokenStat(label: "Input", value: stats.inputTokens, color: .accent)
            TokenStat(label: "Output", value: stats.outputTokens, color: .statusSuccess)
          }
        }

        // Cache card (combined)
        if stats.cacheReadTokens > 0 || stats.cacheCreationTokens > 0 {
          DetailCard(icon: "memorychip", title: "Cache", accentColor: accentColor) {
            HStack(spacing: 16) {
              TokenStat(label: "Read", value: stats.cacheReadTokens, color: .modelHaiku)
              TokenStat(label: "Write", value: stats.cacheCreationTokens, color: .modelSonnet)
            }
          }
        }

        // Cache savings card
        if stats.cacheSavings > 0.01 {
          DetailCard(icon: "leaf.fill", title: "Saved", accentColor: .statusSuccess) {
            Text(formatCost(stats.cacheSavings))
              .font(.system(size: 18, weight: .bold, design: .rounded))
              .foregroundStyle(Color.statusSuccess)
          }
        }

        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(accentColor.opacity(0.03))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
        )
    )
  }

  private func formatCost(_ cost: Double) -> String {
    if cost >= 1_000 {
      return String(format: "$%.1fK", cost / 1_000)
    } else if cost >= 100 {
      return String(format: "$%.0f", cost)
    } else if cost >= 10 {
      return String(format: "$%.1f", cost)
    } else if cost >= 1 {
      return String(format: "$%.2f", cost)
    }
    return String(format: "$%.2f", cost)
  }
}

// MARK: - Detail Card

private struct DetailCard<Content: View>: View {
  let icon: String
  let title: String
  var accentColor: Color = .secondary
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header
      Label(title, systemImage: icon)
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textSecondary)
        .textCase(.uppercase)
        .tracking(0.3)

      content
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(0.02))
    )
  }
}

private struct TokenStat: View {
  let label: String
  let value: Int
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(formatTokens(value))
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(color)

      Text(label)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
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
