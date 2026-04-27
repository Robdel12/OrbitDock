import SwiftUI

struct UsageCenterView: View {
  @Environment(AppRouter.self) private var router
  @Environment(UsageServiceRegistry.self) private var usageRegistry
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var usageEntries: [OverviewUsageProviderEntry] {
    usageRegistry.allProviders.compactMap { provider in
      let windows = usageRegistry.windows(for: provider)
      let errorMessage = usageRegistry.error(for: provider)?.errorDescription
      let rateLimitReachedType = provider == .codex ? usageRegistry.codexRateLimitReachedType : nil
      guard !windows.isEmpty || errorMessage != nil || rateLimitReachedType != nil else { return nil }
      return OverviewUsageProviderEntry(
        provider: provider,
        windows: windows,
        errorMessage: errorMessage,
        rateLimitReachedType: rateLimitReachedType
      )
    }
  }

  private var usageRefreshIdentity: String {
    let todayStartUnix = UInt64(max(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, 0))
    return "\(todayStartUnix)|\(runtimeRegistry.dashboardRefreshIdentity)"
  }

  var body: some View {
    ZStack {
      Color.backgroundPrimary
        .ignoresSafeArea()

      Group {
        if let todayStats = usageRegistry.summary?.today {
          UsageDetailSurface(
            summary: todayStats,
            totalTurns: usageRegistry.providerBreakdown?.groups.reduce(0) { $0 + $1.turnCount } ?? 0,
            allTime: usageRegistry.summary?.allTime,
            entries: usageEntries,
            endpointSnapshots: usageRegistry.endpointSnapshots,
            providerBreakdown: usageRegistry.providerBreakdown,
            modelBreakdown: usageRegistry.modelBreakdown,
            topSessions: usageRegistry.topSessions,
            recentDayBreakdown: usageRegistry.recentDayBreakdown,
            layoutMode: layoutMode
          )
        } else {
          ContentUnavailableView(
            "Usage unavailable",
            systemImage: "chart.xyaxis.line",
            description: Text("Usage data will appear here once the server reports API accounting.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationTitle("Usage")
    .toolbarTitleDisplayMode(.inline)
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: usageBackToolbarPlacement) {
          Button {
            router.goBack(source: .dashboardStream)
          } label: {
            Label(router.backDestinationLabel, systemImage: "chevron.left")
          }
        }
      }
    #else
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            router.goToDashboard(source: .dashboardStream)
          } label: {
            Label("Active", systemImage: "chevron.left")
          }
        }
      }
    #endif
    .task(id: usageRefreshIdentity) {
      await usageRegistry.refreshIfNeeded(todayStart: Calendar.current.startOfDay(for: Date()))
    }
  }
}

#if os(macOS)
  private let usageBackToolbarPlacement: ToolbarItemPlacement = .navigation
#endif

struct OverviewUsageProviderEntry {
  let provider: Provider
  let windows: [RateLimitWindow]
  let errorMessage: String?
  let rateLimitReachedType: ServerCodexRateLimitReachedType?
}

struct OverviewUsageSection: View {
  @Environment(AppRouter.self) private var router
  let entries: [OverviewUsageProviderEntry]
  let todayStats: ServerUsageSummaryBucketPayload?
  let endpointSnapshots: [UsageEndpointSnapshot]
  let providerBreakdown: ServerUsageBreakdownSnapshotPayload?
  let modelBreakdown: ServerUsageBreakdownSnapshotPayload?

  private var totalTurns: UInt64 {
    providerBreakdown?.groups.reduce(0) { $0 + $1.turnCount } ?? 0
  }

  var body: some View {
    if let todayStats {
      Button {
        router.goToUsage(source: .dashboardStream)
      } label: {
        OverviewUsageSummaryCard(
          stats: todayStats,
          totalTurns: totalTurns,
          entries: entries,
          providerBreakdown: providerBreakdown,
          modelBreakdown: modelBreakdown,
          activeServerCount: endpointSnapshots.count
        )
      }
      .buttonStyle(.plain)
      .contentShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      .platformCursorOnHover()
    }
  }
}

private struct OverviewUsageSummaryCard: View {
  let stats: ServerUsageSummaryBucketPayload
  let totalTurns: UInt64
  let entries: [OverviewUsageProviderEntry]
  let providerBreakdown: ServerUsageBreakdownSnapshotPayload?
  let modelBreakdown: ServerUsageBreakdownSnapshotPayload?
  let activeServerCount: Int

