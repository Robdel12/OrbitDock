import SwiftUI

func relativeServerUpdateCheckedAtLabel(
  _ rawValue: String?,
  relativeTo referenceDate: Date = Date()
) -> String {
  guard let rawValue else { return "unknown" }

  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let fallbackFormatter = ISO8601DateFormatter()
  fallbackFormatter.formatOptions = [.withInternetDateTime]

  guard
    let date = formatter.date(from: rawValue) ?? fallbackFormatter.date(from: rawValue)
  else {
    return "unknown"
  }

  let relativeFormatter = RelativeDateTimeFormatter()
  relativeFormatter.unitsStyle = .abbreviated
  return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
}

private func connectionStatusIdentity(_ status: ConnectionStatus) -> String {
  switch status {
    case .connected:
      "connected"
    case .connecting:
      "connecting"
    case .disconnected:
      "disconnected"
    case let .failed(reason):
      "failed:\(reason)"
  }
}

private enum ServerUpdateChannelOption: String, CaseIterable, Identifiable {
  case stable
  case beta
  case nightly

  var id: String {
    rawValue
  }

  var title: String {
    rawValue.capitalized
  }
}

@MainActor
@Observable
final class ServerUpdatesSettingsModel {
  enum UpgradePhase: Equatable {
    case idle
    case waitingForRestart
    case verifying
  }

  enum SupportState: Equatable {
    case idle
    case loading
    case supported
    case legacy
    case disconnected
    case failed
  }

  struct EndpointState: Equatable {
    let endpointId: UUID
    var support: SupportState = .idle
    var currentVersion: String?
    var selectedChannel: String = ServerUpdateChannelOption.stable.rawValue
    var updateStatus: ServerUpdateStatus?
    var infoMessage: String?
    var errorMessage: String?
    var isChecking = false
    var isChangingChannel = false
    var isStartingUpgrade = false
    var pendingUpgradeVersion: String?
    var upgradePhase: UpgradePhase = .idle
    var isUpgradeInFlight: Bool {
      isStartingUpgrade || pendingUpgradeVersion != nil || upgradePhase != .idle
    }
  }

  private(set) var statesByEndpointId: [UUID: EndpointState] = [:]
  @ObservationIgnored private var upgradeWatchdogTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var lastConnectionStatusByEndpointId: [UUID: String] = [:]

  func state(for endpointId: UUID) -> EndpointState {
    statesByEndpointId[endpointId] ?? EndpointState(endpointId: endpointId)
  }

  func reload(for runtimes: [ServerRuntime]) async {
    let liveIds = Set(runtimes.map(\.id))
    statesByEndpointId = statesByEndpointId.filter { liveIds.contains($0.key) }
    lastConnectionStatusByEndpointId = lastConnectionStatusByEndpointId.filter { liveIds.contains($0.key) }
    for endpointId in Array(upgradeWatchdogTasks.keys) where !liveIds.contains(endpointId) {
      upgradeWatchdogTasks[endpointId]?.cancel()
      upgradeWatchdogTasks[endpointId] = nil
    }
    for runtime in runtimes {
      await refresh(runtime, forceCheck: false)
    }
  }

  func refresh(_ runtime: ServerRuntime, forceCheck: Bool) async {
    let endpointId = runtime.id
    var state = state(for: endpointId)
    state.support = .loading
    state.errorMessage = nil
    if forceCheck {
      state.isChecking = true
    }
    statesByEndpointId[endpointId] = state

    if runtime.connection.connectionStatus != .connected {
      let health = try? await runtime.clients.updates.fetchHealth()
      state.currentVersion = health?.version
      state.support = .disconnected
      state.updateStatus = nil
      state.infoMessage = health?.version.map {
        "OrbitDock server v\($0) is reachable, but this endpoint is not connected in the app yet."
      } ?? "Connect this endpoint to check its update channel and upgrade it from OrbitDock."
      state.isChecking = false
      statesByEndpointId[endpointId] = state
      return
    }

    do {
      let meta = try await runtime.clients.updates.fetchServerMeta()
      let checkResponse: ServerUpdateCheckResponse? = if forceCheck {
        try await runtime.clients.updates.checkForUpdates()
      } else {
        nil
      }
      let updateStatus: ServerUpdateStatus?
      if let checkedStatus = checkResponse?.status {
        updateStatus = checkedStatus
      } else if let cachedStatus = meta.updateStatus {
        updateStatus = cachedStatus
      } else {
        updateStatus = try await runtime.clients.updates.fetchUpdateStatus()
      }

      let channel: String
      if let updateStatus {
        channel = updateStatus.channel
      } else {
        channel = try await runtime.clients.updates.fetchUpdateChannel().channel
      }

      state.support = .supported
      state.currentVersion = meta.serverVersion
      state.selectedChannel = normalizedChannel(channel)
      state.updateStatus = updateStatus
      state.infoMessage = resolvedInfoMessage(
        current: state.infoMessage,
        fallback: checkResponse?.error,
        preservingUpgradePhase: state.upgradePhase
      )
      state.isChecking = false
      statesByEndpointId[endpointId] = state
    } catch {
      await apply(error: error, to: runtime, endpointId: endpointId, checking: forceCheck)
    }
  }

