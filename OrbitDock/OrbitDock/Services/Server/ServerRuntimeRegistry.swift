import Combine
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

struct ServerClientIdentity: Equatable {
  let clientId: String
  let deviceName: String

  private static let clientIdKey = "orbitdock.client.id"

  static func current(defaults: UserDefaults = .standard) -> ServerClientIdentity {
    let clientId: String
    if let persisted = defaults.string(forKey: clientIdKey), !persisted.isEmpty {
      clientId = persisted
    } else {
      let generated = UUID().uuidString
      defaults.set(generated, forKey: clientIdKey)
      clientId = generated
    }

    return ServerClientIdentity(clientId: clientId, deviceName: resolvedDeviceName())
  }

  private static func resolvedDeviceName() -> String {
    #if canImport(UIKit)
      let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty {
        return name
      }
    #endif

    #if os(macOS)
      if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        return name
      }
    #endif

    let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !hostName.isEmpty {
      return hostName
    }
    return "OrbitDock Client"
  }
}

@Observable
@MainActor
final class ServerRuntimeRegistry {
  static let shared = ServerRuntimeRegistry()

  private let endpointsProvider: () -> [ServerEndpoint]
  private let runtimeFactory: (ServerEndpoint) -> ServerRuntime
  private let clientIdentityProvider: () -> ServerClientIdentity
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private var statusSubscriptions: [UUID: AnyCancellable] = [:]
  private var serverRoleSubscriptions: [UUID: AnyCancellable] = [:]
  private var serverClaimSubscriptions: [UUID: AnyCancellable] = [:]
  private(set) var connectionStatusByEndpointId: [UUID: ConnectionStatus] = [:]
  private(set) var serverPrimaryByEndpointId: [UUID: Bool] = [:]
  private(set) var serverPrimaryClaimsByEndpointId: [UUID: [ServerClientPrimaryClaim]] = [:]
  private(set) var activeEndpointId: UUID?
  private(set) var primaryEndpointId: UUID?
  private(set) var hasPrimaryEndpointConflict = false

  init() {
    endpointsProvider = { ServerEndpointSettings.endpoints }
    runtimeFactory = { ServerRuntime(endpoint: $0) }
    clientIdentityProvider = { ServerClientIdentity.current() }
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime
  ) {
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = { ServerClientIdentity.current() }
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    clientIdentityProvider: @escaping () -> ServerClientIdentity
  ) {
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = clientIdentityProvider
  }

  var runtimes: [ServerRuntime] {
    runtimesByEndpointId.values.sorted { lhs, rhs in
      let lhsName = lhs.endpoint.name.lowercased()
      let rhsName = rhs.endpoint.name.lowercased()
      if lhsName != rhsName {
        return lhsName < rhsName
      }
      return lhs.endpoint.id.uuidString < rhs.endpoint.id.uuidString
    }
  }

  var activeRuntime: ServerRuntime? {
    guard let activeEndpointId else { return nil }
    return runtimesByEndpointId[activeEndpointId]
  }

  var primaryRuntime: ServerRuntime? {
    ensureInitialized()
    guard let primaryEndpointId else { return nil }
    return runtimesByEndpointId[primaryEndpointId]
  }

  var activeConnection: ServerConnection {
    ensureInitialized()
    guard let activeEndpointId, let runtime = runtimesByEndpointId[activeEndpointId] else {
      fatalError("ServerRuntimeRegistry has no active runtime")
    }
    return runtime.connection
  }

  var activeAppState: ServerAppState {
    ensureInitialized()
    guard let activeEndpointId, let runtime = runtimesByEndpointId[activeEndpointId] else {
      fatalError("ServerRuntimeRegistry has no active runtime")
    }
    return runtime.appState
  }

  var primaryConnection: ServerConnection? {
    primaryRuntime?.connection
  }

  var controlPlaneConnection: ServerConnection? {
    primaryConnection ?? activeRuntime?.connection
  }

  var connectedRuntimeCount: Int {
    runtimes.filter {
      if case .connected = connectionStatusByEndpointId[$0.endpoint.id] ?? $0.connection.status { return true }
      return false
    }.count
  }