  private var providerEntries: [ServerUsageBreakdownEntryPayload] {
    providerBreakdown?.groups.filter { $0.totalTokens > 0 || $0.totalCostUSD > 0 } ?? []
  }

  private var topModelEntry: ServerUsageBreakdownEntryPayload? {
    modelBreakdown?.groups.first
  }

  private var usageHighlights: [OverviewUsageHighlight] {
    var highlights = providerEntries.prefix(2).map { entry in
      OverviewUsageHighlight(
        label: providerLabel(entry),
        value: DashboardFormatters.costCompact(entry.totalCostUSD),
        detail: turnCountLabel(entry.turnCount),
        color: providerColor(entry.provider)
      )
    }

    if let topModelEntry {
      highlights.append(
        OverviewUsageHighlight(
          label: "Top model \(topModelEntry.model ?? topModelEntry.groupKey)",
          value: DashboardFormatters.costCompact(topModelEntry.totalCostUSD),
          detail: turnCountLabel(topModelEntry.turnCount),
          color: modelColor(topModelEntry.model ?? topModelEntry.groupKey)
        )
      )
    }

    return highlights
  }

  private var scopeLabel: String {
    usageScopeLabel(activeServerCount: activeServerCount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Usage")
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          Text(scopeLabel)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer(minLength: 0)

        HStack(spacing: Spacing.xs) {
          OverviewStatusBadge(title: "Today", color: .accent)
          if !entries.isEmpty {
            OverviewStatusBadge(title: "Live limits", color: .providerCodex)
          }
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm) {
          OverviewMetricPill(
            value: DashboardFormatters.costCompact(stats.totalCostUSD),
            label: "cost",
            emphasize: stats.totalCostUSD > 0
          )
          OverviewMetricPill(
            value: "\(stats.distinctSessionCount)",
            label: distinctSessionLabel(stats.distinctSessionCount)
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"),
            label: "tokens"
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: totalTurns), zeroDisplay: "0"),
            label: totalTurns == 1 ? "turn" : "turns"
          )
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          OverviewMetricPill(
            value: DashboardFormatters.costCompact(stats.totalCostUSD),
            label: "cost",
            emphasize: stats.totalCostUSD > 0
          )
          OverviewMetricPill(
            value: "\(stats.distinctSessionCount)",
            label: distinctSessionLabel(stats.distinctSessionCount)
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"),
            label: "tokens"
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: totalTurns), zeroDisplay: "0"),
            label: totalTurns == 1 ? "turn" : "turns"
          )
        }
      }

      if !usageHighlights.isEmpty {
        OverviewUsageHighlightStrip(highlights: usageHighlights)
      }

      if !entries.isEmpty {
        Rectangle()
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .frame(height: 1)

        limitSummaryColumn
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }

  private var limitSummaryColumn: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      OverviewSectionLabel(title: "Live limits")

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          ForEach(entries, id: \.provider.id) { entry in
            OverviewCompactProviderLimitsBlock(entry: entry)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(entries, id: \.provider.id) { entry in
            OverviewCompactProviderLimitsBlock(entry: entry)
          }
        }
      }
    }
  }
}

private struct OverviewUsageHighlight: Identifiable {
  let label: String
  let value: String
  let detail: String
  let color: Color

  var id: String {
    label
  }
}

private struct OverviewUsageHighlightStrip: View {
  let highlights: [OverviewUsageHighlight]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.sm) {
        ForEach(highlights) { highlight in
          OverviewUsageHighlightChip(highlight: highlight)
        }
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(highlights) { highlight in
          OverviewUsageHighlightChip(highlight: highlight)
        }
      }
    }
  }
}

private struct OverviewUsageHighlightChip: View {
  let highlight: OverviewUsageHighlight

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(highlight.color)
        .frame(width: 6, height: 6)

      Text(highlight.label)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: Spacing.sm)

      Text(highlight.value)
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)

      Text(highlight.detail)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.32))
    )
  }
}

private struct UsageDetailSurface: View {
  let summary: ServerUsageSummaryBucketPayload
  let totalTurns: UInt64
  let allTime: ServerUsageSummaryBucketPayload?
  let entries: [OverviewUsageProviderEntry]
  let endpointSnapshots: [UsageEndpointSnapshot]
  let providerBreakdown: ServerUsageBreakdownSnapshotPayload?
  let modelBreakdown: ServerUsageBreakdownSnapshotPayload?
  let topSessions: ServerUsageSessionsSnapshotPayload?
  let recentDayBreakdown: ServerUsageBreakdownSnapshotPayload?
  let layoutMode: DashboardLayoutMode

