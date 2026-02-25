//
//  CommandStrip.swift
//  OrbitDock
//
//  Slim single-line header replacing the old dashboardHeader.
//  Panel toggle + title + status counts + usage bars + new session buttons + search.
//

import SwiftUI

struct CommandStrip: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool
  let onOpenPanel: () -> Void
  let onOpenQuickSwitcher: () -> Void
  let onNewClaude: () -> Void
  let onNewCodex: () -> Void

  @State private var showServerSettings = false
  @State private var showAppSettings = false
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

  private var workingCount: Int {
    sessions.filter { SessionDisplayStatus.from($0) == .working }.count
  }

  private var attentionCount: Int {
    sessions.filter { SessionDisplayStatus.from($0).needsAttention }.count
  }

  private var readyCount: Int {
    sessions.filter { $0.isActive && SessionDisplayStatus.from($0) == .reply }.count
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    Group {
      switch layoutMode {
        case .phoneCompact: compactStrip
        case .pad: padStrip
        case .desktop: desktopStrip
      }
    }
    .background(Color.backgroundSecondary)
    .sheet(isPresented: $showServerSettings) {
      ServerSettingsSheet()
    }
    .sheet(isPresented: $showAppSettings) {
      SettingsView(showsCloseButton: true)
    }
  }

  private var desktopStrip: some View {
    HStack(spacing: 10) {
      panelButton

      Text("OrbitDock")
        .font(.system(size: TypeScale.large, weight: .bold))
        .foregroundStyle(.primary)

      syncIndicator

      if !sessions.isEmpty, workingCount + attentionCount + readyCount > 0 {
        statusSummaryPill
      }

      usageGaugeStrip

      Spacer()

      newSessionMenu
      quickSwitchButton
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var padStrip: some View {
    HStack(spacing: 10) {
      panelButton

      Text("OrbitDock")
        .font(.system(size: TypeScale.large, weight: .bold))
        .foregroundStyle(.primary)

      syncIndicator

      if !sessions.isEmpty, workingCount + attentionCount + readyCount > 0 {
        statusSummaryPill
      }

      usageGaugeStrip

      Spacer()

      newSessionMenu
      quickSwitchButton
      settingsButton
      serverSettingsButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var compactStrip: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        panelButton

        Text("OrbitDock")
          .font(.system(size: TypeScale.subhead, weight: .bold))
          .foregroundStyle(.primary)

        if !sessions.isEmpty, workingCount + attentionCount + readyCount > 0 {
          compactStatusSummaryPill
        }

        compactConnectionStatusPill

        Spacer()

        if isInitialLoading || isRefreshingCachedSessions {
          ProgressView()
            .controlSize(.mini)
            .frame(width: 18, height: 18)
        }

        quickSwitchButton
        compactOverflowMenu
      }

      HStack(spacing: 8) {
        newSessionMenuButton
        Spacer()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var panelButton: some View {
    Button(action: onOpenPanel) {
      Image(systemName: "sidebar.left")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("Toggle panel (⌘1)")
  }

  @ViewBuilder
  private var syncIndicator: some View {
    if isInitialLoading || isRefreshingCachedSessions {
      HStack(spacing: 4) {
        ProgressView()
          .controlSize(.mini)
        Text("Syncing")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private var endpointHealthPill: some View {
    HStack(spacing: 5) {
      Image(systemName: "network")
        .font(.system(size: 9, weight: .semibold))
      Text("\(connectedEndpointCount)/\(enabledEndpointCount)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      if failedEndpointCount > 0 {
        Text("!\(failedEndpointCount)")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
      }
    }
    .foregroundStyle(endpointSummaryColor)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(endpointSummaryColor.opacity(0.14), in: Capsule())
    .help("Connected endpoints: \(connectedEndpointCount) of \(enabledEndpointCount)")
  }

  private var newSessionMenu: some View {
    Menu {
      Button {
        onNewClaude()
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        onNewCodex()
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
        Text("New")
          .font(.system(size: TypeScale.body, weight: .semibold))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .foregroundStyle(Color.accent)
    }
    .menuStyle(.borderlessButton)
    .help("New session")
  }

  private var newSessionMenuButton: some View {
    Menu {
      Button {
        onNewClaude()
      } label: {
        Label("Claude Session", systemImage: "sparkles")
      }

      Button {
        onNewCodex()
      } label: {
        Label("Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
        Text("New Session")
          .font(.system(size: TypeScale.body, weight: .semibold))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .foregroundStyle(Color.accent)
      .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .menuStyle(.borderlessButton)
  }

  private var serverSettingsButton: some View {
    Button(action: { showServerSettings = true }) {
      Image(systemName: "server.rack")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(serverSettingsIconColor)
        .frame(width: 28, height: 28)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var settingsButton: some View {
    Button(action: { showAppSettings = true }) {
      Image(systemName: "slider.horizontal.3")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var serverSettingsIconColor: Color {
    if hasMultipleEndpoints {
      return endpointSummaryColor
    }
    return statusTint(for: activeConnectionStatus)
  }

  private var quickSwitchButton: some View {
    Button(action: onOpenQuickSwitcher) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .frame(width: 28, height: 28)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("Search sessions (⌘K)")
  }

  private var compactOverflowMenu: some View {
    Menu {
      Section("Server") {
        if hasMultipleEndpoints {
          Label(
            "\(connectedEndpointCount) of \(enabledEndpointCount) connected",
            systemImage: "network"
          )
          Button("Reconnect Failed Endpoints") {
            reconnectFailedEndpoints()
          }
          .disabled(failedEndpointCount == 0)
          Button("Disconnect Enabled Endpoints", role: .destructive) {
            disconnectEnabledEndpoints()
          }
        } else {
          switch activeConnectionStatus {
            case .connected:
              Label("Connected", systemImage: "checkmark.circle.fill")
              Button("Disconnect", role: .destructive) {
                activeConnection.disconnect()
              }
            case .connecting:
              Label("Connecting...", systemImage: "antenna.radiowaves.left.and.right")
              Button("Cancel") {
                activeConnection.disconnect()
              }
            case .disconnected:
              Label("Disconnected", systemImage: "bolt.slash.fill")
              Button("Connect") {
                activeConnection.connect()
              }
            case .failed:
              Label("Connection Failed", systemImage: "exclamationmark.triangle.fill")
              Button("Retry") {
                activeConnection.connect()
              }
          }
        }
      }

      Button {
        showServerSettings = true
      } label: {
        Label("Server Settings", systemImage: "server.rack")
      }

      Button {
        showAppSettings = true
      } label: {
        Label("Settings", systemImage: "slider.horizontal.3")
      }

      if !registry.activeProviders.isEmpty {
        Section("Usage") {
          ForEach(registry.activeProviders) { provider in
            Text(provider.displayName)
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(compactOverflowTintColor)
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.backgroundTertiary)
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(compactOverflowTintColor.opacity(0.25), lineWidth: 1)
            )
        )
    }
    .help("More")
  }

  @ViewBuilder
  private var compactConnectionStatusPill: some View {
    if hasMultipleEndpoints {
      compactConnectionPill(
        text: "\(connectedEndpointCount)/\(enabledEndpointCount)",
        icon: "network",
        color: endpointSummaryColor
      )
    } else {
      switch activeConnectionStatus {
        case .connected:
          EmptyView()
        case .connecting:
          HStack(spacing: 4) {
            ProgressView()
              .controlSize(.mini)
              .tint(Color.statusQuestion)

            Text("Connecting")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.statusQuestion)
          }
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.statusQuestion.opacity(0.12), in: Capsule())
        case .disconnected:
          compactConnectionPill(
            text: "Offline",
            icon: "bolt.slash.fill",
            color: .textTertiary
          )
        case .failed:
          compactConnectionPill(
            text: "Offline",
            icon: "exclamationmark.triangle.fill",
            color: .statusPermission
          )
      }
    }
  }

  private func compactConnectionPill(text: String, icon: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text(text)
        .font(.system(size: TypeScale.micro, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
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

  private func reconnectFailedEndpoints() {
    for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
      let status = runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
      if case .failed = status {
        runtimeRegistry.reconnect(endpointId: runtime.endpoint.id)
      }
    }
  }

  private func disconnectEnabledEndpoints() {
    for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
      runtimeRegistry.stop(endpointId: runtime.endpoint.id)
    }
  }

  private var compactOverflowTintColor: Color {
    if hasMultipleEndpoints {
      return endpointSummaryColor
    }
    switch activeConnectionStatus {
      case .connected:
        return Color.textSecondary
      case .connecting:
        return Color.statusQuestion
      case .disconnected:
        return Color.textTertiary
      case .failed:
        return Color.statusPermission
    }
  }

  private var statusSummaryPill: some View {
    HStack(spacing: 6) {
      if workingCount > 0 {
        HStack(spacing: 3) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusWorking)
          Text("\(workingCount)")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusWorking)
        }
      }
      if attentionCount > 0 {
        HStack(spacing: 3) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusPermission)
          Text("\(attentionCount)")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusPermission)
        }
      }
      if readyCount > 0 {
        HStack(spacing: 3) {
          Image(systemName: "bubble.left.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusReply)
          Text("\(readyCount)")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
            .foregroundStyle(Color.statusReply)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.surfaceHover.opacity(0.6), in: Capsule())
  }

  private var usageGaugeStrip: some View {
    HStack(spacing: 12) {
      ForEach(registry.activeProviders) { provider in
        ProviderUsageCompact(
          provider: provider,
          windows: registry.windows(for: provider),
          isLoading: registry.isLoading(for: provider),
          error: registry.error(for: provider),
          isStale: registry.isStale(for: provider)
        )
      }
    }
  }

  private var compactStatusSummaryPill: some View {
    HStack(spacing: 6) {
      if workingCount > 0 {
        Image(systemName: "bolt.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.statusWorking)
        Text("\(workingCount)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusWorking)
      }
      if attentionCount > 0 {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.statusPermission)
        Text("\(attentionCount)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusPermission)
      }
      if readyCount > 0 {
        Image(systemName: "bubble.left.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(Color.statusReply)
        Text("\(readyCount)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusReply)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(Color.surfaceHover.opacity(0.6), in: Capsule())
  }

  // MARK: - Status Dot

  private func statusDot(count: Int, color: Color, icon: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(color)
      Text("\(count)")
        .font(.system(size: TypeScale.code, weight: .bold, design: .rounded))
        .foregroundStyle(color.opacity(0.9))
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 0) {
    CommandStrip(
      sessions: [
        Session(id: "1", projectPath: "/p", status: .active, workStatus: .working),
        Session(
          id: "2",
          projectPath: "/p",
          status: .active,
          workStatus: .permission,
          attentionReason: .awaitingPermission
        ),
        Session(id: "3", projectPath: "/p", status: .active, workStatus: .waiting, attentionReason: .awaitingReply),
      ],
      isInitialLoading: false,
      isRefreshingCachedSessions: false,
      onOpenPanel: {},
      onOpenQuickSwitcher: {},
      onNewClaude: {},
      onNewCodex: {}
    )

    Divider().foregroundStyle(Color.panelBorder)

    Color.backgroundPrimary
      .frame(height: 200)
  }
  .frame(width: 900)
  .environment(ServerRuntimeRegistry.shared)
}
