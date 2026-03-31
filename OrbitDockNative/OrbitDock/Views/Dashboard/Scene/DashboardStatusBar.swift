//
//  DashboardStatusBar.swift
//  OrbitDock
//
//  Pinned header: desktop stays single-row, phone breaks into two rows.
//  Usage gauges live in the sidebar (desktop) or stats popover (phone).
//  Connection health is an inline badge on the server button.
//

import SwiftUI

// MARK: - Status Bar

struct DashboardStatusBar: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.modelPricingService) private var modelPricingService
  @Environment(OrbitDockAppRuntime.self) private var appRuntime
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(UsageServiceRegistry.self) private var usageRegistry
  @Environment(AppRouter.self) private var router
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  let sessions: [RootSessionNode]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool

  #if os(iOS)
  @State private var showAppSettings = false
  #endif
  @State private var showStatsPopover = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var dashboardStatsSessions: [RootSessionNode] {
    sessions.filter { !$0.isActive || $0.hasLiveEndpointConnection }
  }

  private var precomputedStats: (today: StatusBarStats, all: StatusBarStats) {
    let calculator = modelPricingService.calculatorSnapshot
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())

    let todaySessions = dashboardStatsSessions.filter {
      guard let start = $0.startedAt else { return false }
      return start >= startOfToday
    }
    return (
      today: StatusBarStats.from(sessions: todaySessions, costCalculator: calculator),
      all: StatusBarStats.from(sessions: sessions, costCalculator: calculator)
    )
  }

  private var displayedStats: (today: StatusBarStats, allTime: StatusBarStats) {
    let fallback = precomputedStats
    return StatusBarStats.resolve(
      summary: usageRegistry.summary,
      fallbackToday: fallback.today,
      fallbackAllTime: fallback.all
    )
  }

  /// Connection state
  private var enabledRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
  }

  private var endpointStatuses: [ConnectionStatus] {
    enabledRuntimes.map { runtime in
      runtimeRegistry.displayConnectionStatus(for: runtime.endpoint.id)
    }
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

  private var connectingEndpointCount: Int {
    endpointStatuses.filter {
      if case .connecting = $0 { return true }
      return false
    }.count
  }

  private var disconnectedEndpointCount: Int {
    endpointStatuses.filter {
      if case .disconnected = $0 { return true }
      return false
    }.count
  }

  private var unavailableEndpointCount: Int {
    failedEndpointCount + disconnectedEndpointCount
  }

  private var serverStatusColor: Color {
    if enabledRuntimes.isEmpty { return Color.textTertiary }
    if unavailableEndpointCount > 0 { return Color.statusPermission }
    if connectingEndpointCount > 0 { return Color.statusQuestion }
    if connectedEndpointCount == enabledRuntimes.count { return Color.feedbackPositive }
    if connectedEndpointCount > 0 { return Color.statusQuestion }
    return Color.textTertiary
  }

  private var serverButtonLabelText: String? {
    guard !enabledRuntimes.isEmpty else { return nil }
    if unavailableEndpointCount > 0 {
      return enabledRuntimes.count == 1 ? "Offline" : "\(connectedEndpointCount) live"
    }
    if connectingEndpointCount > 0 {
      return connectedEndpointCount > 0 ? "\(connectedEndpointCount) live" : "Connecting"
    }
    if enabledRuntimes.count > 1 {
      return "\(connectedEndpointCount) live"
    }
    return nil
  }

  private var serverButtonHelpText: String {
    if enabledRuntimes.isEmpty {
      return "No endpoints enabled"
    }

    let segments = [
      "\(connectedEndpointCount) connected",
      unavailableEndpointCount > 0 ? "\(unavailableEndpointCount) offline" : nil,
      connectingEndpointCount > 0 ? "\(connectingEndpointCount) syncing" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: ", ")

    return "\(segments) across \(enabledRuntimes.count) enabled endpoint\(enabledRuntimes.count == 1 ? "" : "s")"
  }

  var body: some View {
    let stats = displayedStats
    VStack(spacing: 0) {
      switch layoutMode {
        case .phoneCompact:
          phoneHeader(todayStats: stats.today, allStats: stats.allTime)
        case .pad, .desktop:
          desktopHeader(todayStats: stats.today, allStats: stats.allTime)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(Color.backgroundSecondary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.panelBorder.opacity(layoutMode.isPhoneCompact ? 0.45 : 0.28))
        .frame(height: 1)
    }
    #if os(iOS)
      .sheet(isPresented: $showAppSettings) {
        SettingsView(showsCloseButton: true, initialPane: appRuntime.requestedSettingsPane)
          .environment(appRuntime)
          .environment(appRuntime.notificationCoordinator)
          .environment(runtimeRegistry)
          .environment(runtimeRegistry.activeSessionStore)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
      }
    #endif
    .task(id: Calendar.current.startOfDay(for: Date())) {
      await usageRegistry.refreshAll()
    }
  }

  // MARK: - Desktop Header

  private func desktopHeader(todayStats: StatusBarStats, allStats: StatusBarStats) -> some View {
    HStack(spacing: Spacing.md) {
      DashboardTabSwitcher()

      Spacer(minLength: Spacing.md)

      todayStatsCluster(todayStats: todayStats, allStats: allStats)

      actionButtons
    }
    .padding(.horizontal, Spacing.section)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Phone Header

  private func phoneHeader(todayStats: StatusBarStats, allStats: StatusBarStats) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.sm) {
        DashboardTabSwitcher(compact: true)
          .layoutPriority(1)

        Spacer(minLength: Spacing.sm)

        phoneActionButtons
      }

      HStack(spacing: Spacing.sm_) {
        phoneStatsButton(todayStats: todayStats, allStats: allStats)

        Spacer(minLength: Spacing.sm_)

        if let serverButtonLabelText {
          phoneServerStatusBadge(text: serverButtonLabelText)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.sm)
  }

  private func phoneStatsButton(todayStats: StatusBarStats, allStats: StatusBarStats) -> some View {
    Button {
      showStatsPopover.toggle()
    } label: {
      HStack(spacing: Spacing.gap) {
        Image(systemName: "gauge.with.dots.needle.33percent")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Usage")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        Text(DashboardFormatters.costCompact(todayStats.cost))
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)

        Text("today")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
      .padding(.vertical, Spacing.xxs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Show usage and stats")
    .accessibilityHint("Opens provider usage limits, today's totals, and archive stats.")
    .popover(isPresented: $showStatsPopover) {
      StatsPopoverContent(todayStats: todayStats, allStats: allStats)
    }
  }

  // MARK: - Stats Cluster

  private func todayStatsCluster(todayStats: StatusBarStats, allStats: StatusBarStats) -> some View {
    Button {
      showStatsPopover.toggle()
    } label: {
      HStack(spacing: Spacing.sm_) {
        Text("Today")
          .font(.system(size: TypeScale.mini, weight: .semibold))
          .foregroundStyle(Color.textTertiary)

        headerMetric(
          value: DashboardFormatters.costCompact(todayStats.cost),
          label: "cost",
          emphasize: true,
          monospace: true
        )

        headerMetric(
          value: "\(todayStats.sessionCount)",
          label: todayStats.sessionCount == 1 ? "session" : "sessions"
        )

        headerMetric(
          value: DashboardFormatters.tokens(todayStats.tokens, zeroDisplay: "0"),
          label: "tokens",
          monospace: true
        )
      }
    }
    .buttonStyle(.plain)
    .help(
      "Today: \(DashboardFormatters.cost(todayStats.cost)), \(todayStats.sessionCount) sessions, \(DashboardFormatters.tokensUpperK(todayStats.tokens)) tokens"
    )
    .popover(isPresented: $showStatsPopover) {
      StatsPopoverContent(todayStats: todayStats, allStats: allStats)
    }
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: Spacing.sm_) {
      newSessionButton(showLabel: true)
      quickSwitchButton
      settingsButton
      serverButton(showLabel: true)
    }
  }

  private var phoneActionButtons: some View {
    HStack(spacing: Spacing.xs) {
      newSessionButton(showLabel: false)
      quickSwitchButton
      settingsButton
      serverButton(showLabel: false)
    }
    .padding(.vertical, Spacing.xxs)
  }

  private func newSessionButton(showLabel: Bool) -> some View {
    Button {
      router.openNewSessionSheet()
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.accent)

        if showLabel {
          Text("New Session")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }
      }
      .frame(minWidth: showLabel ? 0 : 32, minHeight: 32, alignment: .center)
      .padding(.horizontal, showLabel ? Spacing.xs : 0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open the new session sheet")
    .contextMenu {
      Button {
        router.openNewSession(provider: .claude)
      } label: {
        Label("Start in Claude", systemImage: "sparkles")
      }

      Button {
        router.openNewSession(provider: .codex)
      } label: {
        Label("Start in Codex", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    }
  }

  private var quickSwitchButton: some View {
    Button(action: { router.openQuickSwitcher() }) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.plain)
    .help("Search sessions (⌘K)")
  }

  private var settingsButton: some View {
    Button(action: {
      appRuntime.requestedSettingsPane = .workspace
      #if os(macOS)
        openSettings()
      #else
        showAppSettings = true
      #endif
    }) {
      Image(systemName: "gearshape")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.plain)
  }

  private func serverButton(showLabel: Bool) -> some View {
    Button(action: {
      appRuntime.requestedSettingsPane = .servers
      #if os(macOS)
        openSettings()
      #else
        showAppSettings = true
      #endif
    }) {
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(serverStatusColor)
          .frame(width: 6, height: 6)
          .shadow(
            color: connectedEndpointCount > 0 ? serverStatusColor.opacity(0.5) : .clear,
            radius: 3
          )

        Image(systemName: "server.rack")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(serverStatusColor)

        if showLabel, let serverButtonLabelText {
          Text(serverButtonLabelText)
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(serverStatusColor)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        serverStatusColor.opacity(OpacityTier.subtle),
        in: Capsule()
      )
      .overlay(
        Capsule()
          .stroke(serverStatusColor.opacity(OpacityTier.light), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help(serverButtonHelpText)
  }

  private func phoneServerStatusBadge(text: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(serverStatusColor)
        .frame(width: 6, height: 6)

      Text(text)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(serverStatusColor)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(
      serverStatusColor.opacity(OpacityTier.light),
      in: Capsule()
    )
  }

  private func headerMetric(
    value: String,
    label: String,
    emphasize: Bool = false,
    monospace: Bool = false
  ) -> some View {
    HStack(spacing: Spacing.xxs) {
      Text(value)
        .font(
          .system(
            size: emphasize ? TypeScale.body : TypeScale.caption,
            weight: emphasize ? .bold : .semibold,
            design: monospace ? .monospaced : .default
          )
        )
        .foregroundStyle(emphasize ? Color.textPrimary : Color.textSecondary)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

}

// MARK: - Tab Switcher (extracted component)

struct DashboardTabSwitcher: View {
  @Environment(AppRouter.self) private var router
  var compact: Bool = false

  var body: some View {
    HStack(spacing: 0) {
      tabButton(label: "Active", icon: "bolt.fill", tab: .missionControl)
      tabButton(label: "Missions", icon: "antenna.radiowaves.left.and.right", tab: .missions)
      tabButton(label: "Library", icon: "books.vertical", tab: .library)
    }
    .padding(compact ? Spacing.gap : Spacing.gap)
    .background(
      RoundedRectangle(cornerRadius: compact ? Radius.xl : Radius.xl, style: .continuous)
        .fill(compact ? Color.backgroundTertiary.opacity(0.96) : Color.backgroundTertiary.opacity(0.6))
        .overlay(
          RoundedRectangle(cornerRadius: compact ? Radius.xl : Radius.xl, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(compact ? OpacityTier.medium : 0), lineWidth: 1)
        )
    )
  }

  private func tabButton(label: String, icon: String, tab: DashboardTab) -> some View {
    let isActive = router.dashboardTab == tab

    return Button {
      withAnimation(Motion.hover) {
        router.selectDashboardTab(tab, source: .dashboardTabSwitcher)
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.system(size: compact ? 8 : 9, weight: .semibold))
        Text(label)
          .font(.system(size: compact ? TypeScale.micro : TypeScale.caption, weight: isActive ? .bold : .medium))
          .lineLimit(1)
      }
      .foregroundStyle(isActive ? Color.textPrimary : Color.textTertiary)
      .frame(maxWidth: compact ? .infinity : nil, minHeight: compact ? 30 : nil)
      .padding(.horizontal, compact ? Spacing.sm : Spacing.md_)
      .padding(.vertical, compact ? Spacing.sm_ : Spacing.sm_)
      .background(
        isActive
          ? Color.surfaceSelected
          : Color.clear,
        in: RoundedRectangle(cornerRadius: compact ? Radius.lg : Radius.xl, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: compact ? Radius.lg : Radius.xl, style: .continuous)
          .stroke(
            isActive && compact ? Color.accent.opacity(OpacityTier.light) : Color.clear,
            lineWidth: 1
          )
      )
      .fixedSize(horizontal: !compact, vertical: false)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Preview

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  let router = AppRouter()
  let appRuntime = OrbitDockAppRuntime()
  VStack(spacing: 0) {
    DashboardStatusBar(
      sessions: [],
      isInitialLoading: false,
      isRefreshingCachedSessions: false
    )

    Divider().foregroundStyle(Color.panelBorder)

    Color.backgroundPrimary
      .frame(height: 200)
  }
  .frame(width: 900)
  .environment(appRuntime)
  .environment(runtimeRegistry)
  .environment(router)
}