  private var contentMaxWidth: CGFloat? {
    layoutMode.isPhoneCompact ? nil : 1080
  }

  private var horizontalPadding: CGFloat {
    layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.xl
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        UsageDetailTodayCard(
          stats: summary,
          totalTurns: totalTurns,
          providerBreakdown: providerBreakdown,
          modelBreakdown: modelBreakdown,
          activeServerCount: endpointSnapshots.count
        )

        if !entries.isEmpty {
          UsageDetailLimitsCard(entries: entries)
        }

        if let recentDayBreakdown, !recentDayBreakdown.groups.isEmpty {
          UsageDetailRecentTrendCard(breakdown: recentDayBreakdown)
        }

        if let topSessions, !topSessions.sessions.isEmpty {
          UsageDetailTopSessionsCard(snapshot: topSessions)
        }

        if let allTime {
          UsageDetailAllTimeCard(stats: allTime)
        }

        if endpointSnapshots.count > 1 {
          OverviewServerUsageSection(
            endpointSnapshots: endpointSnapshots,
            layoutMode: layoutMode
          )
        }
      }
      .frame(maxWidth: contentMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, Spacing.lg)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.backgroundPrimary)
  }
}

private struct UsageDetailAllTimeCard: View {
  let stats: ServerUsageSummaryBucketPayload

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text("All time")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textPrimary)
        Spacer(minLength: 0)
        OverviewStatusBadge(title: "Historical", color: .textTertiary)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm) {
          OverviewMetricPill(value: DashboardFormatters.costCompact(stats.totalCostUSD), label: "cost", emphasize: stats.totalCostUSD > 0)
          OverviewMetricPill(value: "\(stats.distinctSessionCount)", label: distinctSessionLabel(stats.distinctSessionCount))
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"), label: "tokens")
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          OverviewMetricPill(value: DashboardFormatters.costCompact(stats.totalCostUSD), label: "cost", emphasize: stats.totalCostUSD > 0)
          OverviewMetricPill(value: "\(stats.distinctSessionCount)", label: distinctSessionLabel(stats.distinctSessionCount))
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"), label: "tokens")
        }
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }
}

private struct UsageDetailTodayCard: View {
  let stats: ServerUsageSummaryBucketPayload
  let totalTurns: UInt64
  let providerBreakdown: ServerUsageBreakdownSnapshotPayload?
  let modelBreakdown: ServerUsageBreakdownSnapshotPayload?
  let activeServerCount: Int

  private var providerEntries: [ServerUsageBreakdownEntryPayload] {
    providerBreakdown?.groups.filter { $0.totalTokens > 0 || $0.totalCostUSD > 0 } ?? []
  }

  private var modelEntries: [ServerUsageBreakdownEntryPayload] {
    Array((modelBreakdown?.groups ?? []).prefix(4))
  }

