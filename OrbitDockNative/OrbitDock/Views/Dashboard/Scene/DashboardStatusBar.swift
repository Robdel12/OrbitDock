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
  @Environment(\.modelPricingService) private var modelPricingService
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(UsageServiceRegistry.self) private var usageRegistry

  let sessions: [RootSessionNode]

  @State private var showStatsPopover = false

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


  var body: some View {
    let stats = displayedStats

    HStack(spacing: Spacing.sm_) {
      todayStatsCluster(todayStats: stats.today, allStats: stats.allTime)

      Spacer(minLength: Spacing.sm_)

      if let serverButtonLabelText {
        serverStatusBadge(text: serverButtonLabelText)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.panelBorder.opacity(0.28))
        .frame(height: 1)
    }
    .task(id: Calendar.current.startOfDay(for: Date())) {
      await usageRegistry.refreshIfNeeded(todayStart: Calendar.current.startOfDay(for: Date()))
    }
  }

  // MARK: - Stats Cluster

  private func todayStatsCluster(todayStats: StatusBarStats, allStats: StatusBarStats) -> some View {
    Button {
      showStatsPopover.toggle()
    } label: {
      HStack(spacing: Spacing.sm_) {
        Text("Today")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)

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

        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
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


  private func serverStatusBadge(text: String) -> some View {
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

// MARK: - Preview

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  VStack(spacing: 0) {
    DashboardStatusBar(sessions: [])
    Color.backgroundPrimary.frame(height: 200)
  }
  .frame(width: 900)
  .environment(runtimeRegistry)
}