  fileprivate func setChannel(_ channel: ServerUpdateChannelOption, for runtime: ServerRuntime) async {
    let endpointId = runtime.id
    var state = state(for: endpointId)
    let previousChannel = state.selectedChannel
    state.isChangingChannel = true
    state.errorMessage = nil
    state.selectedChannel = channel.rawValue
    statesByEndpointId[endpointId] = state

    do {
      let response = try await runtime.clients.updates.setUpdateChannel(channel.rawValue)
      state.support = .supported
      state.isChangingChannel = false
      state.selectedChannel = normalizedChannel(response.status?.channel ?? channel.rawValue)
      state.updateStatus = response.status
      state.infoMessage = response.error ?? "Channel set to \(channel.title)."
      statesByEndpointId[endpointId] = state
    } catch {
      state.selectedChannel = previousChannel
      statesByEndpointId[endpointId] = state
      await apply(error: error, to: runtime, endpointId: endpointId, checking: false)
    }
  }

  func startUpgrade(for runtime: ServerRuntime) async {
    let endpointId = runtime.id
    var state = state(for: endpointId)
    let targetVersion = state.updateStatus?.latestVersion
    state.isStartingUpgrade = true
    state.pendingUpgradeVersion = targetVersion
    state.upgradePhase = .waitingForRestart
    state.infoMessage = targetVersion.map {
      "Starting upgrade to v\($0). OrbitDock will disconnect briefly while the server restarts."
    } ?? "Starting OrbitDock upgrade. The server may disconnect briefly while it restarts."
    state.errorMessage = nil
    statesByEndpointId[endpointId] = state

    do {
      let response = try await runtime.clients.updates.startUpgrade(
        restart: true,
        channel: state.selectedChannel,
        version: targetVersion
      )
      state.isStartingUpgrade = false
      state.pendingUpgradeVersion = response.targetVersion ?? targetVersion
      state.upgradePhase = .waitingForRestart
      state.infoMessage = upgradeStartedMessage(
        targetVersion: state.pendingUpgradeVersion,
        serverMessage: response.message
      )
      statesByEndpointId[endpointId] = state
      startUpgradeWatchdog(for: runtime)
    } catch {
      await apply(
        error: error,
        to: runtime,
        endpointId: endpointId,
        checking: false,
        preservingUpgradeState: false
      )
    }
  }

  func handleConnectionChanges(for runtimes: [ServerRuntime]) async {
    var runtimesToRefresh: [ServerRuntime] = []

    for runtime in runtimes {
      let endpointId = runtime.id
      let currentStatus = runtime.connection.connectionStatus
      let currentIdentity = connectionStatusIdentity(currentStatus)
      let previousIdentity = lastConnectionStatusByEndpointId[endpointId]
      lastConnectionStatusByEndpointId[endpointId] = currentIdentity

      var state = state(for: endpointId)
      guard state.pendingUpgradeVersion != nil || state.upgradePhase != .idle else {
        if currentIdentity == "connected", previousIdentity != nil, previousIdentity != "connected",
          state.support == .disconnected || state.support == .failed
        {
          runtimesToRefresh.append(runtime)
        }
        continue
      }

      switch currentStatus {
        case .connected:
          guard !state.isStartingUpgrade, state.upgradePhase != .verifying else { continue }
          state.upgradePhase = .verifying
          state.infoMessage = "OrbitDock is back online. Verifying the new server version..."
          state.errorMessage = nil
          statesByEndpointId[endpointId] = state
          await confirmUpgrade(for: runtime)

        case .connecting:
          state.infoMessage = "OrbitDock is restarting. Reconnecting to the server..."
          statesByEndpointId[endpointId] = state

        case .disconnected, .failed:
          state.infoMessage = "OrbitDock is restarting. The app will reconnect automatically when the server is back."
          statesByEndpointId[endpointId] = state
      }
    }

    for runtime in runtimesToRefresh {
      await refresh(runtime, forceCheck: false)
    }
  }