  private var scopeLabel: String {
    usageScopeLabel(activeServerCount: activeServerCount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Today")
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          Text(scopeLabel)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer(minLength: 0)

        OverviewStatusBadge(title: "Today", color: .accent)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm) {
          OverviewMetricPill(value: DashboardFormatters.costCompact(stats.totalCostUSD), label: "cost", emphasize: stats.totalCostUSD > 0)
          OverviewMetricPill(value: "\(stats.distinctSessionCount)", label: distinctSessionLabel(stats.distinctSessionCount))
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"), label: "tokens")
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: totalTurns), zeroDisplay: "0"), label: totalTurns == 1 ? "turn" : "turns")
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          OverviewMetricPill(value: DashboardFormatters.costCompact(stats.totalCostUSD), label: "cost", emphasize: stats.totalCostUSD > 0)
          OverviewMetricPill(value: "\(stats.distinctSessionCount)", label: distinctSessionLabel(stats.distinctSessionCount))
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: stats.totalTokens), zeroDisplay: "0"), label: "tokens")
          OverviewMetricPill(value: DashboardFormatters.tokens(Int(clamping: totalTurns), zeroDisplay: "0"), label: totalTurns == 1 ? "turn" : "turns")
        }
      }

      HStack(spacing: Spacing.sm) {
        UsageDetailMicroStat(label: "input", value: DashboardFormatters.tokens(Int(clamping: stats.inputTokens), zeroDisplay: "0"))
        UsageDetailMicroStat(label: "output", value: DashboardFormatters.tokens(Int(clamping: stats.outputTokens), zeroDisplay: "0"))
        UsageDetailMicroStat(label: "cache", value: DashboardFormatters.tokens(Int(clamping: stats.cachedTokens), zeroDisplay: "0"))
      }

      if !providerEntries.isEmpty || !modelEntries.isEmpty {
        Rectangle()
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .frame(height: 1)
      }

      if !providerEntries.isEmpty || !modelEntries.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Spacing.lg) {
            if !providerEntries.isEmpty {
              detailProviderColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !modelEntries.isEmpty {
              detailModelColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          VStack(alignment: .leading, spacing: Spacing.md_) {
            if !providerEntries.isEmpty {
              detailProviderColumn
            }
            if !modelEntries.isEmpty {
              detailModelColumn
            }
          }
        }
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }

  private var detailProviderColumn: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      OverviewSectionLabel(title: "By provider")

      OverviewProviderShareBar(entries: providerEntries)
        .frame(height: 5)

      ForEach(providerEntries.prefix(2), id: \.groupKey) { entry in
        OverviewBreakdownRow(
          label: providerLabel(entry),
          value: DashboardFormatters.costCompact(entry.totalCostUSD),
          detail: DashboardFormatters.tokens(Int(clamping: entry.totalTokens), zeroDisplay: "0"),
          color: providerColor(entry.provider),
          share: share(
            entry,
            totalCost: providerBreakdown?.totals.totalCostUSD ?? 0,
            totalTokens: providerBreakdown?.totals.totalTokens ?? 0
          )
        )
      }
    }
  }

  private var detailModelColumn: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      OverviewSectionLabel(title: "Top models")

      ForEach(modelEntries, id: \.groupKey) { entry in
        OverviewBreakdownRow(
          label: entry.model ?? entry.groupKey,
          value: DashboardFormatters.costCompact(entry.totalCostUSD),
          detail: turnCountLabel(entry.turnCount),
          color: modelColor(entry.model ?? entry.groupKey),
          share: share(
            entry,
            totalCost: modelBreakdown?.totals.totalCostUSD ?? 0,
            totalTokens: modelBreakdown?.totals.totalTokens ?? 0
          )
        )
      }
    }
  }
}

private struct OverviewServerUsageSection: View {
  let endpointSnapshots: [UsageEndpointSnapshot]
  let layoutMode: DashboardLayoutMode

  private var columns: [GridItem] {
    if layoutMode.isPhoneCompact {
      return [GridItem(.flexible(), spacing: Spacing.sm)]
    }
    return [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: Spacing.sm, alignment: .top)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text("By server")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textPrimary)

        Text("Each server keeps its own usage, limits, and reset windows")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
        ForEach(endpointSnapshots) { snapshot in
          OverviewServerUsageCard(snapshot: snapshot)
        }
      }
    }
  }
}

private struct OverviewServerUsageCard: View {
  let snapshot: UsageEndpointSnapshot

  private var providerEntries: [OverviewEndpointProviderEntry] {
    [
      OverviewEndpointProviderEntry(
        endpointId: snapshot.endpointId,
        provider: .claude,
        windows: snapshot.claudeWindows,
        errorMessage: snapshot.claudeErrorMessage
      ),
      OverviewEndpointProviderEntry(
        endpointId: snapshot.endpointId,
        provider: .codex,
        windows: snapshot.codexWindows,
        errorMessage: snapshot.codexErrorMessage,
        rateLimitReachedType: snapshot.codexRateLimitReachedType
      ),
    ]
    .filter { !$0.windows.isEmpty || $0.errorMessage != nil || $0.rateLimitReachedType != nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "server.rack")
          .font(.system(size: IconScale.sm, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text(snapshot.endpointName)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 0)

        OverviewStatusBadge(title: "Today", color: .accent)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm) {
          OverviewMetricPill(
            value: DashboardFormatters.costCompact(snapshot.overview.summary.today.totalCostUSD),
            label: "cost",
            emphasize: snapshot.overview.summary.today.totalCostUSD > 0
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: snapshot.overview.summary.today.totalTokens), zeroDisplay: "0"),
            label: "tokens"
          )
          OverviewMetricPill(
            value: "\(snapshot.overview.summary.today.distinctSessionCount)",
            label: distinctSessionLabel(snapshot.overview.summary.today.distinctSessionCount)
          )
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          OverviewMetricPill(
            value: DashboardFormatters.costCompact(snapshot.overview.summary.today.totalCostUSD),
            label: "cost",
            emphasize: snapshot.overview.summary.today.totalCostUSD > 0
          )
          OverviewMetricPill(
            value: DashboardFormatters.tokens(Int(clamping: snapshot.overview.summary.today.totalTokens), zeroDisplay: "0"),
            label: "tokens"
          )
          OverviewMetricPill(
            value: "\(snapshot.overview.summary.today.distinctSessionCount)",
            label: distinctSessionLabel(snapshot.overview.summary.today.distinctSessionCount)
          )
        }
      }

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)

      if providerEntries.isEmpty {
        Text("No subscription limit data reported by this server yet.")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      } else {
        VStack(spacing: Spacing.sm) {
          ForEach(Array(providerEntries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 {
              Rectangle()
                .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
                .frame(height: 1)
            }

            OverviewEndpointProviderBlock(entry: entry)
          }
        }
      }
    }
    .padding(Spacing.md_)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overviewCardChrome()
  }
}

