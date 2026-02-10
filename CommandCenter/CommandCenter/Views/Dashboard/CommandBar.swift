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

  /// All stats (computed once)
  private var allStats: [(sessionId: String, stats: TranscriptUsageStats)] {
    MessageStore.shared.readAllSessionStats()
  }

  /// Calculate today's stats
  private var todayStats: DetailedStats {
    let calendar = Calendar.current
    let todaySessions = sessions.filter {
      guard let start = $0.startedAt else { return false }
      return calendar.isDateInToday(start)
    }
    return DetailedStats.from(sessions: todaySessions, allStats: allStats)
  }

  /// All-time aggregate stats
  private var trackedStats: DetailedStats {
    DetailedStats.from(sessions: sessions, allStats: allStats)
  }

  /// Model distribution for the mini chart
  private var modelDistribution: ModelDistribution {
    var counts: [String: (count: Int, color: Color)] = [:]

    for session in sessions {
      // Skip sessions with unknown/missing models
      guard let (name, color) = normalizeModel(session.model) else {
        continue
      }
      if let existing = counts[name] {
        counts[name] = (existing.count + 1, color)
      } else {
        counts[name] = (1, color)
      }
    }

    let entries = counts.map { (name: $0.key, count: $0.value.count, color: $0.value.color) }
    return ModelDistribution(modelCounts: entries)
  }

  /// Normalize model string to display name (returns nil to skip unknown models)
  private func normalizeModel(_ model: String?) -> (name: String, color: Color)? {
    guard let model = model?.lowercased(), !model.isEmpty else {
      return nil // Skip sessions with no model data
    }
    // Claude models
    if model.contains("opus") { return ("Opus", .modelOpus) }
    if model.contains("sonnet") { return ("Sonnet", .modelSonnet) }
    if model.contains("haiku") { return ("Haiku", .modelHaiku) }
    // OpenAI/Codex - normalize: "gpt-5.2-codex" -> "GPT-5.2"
    if model.hasPrefix("gpt-") {
      let version = model.dropFirst(4).split(separator: "-").first ?? ""
      return ("GPT-\(version)", .providerCodex)
    }
    // Skip generic "openai" - not a real model name
    if model == "openai" { return nil }
    return nil // Skip unknown models
  }

  var body: some View {
    VStack(spacing: 0) {
      // Main bar
      HStack(spacing: 0) {
        // Left side: Stats panels stacked with toggle below
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 0) {
            // Today's Activity
            StatsSummaryPanel(
              title: "TODAY",
              icon: "sun.max.fill",
              iconColor: .statusWaiting,
              stats: todayStats
            )

            verticalDivider

            // All-Time Totals
            StatsSummaryPanel(
              title: "TRACKED",
              icon: "tray.full.fill",
              iconColor: .accent.opacity(0.7),
              stats: trackedStats,
              modelDistribution: modelDistribution
            )
          }

          // Details toggle button (below stats)
          DetailsToggleButton(isExpanded: $showDetails)
        }

        Spacer(minLength: 20)

        // Usage Gauges (right side)
        UsageGaugesPanel()
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 20)

      // Expandable detail panels
      if showDetails {
        Divider()
          .background(Color.surfaceBorder.opacity(0.3))

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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.6))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(0.3), lineWidth: 1)
        )
    )
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showDetails)
  }

  private var verticalDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(0.3))
      .frame(width: 1)
      .padding(.vertical, 4)
      .padding(.horizontal, 16)
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
          .font(.system(size: 11, weight: .bold))
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
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(provider.accentColor.opacity(0.08))
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
          .foregroundStyle(.secondary)

        Text("\(Int(window.utilization))%")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)
      }

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
    sessions: [Session],
    allStats: [(sessionId: String, stats: TranscriptUsageStats)]
  ) -> DetailedStats {
    let sessionIds = Set(sessions.map(\.id))
    let sessionModels = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.model) })
    let filtered = allStats.filter { sessionIds.isEmpty || sessionIds.contains($0.sessionId) }

    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var costByModel: [String: Double] = [:]

    for item in filtered {
      inputTokens += item.stats.inputTokens
      outputTokens += item.stats.outputTokens
      cacheReadTokens += item.stats.cacheReadTokens
      cacheCreationTokens += item.stats.cacheCreationTokens

      // Use session.model (from DB) as primary, fall back to stats.model (from transcript)
      let rawModel = sessionModels[item.sessionId] ?? item.stats.model
      if let model = normalizeModelName(rawModel) {
        costByModel[model, default: 0] += item.stats.estimatedCostUSD
      }
    }

    let cost = filtered.reduce(0) { $0 + $1.stats.estimatedCostUSD }
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