  private func apply(
    error: Error,
    to runtime: ServerRuntime,
    endpointId: UUID,
    checking: Bool,
    preservingUpgradeState: Bool = true
  ) async {
    var state = state(for: endpointId)
    state.isChecking = false
    state.isChangingChannel = false
    state.isStartingUpgrade = false

    if !preservingUpgradeState {
      clearUpgradeTracking(for: endpointId)
      state.upgradePhase = .idle
      state.pendingUpgradeVersion = nil
    }

    if let requestError = error as? ServerRequestError {
      switch requestError {
        case .transport:
          let health = try? await runtime.clients.updates.fetchHealth()
          state.currentVersion = health?.version
          state.support = .disconnected
          if preservingUpgradeState && (state.pendingUpgradeVersion != nil || state.upgradePhase != .idle) {
            state.infoMessage = "OrbitDock is restarting. The app will reconnect automatically when the server is back."
          } else {
            state.infoMessage = health?.version.map {
              "OrbitDock server v\($0) is reachable, but this endpoint is not connected in the app yet."
            } ?? "Connect this endpoint to manage updates from OrbitDock."
          }

        case let .httpStatus(status, _, _) where status == 404:
          clearUpgradeTracking(for: endpointId)
          let health = try? await runtime.clients.updates.fetchHealth()
          state.currentVersion = health?.version
          state.support = .legacy
          state.updateStatus = nil
          state.infoMessage =
            "This server predates OrbitDock's in-app update controls. Run orbitdock upgrade --yes --restart on the machine that hosts the server."

        default:
          clearUpgradeTracking(for: endpointId)
          state.upgradePhase = .idle
          state.pendingUpgradeVersion = nil
          state.support = .failed
          state.errorMessage = requestError.recoverySuggestion ?? requestError.localizedDescription
      }
    } else {
      clearUpgradeTracking(for: endpointId)
      state.upgradePhase = .idle
      state.pendingUpgradeVersion = nil
      state.support = .failed
      state.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    if checking, state.support == .supported, state.errorMessage == nil {
      state.infoMessage = "OrbitDock couldn't refresh update status right now."
    }

    statesByEndpointId[endpointId] = state
  }

  private func confirmUpgrade(for runtime: ServerRuntime) async {
    let endpointId = runtime.id
    var state = state(for: endpointId)
    let expectedVersion = state.pendingUpgradeVersion

    do {
      let meta = try await runtime.clients.updates.fetchServerMeta()
      let updateStatus = meta.updateStatus

      state.currentVersion = meta.serverVersion
      state.selectedChannel = normalizedChannel(updateStatus?.channel ?? state.selectedChannel)
      state.support = .supported
      state.errorMessage = nil
      state.isStartingUpgrade = false
      state.upgradePhase = .idle
      state.pendingUpgradeVersion = nil
      state.updateStatus = optimisticPostUpgradeStatus(
        existing: updateStatus ?? state.updateStatus,
        currentVersion: meta.serverVersion,
        channel: state.selectedChannel
      )

      if matchesExpectedVersion(meta.serverVersion, expected: expectedVersion) {
        state.infoMessage = "OrbitDock server upgraded to v\(meta.serverVersion)."
      } else if let expectedVersion {
        state.errorMessage =
          "OrbitDock came back on v\(meta.serverVersion), but the requested upgrade target was v\(expectedVersion). Check the server manually before retrying."
        state.infoMessage = nil
      } else {
        state.infoMessage = "OrbitDock server upgrade completed."
      }

      clearUpgradeTracking(for: endpointId)
      statesByEndpointId[endpointId] = state
    } catch {
      state.upgradePhase = .waitingForRestart
      state.infoMessage = "OrbitDock reconnected, but upgrade verification is still settling."
      statesByEndpointId[endpointId] = state
    }
  }

  private func startUpgradeWatchdog(for runtime: ServerRuntime) {
    let endpointId = runtime.id
    clearUpgradeTracking(for: endpointId)
    upgradeWatchdogTasks[endpointId] = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(90))
      } catch {
        return
      }
      guard let self else { return }
      await self.finishUpgradeWatchdog(for: runtime)
    }
  }

  private func finishUpgradeWatchdog(for runtime: ServerRuntime) async {
    let endpointId = runtime.id
    defer {
      upgradeWatchdogTasks[endpointId] = nil
    }

    var state = state(for: endpointId)
    guard state.pendingUpgradeVersion != nil || state.upgradePhase != .idle else { return }

    let expectedVersion = state.pendingUpgradeVersion
    let health = try? await runtime.clients.updates.fetchHealth()

    state.isStartingUpgrade = false
    state.upgradePhase = .idle
    state.pendingUpgradeVersion = nil

    if let version = health?.version, matchesExpectedVersion(version, expected: expectedVersion) {
      state.currentVersion = version
      state.updateStatus = optimisticPostUpgradeStatus(
        existing: state.updateStatus,
        currentVersion: version,
        channel: state.selectedChannel
      )
      state.support = runtime.connection.connectionStatus == .connected ? .supported : .disconnected
      state.errorMessage = nil
      state.infoMessage = runtime.connection.connectionStatus == .connected
        ? "OrbitDock server upgraded to v\(version)."
        : "OrbitDock server upgraded to v\(version), but this endpoint has not reconnected yet."
      statesByEndpointId[endpointId] = state
      return
    }

    if let version = health?.version {
      state.currentVersion = version
      state.support = .supported
      state.infoMessage = nil
      state.errorMessage =
        "Upgrade started, but the server is still reporting v\(version). If this server was launched manually, restart it on the host machine and try again."
      statesByEndpointId[endpointId] = state
      return
    }

    state.support = .disconnected
    state.infoMessage = nil
    state.errorMessage =
      "Upgrade started, but OrbitDock did not come back in time. If this server was launched manually, restart it on the host machine. If the install failed, the previous binary should still be available as orbitdock.bak."
    statesByEndpointId[endpointId] = state
  }

  private func clearUpgradeTracking(for endpointId: UUID) {
    upgradeWatchdogTasks[endpointId]?.cancel()
    upgradeWatchdogTasks[endpointId] = nil
  }

  private func upgradeStartedMessage(targetVersion: String?, serverMessage: String) -> String {
    if let targetVersion {
      return "Upgrade to v\(targetVersion) started. \(serverMessage)"
    }
    return serverMessage
  }

  private func matchesExpectedVersion(_ current: String, expected: String?) -> Bool {
    guard let expected else { return true }
    return normalizedVersionValue(current) == normalizedVersionValue(expected)
  }

  private func normalizedVersionValue(_ rawValue: String) -> String {
    rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "v", with: "", options: [.anchored])
  }

  private func optimisticPostUpgradeStatus(
    existing: ServerUpdateStatus?,
    currentVersion: String,
    channel: String
  ) -> ServerUpdateStatus {
    ServerUpdateStatus(
      updateAvailable: false,
      latestVersion: currentVersion,
      releaseURL: existing?.releaseURL,
      channel: existing?.channel ?? channel,
      checkedAt: ISO8601DateFormatter().string(from: Date())
    )
  }

  private func resolvedInfoMessage(
    current: String?,
    fallback: String?,
    preservingUpgradePhase: UpgradePhase
  ) -> String? {
    if preservingUpgradePhase != .idle {
      return current
    }
    return fallback
  }

  private func normalizedChannel(_ rawValue: String) -> String {
    ServerUpdateChannelOption(rawValue: rawValue)?.rawValue ?? ServerUpdateChannelOption.stable.rawValue
  }
}