private struct OverviewEndpointProviderBlock: View {
  let entry: OverviewEndpointProviderEntry
  let compact: Bool

  init(entry: OverviewEndpointProviderEntry, compact: Bool = false) {
    self.entry = entry
    self.compact = compact
  }

  private var statusBadge: (title: String, color: Color)? {
    if let rateLimitReachedType = entry.rateLimitReachedType {
      return (codexRateLimitLabel(rateLimitReachedType), .statusError)
    }
    if entry.errorMessage != nil {
      return ("Unavailable", .feedbackCaution)
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? Spacing.xs : Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: entry.provider.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(entry.provider.accentColor)

        Text(entry.provider.displayName)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        Spacer(minLength: 0)

        if let statusBadge {
          Text(statusBadge.title)
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(statusBadge.color)
            .padding(.horizontal, compact ? Spacing.xs : Spacing.sm_)
            .padding(.vertical, compact ? 2 : 3)
            .background(statusBadge.color.opacity(0.12), in: Capsule())
        }
      }

      if !entry.windows.isEmpty {
        VStack(spacing: Spacing.xs) {
          ForEach(entry.windows) { window in
            OverviewUsageWindowRow(window: window, provider: entry.provider)
          }
        }
      } else if let errorMessage = entry.errorMessage {
        Text(errorMessage)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct OverviewEndpointProviderEntry: Identifiable {
  let endpointId: UUID
  let provider: Provider
  let windows: [RateLimitWindow]
  let errorMessage: String?
  let rateLimitReachedType: ServerCodexRateLimitReachedType?

  init(
    endpointId: UUID,
    provider: Provider,
    windows: [RateLimitWindow],
    errorMessage: String?,
    rateLimitReachedType: ServerCodexRateLimitReachedType? = nil
  ) {
    self.endpointId = endpointId
    self.provider = provider
    self.windows = windows
    self.errorMessage = errorMessage
    self.rateLimitReachedType = rateLimitReachedType
  }

  var id: String {
    "\(endpointId.uuidString)-\(provider.rawValue)"
  }
}

private struct OverviewSectionLabel: View {
  let title: String

  var body: some View {
    Text(title.uppercased())
      .font(.system(size: TypeScale.micro, weight: .heavy))
      .foregroundStyle(Color.textQuaternary)
      .tracking(0.6)
  }
}

private struct OverviewMetricPill: View {
  let value: String
  let label: String
  let emphasize: Bool

  init(value: String, label: String, emphasize: Bool = false) {
    self.value = value
    self.label = label
    self.emphasize = emphasize
  }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      Text(value)
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(emphasize ? Color.textPrimary : Color.textSecondary)
        .contentTransition(.numericText())

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.4))
    )
  }
}

private struct OverviewCompactUsageRow: View {
  let label: String
  let value: String
  let detail: String
  let color: Color
  let share: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        Text(label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: Spacing.sm)

        Text(value)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)

        Text(detail)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              .fill(color.opacity(0.8))
              .frame(width: max(2, proxy.size.width * CGFloat(max(share, 0.02))))
          }
      }
      .frame(height: 3)
    }
  }
}

private struct UsageDetailMicroStat: View {
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: Spacing.xxs) {
      Text(label.uppercased())
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(Color.textQuaternary)
        .tracking(0.5)

      Text(value)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
  }
}

