import SwiftUI

struct OverviewUsageProviderEntry {
  let provider: Provider
  let planName: String?
  let windows: [RateLimitWindow]
  let isLoading: Bool
}

struct OverviewUsageSection: View {
  let entries: [OverviewUsageProviderEntry]
  let todayStats: ServerUsageSummaryBucketPayload?
  let layoutMode: DashboardLayoutMode

  var body: some View {
    if !entries.isEmpty || todayStats != nil {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if let todayStats {
          OverviewTodayStatsStrip(stats: todayStats)
        }

        if !entries.isEmpty {
          providerCards
        }
      }
    }
  }

  @ViewBuilder
  private var providerCards: some View {
    if layoutMode.isPhoneCompact || entries.count == 1 {
      ForEach(Array(entries.enumerated()), id: \.element.provider.id) { _, entry in
        OverviewProviderLimitsCard(entry: entry)
      }
    } else {
      HStack(spacing: Spacing.sm) {
        ForEach(Array(entries.enumerated()), id: \.element.provider.id) { _, entry in
          OverviewProviderLimitsCard(entry: entry)
        }
      }
    }
  }
}

private struct OverviewTodayStatsStrip: View {
  let stats: ServerUsageSummaryBucketPayload

  var body: some View {
    HStack(spacing: Spacing.lg) {
      OverviewUsageMetric(
        value: DashboardFormatters.costCompact(stats.totalCostUSD),
        label: "cost",
        emphasize: stats.totalCostUSD > 0
      )

      OverviewUsageMetric(
        value: "\(stats.sessionCount)",
        label: stats.sessionCount == 1 ? "session" : "sessions"
      )

      OverviewUsageMetric(
        value: DashboardFormatters.tokens(Int(stats.totalTokens), zeroDisplay: "0"),
        label: "tokens"
      )

      Spacer(minLength: 0)

      Text("Today")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }
}

private struct OverviewUsageMetric: View {
  let value: String
  let label: String
  let emphasize: Bool

  init(value: String, label: String, emphasize: Bool = false) {
    self.value = value
    self.label = label
    self.emphasize = emphasize
  }

  var body: some View {
    HStack(spacing: Spacing.xxs) {
      Text(value)
        .font(.system(size: TypeScale.caption, weight: emphasize ? .bold : .semibold, design: .monospaced))
        .foregroundStyle(emphasize ? Color.textPrimary : Color.textSecondary)
        .contentTransition(.numericText())

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }
}

private struct OverviewProviderLimitsCard: View {
  let entry: OverviewUsageProviderEntry

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: entry.provider.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(entry.provider.accentColor)

        Text(entry.provider.displayName)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        if let plan = entry.planName {
          Text(plan)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if !entry.windows.isEmpty {
        VStack(spacing: Spacing.xs) {
          ForEach(entry.windows) { window in
            OverviewUsageWindowRow(window: window, provider: entry.provider)
          }
        }
      } else if entry.isLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.mini)
          Text("Loading...")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(Spacing.md_)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }
}

private struct OverviewUsageWindowRow: View {
  let window: RateLimitWindow
  let provider: Provider

  private var usageColor: Color {
    provider.color(for: window.utilization)
  }

  private var showProjection: Bool {
    window.projectedAtReset > window.utilization + 5
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: Spacing.xs) {
        Text(window.descriptiveLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)

        if window.willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(Color.feedbackCaution)
        }

        Spacer(minLength: 0)

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(usageColor)

        if showProjection {
          Text("→ \(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(DashboardFormatters.projectedColor(window.projectedAtReset))
        }
      }

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(height: 3)
    }
  }
}