private struct ModelDistribution {
  /// Model counts by display name
  let modelCounts: [(name: String, count: Int, color: Color)]

  var total: Int {
    modelCounts.reduce(0) { $0 + $1.count }
  }

  /// All model entries for display (sorted by count)
  var entries: [(name: String, count: Int, color: Color)] {
    modelCounts.sorted { $0.count > $1.count }
  }
}

// MARK: - Stats Summary Panel (compact view in main bar)

private struct StatsSummaryPanel: View {
  let title: String
  let icon: String
  let iconColor: Color
  let stats: DetailedStats
  var modelDistribution: ModelDistribution?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section label
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(iconColor)

        Text(title)
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
          label: title == "TODAY" ? "spent" : "total",
          icon: "dollarsign.circle.fill",
          color: title == "TRACKED" ? .statusSuccess : .primary
        )

        // Tokens
        StatBlock(
          value: formatTokens(stats.tokens),
          label: "tokens",
          icon: "textformat.abc"
        )

        // Model distribution (only for TRACKED)
        if let distribution = modelDistribution, distribution.total > 0 {
          ModelDistributionChart(distribution: distribution)
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
      return String(format: "%.1fM", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
      return String(format: "%.0fK", Double(tokens) / 1_000)
    }
    return "\(tokens)"
  }
}

// MARK: - Details Toggle Button

private struct DetailsToggleButton: View {
  @Binding var isExpanded: Bool
  @State private var isHovered = false

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "chart.bar.doc.horizontal")
          .font(.system(size: 10, weight: .semibold))

        Text(isExpanded ? "Less" : "Details")
          .font(.system(size: 10, weight: .semibold))

        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
      }
      .foregroundStyle(isHovered || isExpanded ? .primary : .secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isHovered || isExpanded ? Color.primary.opacity(0.1) : Color.primary.opacity(0.05))
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
      }
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
          .foregroundStyle(.tertiary)
          .tracking(0.5)

        Text("breakdown")
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(.quaternary)
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
        .foregroundStyle(.secondary)
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
        .foregroundStyle(.tertiary)
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

  /// Split entries into rows for grid layout
  private var gridRows: [[ModelEntry]] {
    let entries = distribution.entries.map { ModelEntry(name: $0.name, count: $0.count, color: $0.color) }
    // 2 columns
    var rows: [[ModelEntry]] = []
    for i in stride(from: 0, to: entries.count, by: 2) {
      let end = min(i + 2, entries.count)
      rows.append(Array(entries[i ..< end]))
    }
    return rows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Section label
      Text("MODELS")
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(.quaternary)
        .tracking(0.5)

      // Grid layout - 2 columns
      VStack(alignment: .leading, spacing: 3) {
        ForEach(gridRows.indices, id: \.self) { rowIndex in
          HStack(spacing: 12) {
            ForEach(gridRows[rowIndex], id: \.name) { entry in
              modelChip(entry: entry)
            }
          }
        }
      }
    }
  }

  private func modelChip(entry: ModelEntry) -> some View {
    HStack(spacing: 4) {
      Image(systemName: iconForModel(entry.name))
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(entry.color.opacity(0.8))

      Text(entry.name)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(entry.color)

      Text("\(entry.count)")
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }

  private func iconForModel(_ name: String) -> String {
    if name.hasPrefix("GPT") {
      return "chevron.left.forwardslash.chevron.right"
    }
    return "staroflife.fill" // Claude models
  }
}

private struct ModelEntry {
  let name: String
  let count: Int
  let color: Color
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