private struct UsageDetailLimitsCard: View {
  let entries: [OverviewUsageProviderEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack {
        Text("Limits & resets")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textPrimary)
        Spacer(minLength: 0)
        OverviewStatusBadge(title: "Live", color: .providerCodex)
      }

      VStack(spacing: Spacing.sm) {
        ForEach(Array(entries.enumerated()), id: \.element.provider.id) { index, entry in
          if index > 0 {
            Rectangle()
              .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
              .frame(height: 1)
          }

          UsageDetailProviderLimitsBlock(entry: entry)
        }
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }
}

private struct UsageDetailProviderLimitsBlock: View {
  let entry: OverviewUsageProviderEntry

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: entry.provider.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(entry.provider.accentColor)

        Text(entry.provider.displayName)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        Spacer(minLength: 0)
      }

      if !entry.windows.isEmpty {
        VStack(spacing: Spacing.xs) {
          ForEach(entry.windows) { window in
            OverviewUsageWindowRow(window: window, provider: entry.provider)
          }
        }
      } else if let errorMessage = entry.errorMessage {
        Text(errorMessage)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      } else if let rateLimitReachedType = entry.rateLimitReachedType {
        Text(codexRateLimitLabel(rateLimitReachedType))
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.statusError)
      }
    }
  }
}

private struct UsageDetailRecentTrendCard: View {
  let breakdown: ServerUsageBreakdownSnapshotPayload

  private var entries: [ServerUsageBreakdownEntryPayload] {
    Array(
      breakdown.groups
        .filter { $0.dayStartUnix != nil }
        .sorted { ($0.dayStartUnix ?? 0) < ($1.dayStartUnix ?? 0) }
        .suffix(7)
    )
  }

  private var maxWeight: Double {
    let totalCost = entries.reduce(0) { $0 + $1.totalCostUSD }
    if totalCost > 0 {
      return entries.map(\.totalCostUSD).max() ?? 0
    }
    return Double(entries.map(\.totalTokens).max() ?? 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack {
        Text("Recent activity")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textPrimary)
        Spacer(minLength: 0)
        OverviewStatusBadge(title: "Last 7 days", color: .accent)
      }

      VStack(spacing: Spacing.xs) {
        ForEach(entries, id: \.groupKey) { entry in
          UsageDetailDayRow(entry: entry, maxWeight: maxWeight)
        }
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }
}

private struct UsageDetailDayRow: View {
  let entry: ServerUsageBreakdownEntryPayload
  let maxWeight: Double

  private var weight: Double {
    if entry.totalCostUSD > 0 {
      return entry.totalCostUSD
    }
    return Double(entry.totalTokens)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Text(dayLabel(from: entry.dayStartUnix))
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 34, alignment: .leading)

      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              .fill(Color.accent.opacity(0.8))
              .frame(width: max(2, proxy.size.width * CGFloat(weight / max(maxWeight, 1))))
          }
      }
      .frame(height: 5)

      Text(DashboardFormatters.costCompact(entry.totalCostUSD))
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)

      Text(DashboardFormatters.tokens(Int(clamping: entry.totalTokens), zeroDisplay: "0"))
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
  }
}

private struct UsageDetailTopSessionsCard: View {
  let snapshot: ServerUsageSessionsSnapshotPayload

  private var entries: [ServerUsageSessionSummaryPayload] {
    Array(snapshot.sessions.prefix(6))
  }

  private var visibleTotalCost: Double {
    entries.reduce(0) { $0 + $1.totalCostUSD }
  }

  private var visibleTotalTokens: UInt64 {
    entries.reduce(0) { $0 + $1.totalTokens }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack {
        Text("Top sessions")
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textPrimary)
        Spacer(minLength: 0)
        OverviewStatusBadge(title: "\(snapshot.totalCount) distinct", color: .textTertiary)
      }

      VStack(spacing: Spacing.xs) {
        ForEach(entries) { entry in
          UsageDetailSessionRow(
            entry: entry,
            color: providerColor(entry.provider),
            share: usageSessionShare(
              entry,
              totalCost: visibleTotalCost,
              totalTokens: visibleTotalTokens
            )
          )
        }
      }
    }
    .padding(Spacing.md_)
    .overviewCardChrome()
  }
}

private struct UsageDetailSessionRow: View {
  let entry: ServerUsageSessionSummaryPayload
  let color: Color
  let share: Double