  var activeConnectionStatus: ConnectionStatus {
    guard let activeEndpointId else { return .disconnected }
    return connectionStatusByEndpointId[activeEndpointId] ?? .disconnected
  }

  func configureFromSettings(startEnabled: Bool) {
    let configuredEndpoints = endpointsProvider()
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      runtime.stop()
      runtimesByEndpointId[id] = nil
      statusSubscriptions[id]?.cancel()
      statusSubscriptions[id] = nil
      serverRoleSubscriptions[id]?.cancel()
      serverRoleSubscriptions[id] = nil
      serverClaimSubscriptions[id]?.cancel()
      serverClaimSubscriptions[id] = nil
      connectionStatusByEndpointId[id] = nil
      serverPrimaryByEndpointId[id] = nil
      serverPrimaryClaimsByEndpointId[id] = nil
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          existing.stop()
          statusSubscriptions[endpoint.id]?.cancel()
          statusSubscriptions[endpoint.id] = nil
          serverRoleSubscriptions[endpoint.id]?.cancel()
          serverRoleSubscriptions[endpoint.id] = nil
          serverClaimSubscriptions[endpoint.id]?.cancel()
          serverClaimSubscriptions[endpoint.id] = nil
          serverPrimaryByEndpointId[endpoint.id] = nil
          serverPrimaryClaimsByEndpointId[endpoint.id] = nil

          let replacement = runtimeFactory(endpoint)
          runtimesByEndpointId[endpoint.id] = replacement
          observeConnectionState(for: replacement)
        }
      } else {
        let runtime = runtimeFactory(endpoint)
        runtimesByEndpointId[endpoint.id] = runtime
        observeConnectionState(for: runtime)
      }
    }

    let preferredActiveEndpointId = Self.preferredActiveEndpointID(from: configuredEndpoints)
    if let activeEndpointId,
       configuredEndpoints.contains(where: { $0.id == activeEndpointId && $0.isEnabled })
    {
      self.activeEndpointId = activeEndpointId
    } else {
      self.activeEndpointId = preferredActiveEndpointId
    }
    recomputePrimaryEndpoint(from: configuredEndpoints)

    guard startEnabled else { return }

    for endpoint in configuredEndpoints where endpoint.isEnabled {
      runtimesByEndpointId[endpoint.id]?.start()
    }

    syncClientPrimaryClaims()
  }

  func setActiveEndpoint(id: UUID) {
    guard runtimesByEndpointId[id] != nil else { return }
    activeEndpointId = id
    recomputePrimaryEndpoint()
  }

  func reconnect(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.reconnect()
  }

  func setServerRole(endpointId: UUID, isPrimary: Bool) {
    ensureInitialized()
    guard let targetRuntime = runtimesByEndpointId[endpointId], targetRuntime.endpoint.isEnabled else { return }

    if isPrimary {
      for runtime in runtimesByEndpointId.values where runtime.endpoint.id != endpointId && runtime.endpoint.isEnabled {
        runtime.connection.setServerRole(isPrimary: false)
      }
    }

    targetRuntime.connection.setServerRole(isPrimary: isPrimary)
  }

  func stop(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.stop()
  }

  func startEnabledRuntimes() {
    configureFromSettings(startEnabled: true)
  }

  func handleMemoryPressure() {
    for runtime in runtimesByEndpointId.values {
      runtime.appState.handleMemoryPressure()
    }
  }

  func stopAllRuntimes() {
    for runtime in runtimesByEndpointId.values {
      runtime.stop()
    }
  }

  func appState(for session: Session, fallback: ServerAppState) -> ServerAppState {
    guard let endpointId = session.endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.appState
  }

  func sessionObservable(for session: Session, fallback: ServerAppState) -> SessionObservable {
    appState(for: session, fallback: fallback).session(session.id)
  }

  func isForkedSession(_ session: Session, fallback: ServerAppState) -> Bool {
    sessionObservable(for: session, fallback: fallback).forkedFrom != nil
  }

  func appState(for endpointId: UUID?, fallback: ServerAppState) -> ServerAppState {
    guard let endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.appState
  }

  func primaryAppState(fallback: ServerAppState) -> ServerAppState {
    if let primaryRuntime {
      return primaryRuntime.appState
    }
    return fallback
  }

  func connection(for endpointId: UUID?) -> ServerConnection? {
    guard let endpointId else { return nil }
    return runtimesByEndpointId[endpointId]?.connection
  }

  private func ensureInitialized() {
    if runtimesByEndpointId.isEmpty {
      configureFromSettings(startEnabled: false)
    }

    #if os(iOS)
      // iOS should never synthesize a localhost runtime fallback.
      if activeEndpointId == nil {
        activeEndpointId = runtimesByEndpointId.keys.first
      }
      recomputePrimaryEndpoint()
      return
    #endif

    if runtimesByEndpointId.isEmpty {
      let endpoint = ServerEndpoint.localDefault(defaultPort: ServerEndpointSettings.defaultPort)
      let runtime = runtimeFactory(endpoint)
      runtimesByEndpointId[endpoint.id] = runtime
      observeConnectionState(for: runtime)
    }

    if activeEndpointId == nil {
      activeEndpointId = runtimesByEndpointId.keys.first
    }
    recomputePrimaryEndpoint()
  }

  private func observeConnectionState(for runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    connectionStatusByEndpointId[endpointId] = runtime.connection.status
    if let isPrimary = runtime.connection.serverIsPrimary {
      serverPrimaryByEndpointId[endpointId] = isPrimary
    } else {
      serverPrimaryByEndpointId[endpointId] = nil
    }
    serverPrimaryClaimsByEndpointId[endpointId] = runtime.connection.serverPrimaryClaims

    if statusSubscriptions[endpointId] == nil {
      statusSubscriptions[endpointId] = runtime.connection.$status.sink { [weak self] status in
        guard let self else { return }
        Task { @MainActor in
          self.connectionStatusByEndpointId[endpointId] = status
          self.syncClientPrimaryClaims()
        }
      }
    }

    if serverRoleSubscriptions[endpointId] == nil {
      serverRoleSubscriptions[endpointId] = runtime.connection.$serverIsPrimary.sink { [weak self] isPrimary in
        guard let self else { return }
        Task { @MainActor in
          if let isPrimary {
            self.serverPrimaryByEndpointId[endpointId] = isPrimary
          } else {
            self.serverPrimaryByEndpointId[endpointId] = nil
          }
          self.recomputePrimaryEndpoint()
        }
      }
    }

    if serverClaimSubscriptions[endpointId] == nil {
      serverClaimSubscriptions[endpointId] = runtime.connection.$serverPrimaryClaims.sink { [weak self] claims in
        guard let self else { return }
        Task { @MainActor in
          self.serverPrimaryClaimsByEndpointId[endpointId] = claims
        }
      }
    }
  }

  private func recomputePrimaryEndpoint(from endpoints: [ServerEndpoint]? = nil) {
    let configuredEndpoints = endpoints ?? endpointsProvider()
    let enabledEndpoints = configuredEndpoints.filter(\.isEnabled)
    let previousPrimaryEndpointId = primaryEndpointId
    let declaredPrimaryCandidates = enabledEndpoints.filter { endpoint in
      serverPrimaryByEndpointId[endpoint.id] == true
    }

    hasPrimaryEndpointConflict = declaredPrimaryCandidates.count > 1
    primaryEndpointId = Self.preferredActiveEndpointID(from: configuredEndpoints)

    if previousPrimaryEndpointId != primaryEndpointId {
      NotificationCenter.default.post(
        name: .serverPrimaryEndpointDidChange,
        object: nil,
        userInfo: ["endpointId": primaryEndpointId as Any]
      )
    }

    syncClientPrimaryClaims()
  }

  static func preferredActiveEndpointID(from endpoints: [ServerEndpoint]) -> UUID? {
    endpoints.first(where: { $0.isDefault && $0.isEnabled })?.id
      ?? endpoints.first(where: \.isEnabled)?.id
      ?? endpoints.first?.id
  }

  private func syncClientPrimaryClaims() {
    let identity = clientIdentityProvider()
    guard let primaryEndpointId else { return }

    for runtime in runtimesByEndpointId.values where runtime.endpoint.isEnabled {
      runtime.connection.setClientPrimaryClaim(
        clientId: identity.clientId,
        deviceName: identity.deviceName,
        isPrimary: runtime.endpoint.id == primaryEndpointId
      )
    }
  }
}