struct ServerUpdatesSettingsView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var model = ServerUpdatesSettingsModel()

  private var orderedRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.sorted { lhs, rhs in
      lhs.endpoint.name.localizedCaseInsensitiveCompare(rhs.endpoint.name) == .orderedAscending
    }
  }

  private var runtimesIdentity: String {
    orderedRuntimes
      .map { "\($0.id.uuidString):\($0.endpoint.name):\($0.endpoint.isEnabled)" }
      .joined(separator: "|")
  }

  private var runtimeConnectionIdentity: String {
    orderedRuntimes
      .map { runtime in
        let status = runtimeRegistry.displayConnectionStatus(for: runtime.id)
        return "\(runtime.id.uuidString):\(statusIdentity(status))"
      }
      .joined(separator: "|")
  }

  var body: some View {
    SettingsSection(title: "SERVER UPDATES", icon: "arrow.triangle.2.circlepath") {
      if orderedRuntimes.isEmpty {
        Text("Add a server endpoint to manage update channels and install new OrbitDock server releases.")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
      } else {
        VStack(spacing: Spacing.md) {
          ForEach(orderedRuntimes, id: \.id) { runtime in
            endpointCard(runtime)
          }
        }
      }
    }
    .task(id: runtimesIdentity) {
      await model.reload(for: orderedRuntimes)
    }
    .task(id: runtimeConnectionIdentity) {
      await model.handleConnectionChanges(for: orderedRuntimes)
    }
  }

  private func endpointCard(_ runtime: ServerRuntime) -> some View {
    let state = model.state(for: runtime.id)
    let channelSelection = Binding<ServerUpdateChannelOption>(
      get: {
        ServerUpdateChannelOption(rawValue: state.selectedChannel) ?? .stable
      },
      set: { newValue in
        Task {
          await model.setChannel(newValue, for: runtime)
        }
      }
    )

    return VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Circle()
          .fill(supportColor(for: state.support))
          .frame(width: 8, height: 8)

        Text(runtime.endpoint.name)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Text(versionLabel(for: state))
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)

        Spacer()

        if state.isUpgradeInFlight {
          inFlightBadge()
        } else if let status = state.updateStatus {
          updateBadge(status)
        }
      }

      ViewThatFits(in: .horizontal) {
        controlsRow(runtime: runtime, state: state, channelSelection: channelSelection)
        VStack(alignment: .leading, spacing: Spacing.md) {
          channelControl(selection: channelSelection, state: state)
          HStack(spacing: Spacing.md) {
            checkButton(runtime: runtime, state: state)
            upgradeButton(runtime: runtime, state: state)
          }
        }
      }

      if let status = state.updateStatus {
        HStack(spacing: Spacing.sm) {
          Text("Checked")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text(checkedAtLabel(status.checkedAt))
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textSecondary)

          Spacer()

          if let releaseURL = releaseURL(for: status) {
            Link("Release Notes", destination: releaseURL)
              .font(.system(size: TypeScale.meta, weight: .semibold))
              .foregroundStyle(Color.accent)
          }
        }
      }

      if let infoMessage = state.infoMessage {
        messageBanner(
          infoMessage,
          color: state.support == .legacy ? Color.statusQuestion : Color.feedbackPositive,
          icon: state.support == .legacy ? "wrench.and.screwdriver.fill" : "info.circle.fill"
        )
      }

      if let errorMessage = state.errorMessage {
        messageBanner(
          errorMessage,
          color: Color.statusPermission,
          icon: "exclamationmark.triangle.fill"
        )
      }
    }
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.panelBorder, lineWidth: 1)
    )
  }

  private func supportColor(for support: ServerUpdatesSettingsModel.SupportState) -> Color {
    switch support {
      case .idle, .loading:
        Color.statusQuestion
      case .supported:
        Color.feedbackPositive
      case .legacy:
        Color.statusQuestion
      case .disconnected, .failed:
        Color.statusPermission
    }
  }

  private func versionLabel(for state: ServerUpdatesSettingsModel.EndpointState) -> String {
    if let version = state.currentVersion, !version.isEmpty {
      return "v\(version)"
    }
    return "version unknown"
  }

  private func canUpgrade(_ state: ServerUpdatesSettingsModel.EndpointState) -> Bool {
    guard state.support == .supported else { return false }
    guard let status = state.updateStatus else { return false }
    return status.updateAvailable && status.latestVersion != nil
  }

  private func upgradeButtonTitle(for state: ServerUpdatesSettingsModel.EndpointState) -> String {
    if state.isStartingUpgrade {
      return "Starting..."
    }
    switch state.upgradePhase {
      case .waitingForRestart:
        return "Restarting..."
      case .verifying:
        return "Verifying..."
      case .idle:
        break
    }

    guard state.support == .supported else {
      return "Upgrade Unavailable"
    }
    guard let status = state.updateStatus else {
      return "Check First"
    }
    guard status.updateAvailable else {
      return "Up To Date"
    }
    if let latestVersion = status.latestVersion {
      return "Upgrade to \(latestVersion)"
    }
    return "Upgrade"
  }

  @ViewBuilder
  private func controlsRow(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState,
    channelSelection: Binding<ServerUpdateChannelOption>
  ) -> some View {
    HStack(spacing: Spacing.md) {
      channelControl(selection: channelSelection, state: state)
      Spacer()
      checkButton(runtime: runtime, state: state)
      upgradeButton(runtime: runtime, state: state)
    }
  }

  @ViewBuilder
  private func channelControl(
    selection: Binding<ServerUpdateChannelOption>,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text("Channel")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
      Picker("Update Channel", selection: selection) {
        ForEach(ServerUpdateChannelOption.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.menu)
      .disabled(state.support != .supported || state.isChangingChannel || state.isUpgradeInFlight)
    }
  }

  @ViewBuilder
  private func checkButton(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    Button {
      Task {
        await model.refresh(runtime, forceCheck: true)
      }
    } label: {
      HStack(spacing: Spacing.sm_) {
        if state.isChecking {
          ProgressView()
            .controlSize(.small)
        }
        Text("Check Now")
      }
    }
    .buttonStyle(.bordered)
    .disabled(state.support == .loading || state.isChangingChannel || state.isUpgradeInFlight)
  }

  @ViewBuilder
  private func upgradeButton(
    runtime: ServerRuntime,
    state: ServerUpdatesSettingsModel.EndpointState
  ) -> some View {
    Button {
      Task {
        await model.startUpgrade(for: runtime)
      }
    } label: {
      HStack(spacing: Spacing.sm_) {
        if state.isStartingUpgrade || state.upgradePhase != .idle {
          ProgressView()
            .controlSize(.small)
        }
        Text(upgradeButtonTitle(for: state))
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(Color.accent)
    .disabled(!canUpgrade(state) || state.isChecking || state.isChangingChannel || state.isUpgradeInFlight)
  }

  @ViewBuilder
  private func updateBadge(_ status: ServerUpdateStatus) -> some View {
    let color = status.updateAvailable ? Color.statusQuestion : Color.feedbackPositive
    let icon = status.updateAvailable ? "arrow.up.circle.fill" : "checkmark.circle.fill"
    let label = status.updateAvailable
      ? "Update Available"
      : "Up To Date"

    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  @ViewBuilder
  private func inFlightBadge() -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
        .font(.system(size: IconScale.sm, weight: .semibold))
      Text("Restarting")
        .font(.system(size: TypeScale.mini, weight: .semibold))
    }
    .foregroundStyle(Color.statusQuestion)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.gap)
    .background(Color.statusQuestion.opacity(OpacityTier.light), in: Capsule())
  }

  private func statusIdentity(_ status: ConnectionStatus) -> String {
    connectionStatusIdentity(status)
  }

  @ViewBuilder
  private func messageBanner(
    _ text: String,
    color: Color,
    icon: String
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.lg))
        .foregroundStyle(color)

      Text(text)
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Spacing.md)
    .background(color.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(color.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  private func checkedAtLabel(_ rawValue: String?) -> String {
    relativeServerUpdateCheckedAtLabel(rawValue)
  }

  private func releaseURL(for status: ServerUpdateStatus) -> URL? {
    guard let rawValue = status.releaseURL else { return nil }
    return URL(string: rawValue)
  }
}
