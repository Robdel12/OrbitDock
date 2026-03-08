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
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router

  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool

  @State private var showServerSettings = false
  @State private var showAppSettings = false
  @State private var showStatsPopover = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var dashboardStatsSessions: [Session] {
    sessions.filter { !$0.isActive || $0.hasLiveEndpointConnection }
  }

  private var todayStats: StatusBarStats {
    let calendar = Calendar.current
    let todaySessions = dashboardStatsSessions.filter {
      guard let start = $0.startedAt else { return false }
      return calendar.isDateInToday(start)
    }
    return StatusBarStats.from(sessions: todaySessions)
  }

  private var allStats: StatusBarStats {
    StatusBarStats.from(sessions: sessions)
  }

  // Connection state
  private var enabledRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
  }

  private var endpointStatuses: [ConnectionStatus] {
    enabledRuntimes.map { runtime in
      runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
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

  private var connectionSummaryText: String? {
    if unavailableEndpointCount > 0 {
      return unavailableEndpointCount == 1 ? "1 offline" : "\(unavailableEndpointCount) offline"
    }
    if connectingEndpointCount > 0 || isInitialLoading || isRefreshingCachedSessions {
      return "Syncing"
    }
    return nil
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
    VStack(spacing: 0) {
      switch layoutMode {
        case .phoneCompact: phoneHeader
        case .pad, .desktop: desktopHeader
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

  // MARK: - Desktop Header

  private var desktopHeader: some View {
    HStack(spacing: Spacing.md) {
      DashboardTabSwitcher()

      Spacer(minLength: Spacing.md)

      if let connectionSummaryText {
        connectionStateBadge(text: connectionSummaryText)
      }

      todayStatsCluster

      actionButtons
    }
    .padding(.horizontal, Spacing.section)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Phone Header

  private var phoneHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.sm) {
        DashboardTabSwitcher(compact: true)
          .layoutPriority(1)

        Spacer(minLength: Spacing.sm_)

        phoneActionButtons
      }

      HStack(spacing: Spacing.sm_) {
        phoneStatsButton

        Spacer(minLength: Spacing.sm_)

        if let connectionSummaryText {
          connectionStateBadge(text: connectionSummaryText)
        }

        if let serverButtonLabelText {
          phoneServerStatusBadge(text: serverButtonLabelText)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var phoneStatsButton: some View {
    Button {
      showStatsPopover.toggle()
    } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "gauge.with.dots.needle.33percent")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: 1) {
          Text("Usage")
            .font(.system(size: TypeScale.mini, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text("\(DashboardFormatters.costCompact(todayStats.cost)) today")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule(style: .continuous)
          .fill(Color.backgroundTertiary.opacity(0.58))
          .overlay(
            Capsule(style: .continuous)
              .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Show usage and stats")
    .accessibilityHint("Opens provider usage limits, today's totals, and archive stats.")
    .popover(isPresented: $showStatsPopover) {
      StatsPopoverContent(todayStats: todayStats, allStats: allStats)
    }
  }

  // MARK: - Stats Cluster

  private var todayStatsCluster: some View {
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

  // MARK: - Connection Badge

  private func connectionStateBadge(text: String) -> some View {
    HStack(spacing: Spacing.xs) {
      if unavailableEndpointCount > 0 {
        Image(systemName: "wifi.slash")
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(Color.statusPermission)
      } else {
        ProgressView()
          .controlSize(.mini)
      }

      Text(text)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(unavailableEndpointCount > 0 ? Color.statusPermission : Color.textTertiary)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(
      (unavailableEndpointCount > 0 ? Color.statusPermission : Color.backgroundTertiary)
        .opacity(unavailableEndpointCount > 0 ? OpacityTier.light : 0.6),
      in: Capsule()
    )
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack(spacing: Spacing.sm_) {
      newSessionMenu
      quickSwitchButton
      settingsButton
      serverButton(showLabel: true)
    }
  }

  private var phoneActionButtons: some View {
    HStack(spacing: Spacing.xs) {
      newSessionMenu
      quickSwitchButton
      settingsButton
      serverButton(showLabel: false)
    }
  }

  private var newSessionMenu: some View {
    Menu {
      Button {
        router.openNewSession(provider: .claude)
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        router.openNewSession(provider: .codex)
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.accent)
        .frame(width: 28, height: 28)
        .background(Color.accent.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .help("New session")
  }

  private var quickSwitchButton: some View {
    Button(action: { router.openQuickSwitcher() }) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .help("Search sessions (⌘K)")
  }

  private var settingsButton: some View {
    Button(action: { showAppSettings = true }) {
      Image(systemName: "gearshape")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
  }

  private func serverButton(showLabel: Bool) -> some View {
    Button(action: { showServerSettings = true }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "server.rack")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(serverStatusColor)

        if showLabel, let serverButtonLabelText {
          Text(serverButtonLabelText)
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(serverStatusColor)
        }
      }
      .frame(height: 28)
      .padding(.horizontal, showLabel ? Spacing.sm_ : Spacing.xs)
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
      tabButton(label: "Library", icon: "books.vertical", tab: .library)
    }
    .padding(compact ? Spacing.xxs : Spacing.gap)
    .background(Color.backgroundTertiary.opacity(0.6), in: Capsule())
  }

  private func tabButton(label: String, icon: String, tab: DashboardTab) -> some View {
    let isActive = router.dashboardTab == tab

    return Button {
      withAnimation(Motion.hover) {
        router.dashboardTab = tab
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
      .padding(.horizontal, compact ? Spacing.sm : Spacing.md_)
      .padding(.vertical, compact ? Spacing.sm_ : Spacing.sm_)
      .background(
        isActive
          ? Color.surfaceHover
          : Color.clear,
        in: Capsule()
      )
      .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
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
