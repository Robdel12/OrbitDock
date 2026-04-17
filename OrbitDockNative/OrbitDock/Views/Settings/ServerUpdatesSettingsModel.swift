import Observation
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

func connectionStatusIdentity(_ status: ConnectionStatus) -> String {
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

enum ServerUpdateChannelOption: String, CaseIterable, Identifiable {
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

  func setChannel(_ channel: ServerUpdateChannelOption, for runtime: ServerRuntime) async {
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