  private var detailLine: String? {
    let normalizedContext = entry.contextLine?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    if let normalizedContext {
      return normalizedContext
    }

    let project = entry.projectName?.nilIfEmpty
      ?? URL(fileURLWithPath: entry.projectPath).lastPathComponent.nilIfEmpty
    let details = [project, entry.model?.nilIfEmpty].compactMap { $0 }
    return details.isEmpty ? nil : details.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Circle()
          .fill(color)
          .frame(width: 7, height: 7)
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: 2) {
          Text(entry.displayName)
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)

          if let detailLine {
            Text(detailLine)
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }

        Spacer(minLength: Spacing.sm)

        VStack(alignment: .trailing, spacing: 2) {
          Text(DashboardFormatters.costCompact(entry.totalCostUSD))
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textPrimary)

          Text("\(turnCountLabel(entry.turnCount)) · \(DashboardFormatters.tokens(Int(clamping: entry.totalTokens), zeroDisplay: "0"))")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              .fill(color.opacity(0.75))
              .frame(width: max(2, proxy.size.width * CGFloat(max(share, 0.02))))
          }
      }
      .frame(height: 3)
    }
    .padding(.vertical, 2)
  }
}

private struct OverviewCompactProviderLimitsBlock: View {
  let entry: OverviewUsageProviderEntry

  private var displayedWindows: [RateLimitWindow] {
    Array(entry.windows.sorted(by: compactWindowSort).prefix(2))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: entry.provider.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(entry.provider.accentColor)

        Text(entry.provider.displayName)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Spacer(minLength: 0)

        if let rateLimitReachedType = entry.rateLimitReachedType {
          Text(codexRateLimitLabel(rateLimitReachedType))
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(Color.statusError)
        } else if entry.errorMessage != nil {
          Text("Unavailable")
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(Color.feedbackCaution)
        } else if let primary = displayedWindows.first {
          Text("\(primary.descriptiveLabel) \(Int(primary.utilization))%")
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(entry.provider.color(for: primary.utilization))
        }
      }

      if !displayedWindows.isEmpty {
        VStack(spacing: Spacing.xs) {
          ForEach(displayedWindows) { window in
            OverviewUsageWindowRow(window: window, provider: entry.provider, compact: true)
          }
        }
      } else if let errorMessage = entry.errorMessage {
        Text(errorMessage)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Waiting for usage")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.vertical, 2)
  }

  private func compactWindowSort(_ lhs: RateLimitWindow, _ rhs: RateLimitWindow) -> Bool {
    compactWindowScore(lhs) > compactWindowScore(rhs)
  }

  private func compactWindowScore(_ window: RateLimitWindow) -> Double {
    max(window.projectedAtReset, window.utilization)
  }
}

private struct OverviewStatusBadge: View {
  let title: String
  let color: Color

  var body: some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
  }
}

private struct OverviewProviderShareBar: View {
  let entries: [ServerUsageBreakdownEntryPayload]

  private var totalWeight: Double {
    let cost = entries.reduce(0) { $0 + $1.totalCostUSD }
    if cost > 0 { return cost }
    return Double(entries.reduce(0) { $0 + $1.totalTokens })
  }

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 1) {
        ForEach(entries, id: \.groupKey) { entry in
          Rectangle()
            .fill(providerColor(entry.provider))
            .frame(width: segmentWidth(entry: entry, totalWidth: proxy.size.width))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
    }
  }

  private func segmentWidth(entry: ServerUsageBreakdownEntryPayload, totalWidth: CGFloat) -> CGFloat {
    guard totalWeight > 0 else { return 0 }
    let weight = entry.totalCostUSD > 0 ? entry.totalCostUSD : Double(entry.totalTokens)
    return max(2, totalWidth * CGFloat(weight / totalWeight))
  }
}

private struct OverviewBreakdownRow: View {
  let label: String
  let value: String
  let detail: String
  let color: Color
  let share: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        Text(label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: Spacing.sm)

        Text(value)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)

        Text(detail)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      GeometryReader { proxy in
        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              .fill(color.opacity(0.75))
              .frame(width: max(2, proxy.size.width * CGFloat(share)))
          }
      }
      .frame(height: 3)
    }
  }
}

private struct OverviewUsageWindowRow: View {
  let window: RateLimitWindow
  let provider: Provider
  let compact: Bool

