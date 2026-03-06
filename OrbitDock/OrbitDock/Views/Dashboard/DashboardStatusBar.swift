//
//  DashboardStatusBar.swift
//  OrbitDock
//
//  Pinned status bar — merges title, usage gauges, stats, and action buttons
//  into a single compact line. Usage gauges are always visible (never scrolled away).
//

import SwiftUI

struct DashboardStatusBar: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router

  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool

  @State private var showServerSettings = false
  @State private var showAppSettings = false
  @State private var showStatsPopover = false
  private let registry = UsageServiceRegistry.shared

  private var activeConnection: ServerConnection {
    runtimeRegistry.activeConnection
  }

  private var activeConnectionStatus: ConnectionStatus {
    runtimeRegistry.activeConnectionStatus
  }

  private var enabledRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
  }

  private var endpointStatuses: [ConnectionStatus] {
    enabledRuntimes.map { runtime in
      runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
    }
  }

  private var enabledEndpointCount: Int {
    enabledRuntimes.count
  }

  private var connectedEndpointCount: Int {
    endpointStatuses.filter {
      if case .connected = $0 { return true }
      return false
    }.count
  }

  private var failedEndpointCount: Int {
    endpointStatuses.filter {
      if case .failed = $0 { return true }
      return false
    }.count
  }

  private var hasMultipleEndpoints: Bool {
    enabledEndpointCount > 1
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var todayStats: StatusBarStats {
    let calendar = Calendar.current
    let todaySessions = sessions.filter {
      guard let start = $0.startedAt else { return false }
      return calendar.isDateInToday(start)
    }
    return StatusBarStats.from(sessions: todaySessions)
  }

  private var allStats: StatusBarStats {
    StatusBarStats.from(sessions: sessions)
  }

  var body: some View {
    VStack(spacing: 0) {
      switch layoutMode {
        case .phoneCompact: compactStatusBar
        case .pad, .desktop: desktopStatusBar
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(Color.backgroundSecondary)
    .sheet(isPresented: $showServerSettings) {
      ServerSettingsSheet()
    }
    .sheet(isPresented: $showAppSettings) {
      SettingsView(showsCloseButton: true)
    }
  }

  // MARK: - Desktop / Pad Layout

  private var desktopStatusBar: some View {
    HStack(spacing: Spacing.sm) {
      // Usage gauges — prime position, always visible
      UsageGaugesPanel()

      Spacer(minLength: Spacing.sm)

      syncIndicator

      // Compact today stats
      todayStatsCluster

      // Action buttons
      HStack(spacing: Spacing.xs) {
        newSessionMenu
        quickSwitchButton
        settingsButton
        serverSettingsButton
      }
    }
    .padding(.horizontal, Spacing.lg_)
    .padding(.vertical, Spacing.sm_)
  }

  // MARK: - Phone Compact Layout

  private var compactStatusBar: some View {
    VStack(spacing: Spacing.xs) {
      // Line 1: actions + sync
      HStack(spacing: Spacing.sm) {
        syncIndicator

        Spacer()

        HStack(spacing: Spacing.xs) {
          newSessionMenu
          quickSwitchButton
          settingsButton
          serverSettingsButton
        }
      }

      // Line 2: usage gauges
      ScrollView(.horizontal, showsIndicators: false) {
        UsageGaugesPanel()
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
  }

  // MARK: - Today Stats

  private var todayStatsCluster: some View {
    Button {
      showStatsPopover.toggle()
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(formatCostCompact(todayStats.cost))
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)

        Text("·")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Text("\(todayStats.sessionCount) sess")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        Text("·")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Text(formatCompactTokens(todayStats.tokens))
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xs)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showStatsPopover) {
      StatsPopoverContent(todayStats: todayStats, allStats: allStats)
    }
  }

  // MARK: - Sync Indicator

  @ViewBuilder
  private var syncIndicator: some View {
    if isInitialLoading || isRefreshingCachedSessions {
      HStack(spacing: Spacing.xs) {
        ProgressView()
          .controlSize(.mini)
        Text("Syncing")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  // MARK: - Action Buttons

  private var newSessionMenu: some View {
    Menu {
      Button {
        router.showNewClaudeSheet = true
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        router.showNewCodexSheet = true
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.accent)
        .frame(width: 26, height: 26)
        .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .help("New session")
  }

  private var quickSwitchButton: some View {
    Button(action: { router.openQuickSwitcher() }) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
    .help("Search sessions (⌘K)")
  }

  private var settingsButton: some View {
    Button(action: { showAppSettings = true }) {
      Image(systemName: "gearshape")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
  }

  private var serverSettingsButton: some View {
    Button(action: { showServerSettings = true }) {
      Image(systemName: "server.rack")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(serverSettingsIconColor)
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Connection Colors

  private var serverSettingsIconColor: Color {
    if hasMultipleEndpoints {
      return endpointSummaryColor
    }
    return statusTint(for: activeConnectionStatus)
  }

  private var endpointSummaryColor: Color {
    if enabledEndpointCount == 0 {
      return Color.textTertiary
    }
    if failedEndpointCount > 0 {
      return Color.statusPermission
    }
    if connectedEndpointCount == enabledEndpointCount {
      return Color.statusWorking
    }
    if connectedEndpointCount > 0 {
      return Color.statusQuestion
    }
    return Color.textTertiary
  }

  private func statusTint(for status: ConnectionStatus) -> Color {
    switch status {
      case .connected:
        Color.statusWorking
      case .connecting:
        Color.statusQuestion
      case .failed:
        Color.statusPermission
      case .disconnected:
        Color.textSecondary
    }
  }

  // MARK: - Formatting

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
}

// MARK: - Usage Gauges Panel

struct UsageGaugesPanel: View {
  let registry = UsageServiceRegistry.shared

  private var activeProviders: [(provider: Provider, windows: [RateLimitWindow], isLoading: Bool)] {
    registry.allProviders.map { provider in
      (provider: provider, windows: registry.windows(for: provider), isLoading: registry.isLoading(for: provider))
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(activeProviders.enumerated()), id: \.element.provider.id) { index, entry in
        if index > 0 {
          dividerBar
        }

        ProviderGaugeMini(
          provider: entry.provider,
          windows: entry.windows,
          isLoading: entry.isLoading
        )
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.5))
    )
  }

  private var dividerBar: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
      .frame(width: 1)
      .padding(.vertical, Spacing.xs)
      .padding(.horizontal, Spacing.sm)
  }
}

private struct ProviderGaugeMini: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool

  private var hasData: Bool {
    !windows.isEmpty || isLoading
  }

  var body: some View {
    HStack(spacing: hasData ? Spacing.md_ : Spacing.sm_) {
      // Provider icon + name — always visible
      HStack(spacing: Spacing.xs) {
        Image(systemName: provider.icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textSecondary)
      }

      if !windows.isEmpty {
        HStack(spacing: Spacing.md) {
          ForEach(windows) { window in
            MiniGauge(window: window, provider: provider)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.mini)
      } else {
        Text("—")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, Spacing.sm_)
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
    if window.projectedAtReset >= 90 { return .feedbackCaution }
    return .feedbackPositive
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
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Label + percentage
      HStack(spacing: Spacing.sm_) {
        Text(window.label)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .fixedSize()

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)
          .fixedSize()
      }

      // Progress bar with projection
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(Color.primary.opacity(0.1))

          // Projected (behind current)
          if showProjection {
            RoundedRectangle(cornerRadius: Radius.xs)
              .fill(projectedColor.opacity(0.3))
              .frame(width: geo.size.width * min(1, window.projectedAtReset / 100))
          }

          RoundedRectangle(cornerRadius: Radius.xs)
            .fill(usageColor)
            .frame(width: geo.size.width * min(1, window.utilization / 100))
        }
      }
      .frame(width: 70, height: 5)

      // Pace + projection
      HStack(spacing: Spacing.xs) {
        if !paceLabel.isEmpty {
          Text(paceLabel)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(projectedColor)
        }

        if showProjection {
          Text("→\(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(projectedColor.opacity(0.8))
        }
      }
      .fixedSize()
    }
  }
}

// MARK: - Stats Popover

private struct StatsPopoverContent: View {
  let todayStats: StatusBarStats
  let allStats: StatusBarStats

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      statsSection(title: "Today", stats: todayStats, accentColor: .accent)
      statsSection(title: "All Time", stats: allStats, accentColor: .textSecondary)
    }
    .padding(Spacing.lg)
    .frame(minWidth: 280)
  }

  private func statsSection(title: String, stats: StatusBarStats, accentColor: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      Text(title.uppercased())
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(accentColor)
        .tracking(0.5)

      HStack(spacing: Spacing.xl) {
        statItem(label: "Cost", value: formatCost(stats.cost))
        statItem(label: "Sessions", value: "\(stats.sessionCount)")
        statItem(label: "Tokens", value: formatTokens(stats.tokens))
      }

      // Cost by model breakdown
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

              Text(formatCost(item.cost))
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

  private func formatCost(_ cost: Double) -> String {
    if cost >= 1_000 { return String(format: "$%.1fK", cost / 1_000) }
    if cost >= 100 { return String(format: "$%.0f", cost) }
    if cost >= 10 { return String(format: "$%.1f", cost) }
    return String(format: "$%.2f", cost)
  }

  private func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
    return "\(value)"
  }
}

// MARK: - Stats Data Model

private struct StatusBarStats {
  let sessionCount: Int
  let cost: Double
  let tokens: Int
  let costByModel: [(model: String, cost: Double, color: Color)]

  static func from(sessions: [Session]) -> StatusBarStats {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var cost = 0.0
    var costByModel: [String: Double] = [:]

    for session in sessions {
      let input = session.inputTokens ?? 0
      let output = session.outputTokens ?? 0
      let cached = session.cachedTokens ?? 0
      let context = session.effectiveContextInputTokens
      let hasServerUsage = input > 0 || output > 0 || cached > 0 || context > 0

      var sessionInput = 0
      var sessionOutput = 0
      var sessionCacheRead = 0
      let sessionCacheCreation = 0

      if hasServerUsage {
        sessionInput = input
        sessionOutput = output
        sessionCacheRead = cached
      } else if session.totalTokens > 0 {
        sessionOutput = session.totalTokens
      }

      inputTokens += sessionInput
      outputTokens += sessionOutput
      cacheReadTokens += sessionCacheRead
      cacheCreationTokens += sessionCacheCreation

      let rawModel = session.model
      let sessionCost = ModelPricingService.shared.calculateCost(
        model: rawModel,
        inputTokens: sessionInput,
        outputTokens: sessionOutput,
        cacheReadTokens: sessionCacheRead,
        cacheCreationTokens: sessionCacheCreation
      )
      cost += sessionCost

      if let model = normalizeModelName(rawModel) {
        costByModel[model, default: 0] += sessionCost
      }
    }

    let tokens = inputTokens + outputTokens

    let sortedCosts = costByModel.sorted { $0.value > $1.value }.map {
      (model: $0.key, cost: $0.value, color: colorForModel($0.key))
    }

    return StatusBarStats(
      sessionCount: sessions.count,
      cost: cost,
      tokens: tokens,
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

// MARK: - Preview

#Preview {
  VStack(spacing: 0) {
    DashboardStatusBar(
      sessions: [
        Session(
          id: "1",
          projectPath: "/p",
          model: "claude-opus-4-5-20251101",
          status: .active,
          workStatus: .working,
          startedAt: Date()
        ),
        Session(
          id: "2",
          projectPath: "/p",
          model: "claude-sonnet-4-20250514",
          status: .active,
          workStatus: .permission,
          startedAt: Date(),
          attentionReason: .awaitingPermission
        ),
      ],
      isInitialLoading: false,
      isRefreshingCachedSessions: false
    )

    Divider().foregroundStyle(Color.panelBorder)

    Color.backgroundPrimary
      .frame(height: 200)
  }
  .frame(width: 900)
  .environment(ServerRuntimeRegistry.shared)
  .environment(AppRouter())
}
