//
//  StatsPopoverContent.swift
//  OrbitDock
//
//  Stats popover showing today/all-time stats and usage gauges.
//  Shown when tapping cost badge in status bar.
//

import SwiftUI

// MARK: - Stats Popover

struct StatsPopoverContent: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(UsageServiceRegistry.self) private var registry

  let todayStats: StatusBarStats
  let allStats: StatusBarStats

  private var activeProviders: [(provider: Provider, windows: [RateLimitWindow], isLoading: Bool)] {
    registry.allProviders.map { provider in
      (provider: provider, windows: registry.windows(for: provider), isLoading: registry.isLoading(for: provider))
    }
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        if layoutMode.isPhoneCompact {
          usageSection
          statsSection(title: "Today", stats: todayStats, accentColor: .accent)
          statsSection(title: "All Time", stats: allStats, accentColor: .textSecondary)
        } else {
          statsSection(title: "Today", stats: todayStats, accentColor: .accent)
          statsSection(title: "All Time", stats: allStats, accentColor: .textSecondary)
          usageSection
        }
      }
      .padding(Spacing.lg)
    }
    .frame(minWidth: layoutMode.isPhoneCompact ? nil : 300)
  }

  // MARK: - Usage Section

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "gauge.with.dots.needle.33percent")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text(layoutMode.isPhoneCompact ? "LIVE LIMITS" : "USAGE")
          .font(.system(size: TypeScale.micro, weight: .heavy))
          .foregroundStyle(layoutMode.isPhoneCompact ? Color.accent : Color.textTertiary)
          .tracking(0.8)
      }

      ForEach(Array(activeProviders.enumerated()), id: \.element.provider.id) { index, entry in
        if index > 0 {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
            .frame(height: 1)
            .padding(.vertical, Spacing.xs)
        }

        popoverProviderGauge(entry.provider, windows: entry.windows, isLoading: entry.isLoading)
      }
    }
  }

  private func popoverProviderGauge(_ provider: Provider, windows: [RateLimitWindow], isLoading: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Provider header
      HStack(spacing: Spacing.sm_) {
        Image(systemName: provider.icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        if let plan = registry.planName(for: provider) {
          Text(plan)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if !windows.isEmpty {
        ForEach(windows) { window in
          popoverWindowRow(window, provider: provider)
        }
      } else if isLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.mini)
          Text("Loading...")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      } else {
        Text("No usage data")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }

  private func popoverWindowRow(_ window: RateLimitWindow, provider: Provider) -> some View {
    let usageColor = provider.color(for: window.utilization)
    let projectedColor = DashboardFormatters.projectedColor(window.projectedAtReset)
    let showProjection = window.projectedAtReset > window.utilization + 5
    let paceText = DashboardFormatters.paceLabel(window.paceStatus)
    let resetText = window.resetsInDescription.map { "Resets in \($0)" }

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        Text(window.label)
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
          .foregroundStyle(provider.accentColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 3)
          .background(provider.accentColor.opacity(0.14), in: Capsule())

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.body, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)

        Spacer(minLength: Spacing.sm)

        if let paceText {
          HStack(spacing: Spacing.xs) {
            Text(paceText)

            if showProjection {
              Text("+\(Int(window.projectedAtReset.rounded()))%")
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            }
          }
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(projectedColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 3)
          .background(projectedColor.opacity(0.14), in: Capsule())
        }
      }

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(height: 6)

      if let resetText {
        Text(resetText)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.45))
    )
    .overlay {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    }
  }

  // MARK: - Stats Section

  private func statsSection(title: String, stats: StatusBarStats, accentColor: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      Text(title.uppercased())
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(accentColor)
        .tracking(0.8)

      HStack(spacing: Spacing.xl) {
        statItem(label: "Cost", value: DashboardFormatters.costCompact(stats.cost))
        statItem(label: "Sessions", value: "\(stats.sessionCount)")
        statItem(label: "Tokens", value: DashboardFormatters.tokensUpperK(stats.tokens))
      }

      if !stats.costByModel.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(stats.costByModel.prefix(4), id: \.model) { item in
            HStack(spacing: Spacing.sm) {
              Circle()
                .fill(item.color)
                .frame(width: 6, height: 6)

              Text(item.model)
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.textSecondary)

              Spacer()

              Text(DashboardFormatters.costCompact(item.cost))
                .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            }
          }
        }
      }
    }
  }

  private func statItem(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.gap) {
      Text(value)
        .font(.system(size: TypeScale.subhead, weight: .bold, design: .rounded))
        .foregroundStyle(.primary)
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }
}

// MARK: - Stats Data Model

struct StatusBarStats {
  let sessionCount: Int
  let cost: Double
  let tokens: Int
  let costByModel: [(model: String, cost: Double, color: Color)]

  static func from(
    sessions: [RootSessionNode],
    costCalculator _: TokenCostCalculator
  ) -> StatusBarStats {
    var costByModel: [String: Double] = [:]

    for session in sessions {
      guard let model = normalizeModelName(session.model) else { continue }
      costByModel[model, default: 0] += session.totalCostUSD
    }

    let sortedCosts = costByModel.sorted { $0.value > $1.value }.map {
      (model: $0.key, cost: $0.value, color: colorForModel($0.key))
    }

    return StatusBarStats(
      sessionCount: sessions.count,
      cost: sessions.reduce(0) { $0 + $1.totalCostUSD },
      tokens: sessions.reduce(0) { $0 + $1.totalTokens },
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
    return nil
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
