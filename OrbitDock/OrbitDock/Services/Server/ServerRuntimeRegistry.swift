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
  private let shouldBootstrapFromSettings: Bool
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private(set) var activeEndpointId: UUID?
  private(set) var primaryEndpointId: UUID?
  private(set) var hasPrimaryEndpointConflict = false
  @ObservationIgnored
  private lazy var fallbackSessionStore: SessionStore = {
    let apiClient = APIClient(serverURL: URL(string: "http://127.0.0.1:3000")!, authToken: nil)
    let eventStream = EventStream(authToken: nil)
    return SessionStore(
      apiClient: apiClient, eventStream: eventStream,
      endpointId: UUID()
    )
  }()
  @ObservationIgnored private var statusObserverTasks: [UUID: Task<Void, Never>] = [:]

  init() {
    endpointsProvider = { ServerEndpointSettings.endpoints }
    runtimeFactory = { ServerRuntime(endpoint: $0) }
    clientIdentityProvider = { ServerClientIdentity.current() }
    shouldBootstrapFromSettings = !AppRuntimeMode.isRunningTestsProcess
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    shouldBootstrapFromSettings: Bool = true
  ) {
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = { ServerClientIdentity.current() }
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    clientIdentityProvider: @escaping () -> ServerClientIdentity,
    shouldBootstrapFromSettings: Bool = true
  ) {
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = clientIdentityProvider
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
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

  var activeSessionStore: SessionStore {
    ensureInitialized()
    if let runtime = resolvedActiveRuntime() {
      return runtime.sessionStore
    }
    return fallbackSessionStore
  }

  var connectionStatusByEndpointId: [UUID: ConnectionStatus] {
    var result: [UUID: ConnectionStatus] = [:]
    for (id, runtime) in runtimesByEndpointId {
      result[id] = runtime.eventStream.connectionStatus
    }
    return result
  }

  var serverPrimaryByEndpointId: [UUID: Bool] {
    var result: [UUID: Bool] = [:]
    for (id, runtime) in runtimesByEndpointId {
      if let isPrimary = runtime.sessionStore.serverIsPrimary {
        result[id] = isPrimary
      }
    }
    return result
  }

  var serverPrimaryClaimsByEndpointId: [UUID: [ServerClientPrimaryClaim]] {
    var result: [UUID: [ServerClientPrimaryClaim]] = [:]
    for (id, runtime) in runtimesByEndpointId {
      let claims = runtime.sessionStore.serverPrimaryClaims
      if !claims.isEmpty {
        result[id] = claims
      }
    }
    return result
  }

  var connectedRuntimeCount: Int {
    runtimes.filter {
      if case .connected = $0.eventStream.connectionStatus { return true }
      return false
    }.count
  }

  var activeConnectionStatus: ConnectionStatus {
    guard let activeEndpointId else { return .disconnected }
    return runtimesByEndpointId[activeEndpointId]?.eventStream.connectionStatus ?? .disconnected
  }

  func configureFromSettings(startEnabled: Bool) {
    let configuredEndpoints = endpointsProvider()
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      runtime.stop()
      runtimesByEndpointId[id] = nil
      statusObserverTasks[id]?.cancel()
      statusObserverTasks[id] = nil
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          existing.stop()
          statusObserverTasks[endpoint.id]?.cancel()
          statusObserverTasks[endpoint.id] = nil

          let replacement = runtimeFactory(endpoint)
          runtimesByEndpointId[endpoint.id] = replacement
        }
      } else {
        let runtime = runtimeFactory(endpoint)
        runtimesByEndpointId[endpoint.id] = runtime
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
        runtime.sessionStore.setServerRole(isPrimary: false)
      }
    }

    targetRuntime.sessionStore.setServerRole(isPrimary: isPrimary)
  }

  func stop(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.stop()
  }

  func startEnabledRuntimes() {
    configureFromSettings(startEnabled: true)
  }

  func handleMemoryPressure() {
    for runtime in runtimesByEndpointId.values {
      runtime.sessionStore.handleMemoryPressure()
    }
  }

  func stopAllRuntimes() {
    for runtime in runtimesByEndpointId.values {
      runtime.stop()
    }
  }

  func sessionStore(for session: Session, fallback: SessionStore) -> SessionStore {
    guard let endpointId = session.endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.sessionStore
  }

  func sessionObservable(for session: Session, fallback: SessionStore) -> SessionObservable {
    sessionStore(for: session, fallback: fallback).session(session.id)
  }

  func isForkedSession(_ session: Session, fallback: SessionStore) -> Bool {
    sessionObservable(for: session, fallback: fallback).forkedFrom != nil
  }

  func sessionStore(for endpointId: UUID?, fallback: SessionStore) -> SessionStore {
    guard let endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.sessionStore
  }

  func primarySessionStore(fallback: SessionStore) -> SessionStore {
    if let primaryRuntime {
      return primaryRuntime.sessionStore
    }
    return fallback
  }

  private func ensureInitialized() {
    if shouldBootstrapFromSettings, runtimesByEndpointId.isEmpty {
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
    }

    if activeEndpointId == nil {
      activeEndpointId = runtimesByEndpointId.keys.first
    }
    recomputePrimaryEndpoint()
  }

  private func resolvedActiveRuntime() -> ServerRuntime? {
    if let activeEndpointId, let runtime = runtimesByEndpointId[activeEndpointId] {
      return runtime
    }

    if let firstRuntime = runtimes.first {
      activeEndpointId = firstRuntime.endpoint.id
      recomputePrimaryEndpoint()
      return firstRuntime
    }

    return nil
  }

  private func recomputePrimaryEndpoint(from endpoints: [ServerEndpoint]? = nil) {
    let configuredEndpoints = endpoints ?? endpointsProvider()
    let enabledEndpoints = configuredEndpoints.filter(\.isEnabled)
    let previousPrimaryEndpointId = primaryEndpointId
    let declaredPrimaryCandidates = enabledEndpoints.filter { endpoint in
      runtimesByEndpointId[endpoint.id]?.sessionStore.serverIsPrimary == true
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
      runtime.sessionStore.setClientPrimaryClaim(
        clientId: identity.clientId,
        deviceName: identity.deviceName,
        isPrimary: runtime.endpoint.id == primaryEndpointId
      )
    }
  }
}