  init(window: RateLimitWindow, provider: Provider, compact: Bool = false) {
    self.window = window
    self.provider = provider
    self.compact = compact
  }

  private var usageColor: Color {
    provider.color(for: window.utilization)
  }

  private var showProjection: Bool {
    window.projectedAtReset > window.utilization + 5
  }

  private var resetSummary: String? {
    guard let resetTime = window.resetsAtFormatted(showDay: window.windowDuration >= 86_400) else {
      return nil
    }
    if let remaining = window.resetsInDescription {
      return "Resets \(resetTime) · \(remaining)"
    }
    return "Resets \(resetTime)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 2 : 3) {
      HStack(spacing: Spacing.xs) {
        Text(window.descriptiveLabel)
          .font(.system(size: compact ? TypeScale.mini : TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)

        if window.willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(Color.feedbackCaution)
        }

        Spacer(minLength: 0)

        Text("\(Int(window.utilization))%")
          .font(.system(size: compact ? TypeScale.mini : TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(usageColor)

        if showProjection {
          Text("→ \(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: compact ? TypeScale.mini : TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(DashboardFormatters.projectedColor(window.projectedAtReset))
        }
      }

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(height: compact ? 3 : 4)

      HStack(spacing: Spacing.sm) {
        if let resetSummary {
          Text(resetSummary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if let paceLabel = DashboardFormatters.paceLabel(window.paceStatus) {
          Text(paceLabel)
            .lineLimit(1)
        }
      }
      .font(.system(size: compact ? TypeScale.mini : TypeScale.micro, weight: .medium))
      .foregroundStyle(Color.textQuaternary)
    }
  }
}

private extension View {
  func overviewCardChrome() -> some View {
    background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }
}

private func providerColor(_ provider: ServerProvider?) -> Color {
  switch provider {
    case .claude: .providerClaude
    case .codex: .providerCodex
    case nil: .textTertiary
  }
}

private func providerLabel(_ entry: ServerUsageBreakdownEntryPayload) -> String {
  switch entry.provider {
    case .claude: "Claude"
    case .codex: "Codex"
    case nil: entry.groupKey
  }
}

private func modelColor(_ model: String) -> Color {
  let normalized = model.lowercased()
  if normalized.contains("opus") { return .modelOpus }
  if normalized.contains("sonnet") { return .modelSonnet }
  if normalized.contains("haiku") { return .modelHaiku }
  if normalized.hasPrefix("gpt") { return .providerCodex }
  return .accent
}

private func share(
  _ entry: ServerUsageBreakdownEntryPayload,
  totalCost: Double,
  totalTokens: UInt64
) -> Double {
  if totalCost > 0 {
    return max(0, min(1, entry.totalCostUSD / totalCost))
  }
  guard totalTokens > 0 else { return 0 }
  return max(0, min(1, Double(entry.totalTokens) / Double(totalTokens)))
}

private func usageSessionShare(
  _ entry: ServerUsageSessionSummaryPayload,
  totalCost: Double,
  totalTokens: UInt64
) -> Double {
  if totalCost > 0 {
    return max(0, min(1, entry.totalCostUSD / totalCost))
  }
  guard totalTokens > 0 else { return 0 }
  return max(0, min(1, Double(entry.totalTokens) / Double(totalTokens)))
}

private func turnCountLabel(_ turns: UInt64) -> String {
  turns == 1 ? "1 turn" : "\(turns) turns"
}

private func distinctSessionLabel(_ count: UInt64) -> String {
  count == 1 ? "distinct session" : "distinct sessions"
}

private func usageScopeLabel(activeServerCount: Int) -> String {
  if activeServerCount > 1 {
    return "Today across \(activeServerCount) servers"
  }
  return "Today on current server"
}

private func dayLabel(from unix: UInt64?) -> String {
  guard let unix else { return "Day" }
  let date = Date(timeIntervalSince1970: TimeInterval(unix))
  let formatter = DateFormatter()
  formatter.dateFormat = "EEE"
  return formatter.string(from: date)
}

private func codexRateLimitLabel(_ type: ServerCodexRateLimitReachedType) -> String {
  switch type {
    case .rateLimitReached:
      "Rate limited"
    case .workspaceOwnerCreditsDepleted, .workspaceMemberCreditsDepleted:
      "Credits depleted"
    case .workspaceOwnerUsageLimitReached, .workspaceMemberUsageLimitReached:
      "Usage limit reached"
  }
}
