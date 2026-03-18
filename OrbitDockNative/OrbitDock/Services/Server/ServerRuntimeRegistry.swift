import Foundation

#if canImport(UIKit)
  import UIKit
#endif

@Observable
@MainActor
final class ServerRuntimeRegistry {
  private let endpointSettings: ServerEndpointSettingsClient
  private let endpointsProvider: () -> [ServerEndpoint]
  private let runtimeFactory: (ServerEndpoint) -> ServerRuntime
  private let clientIdentityProvider: () -> ServerClientIdentity
  private let shouldBootstrapFromSettings: Bool
  private let controlPlaneCoordinator = ServerControlPlaneCoordinator()
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private(set) var connectionStatusByEndpointId: [UUID: ConnectionStatus] = [:]
  private(set) var readinessByEndpointId: [UUID: ServerRuntimeReadiness] = [:]
  private(set) var activeEndpointId: UUID?
  private(set) var primaryEndpointId: UUID?
  private(set) var hasPrimaryEndpointConflict = false
  private(set) var hasConfiguredEndpoints = false
  let readinessUpdates: AsyncStream<Void>
  @ObservationIgnored private let readinessContinuation: AsyncStream<Void>.Continuation

  // MARK: - Session list aggregation (across all endpoints)

  @ObservationIgnored private var sessionsByEndpoint: [UUID: [String: RootSessionNode]] = [:]
  private(set) var aggregatedSessions: [RootSessionNode] = []

  @ObservationIgnored
  private lazy var fallbackSessionStore: SessionStore = {
    let baseURL = URL(string: "http://127.0.0.1:3000")!
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: nil)
    let clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    return SessionStore(
      clients: clients,
      connection: ServerConnection(authToken: nil),
      endpointId: UUID()
    )
  }()

  @ObservationIgnored private var statusObserverTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var readinessObserverTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var connectionListenerTokensByEndpointId: [UUID: ServerConnectionListenerToken] = [:]
  @ObservationIgnored private var suspendedForBackground = false

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

  private static func currentIdentity(defaults: UserDefaults = .standard) -> ServerClientIdentity {
    let key = "orbitdock.client.id"
    let clientId: String
    if let persisted = defaults.string(forKey: key), !persisted.isEmpty {
      clientId = persisted
    } else {
      let generated = UUID().uuidString
      defaults.set(generated, forKey: key)
      clientId = generated
    }
    return ServerClientIdentity(clientId: clientId, deviceName: resolvedDeviceName())
  }

  init() {
    var readinessContinuation: AsyncStream<Void>.Continuation!
    readinessUpdates = AsyncStream { readinessContinuation = $0 }
    self.readinessContinuation = readinessContinuation
    let endpointSettings = ServerEndpointSettingsClient.live()
    self.endpointSettings = endpointSettings
    endpointsProvider = { endpointSettings.endpoints() }
    runtimeFactory = { ServerRuntime(endpoint: $0) }
    clientIdentityProvider = { Self.currentIdentity() }
    shouldBootstrapFromSettings = !AppRuntimeMode.isRunningTestsProcess
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    endpointSettings: ServerEndpointSettingsClient? = nil,
    shouldBootstrapFromSettings: Bool = true
  ) {
    var readinessContinuation: AsyncStream<Void>.Continuation!
    readinessUpdates = AsyncStream { readinessContinuation = $0 }
    self.readinessContinuation = readinessContinuation
    self.endpointSettings = endpointSettings ?? .live()
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = { Self.currentIdentity() }
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    clientIdentityProvider: @escaping () -> ServerClientIdentity,
    endpointSettings: ServerEndpointSettingsClient? = nil,
    shouldBootstrapFromSettings: Bool = true
  ) {
    var readinessContinuation: AsyncStream<Void>.Continuation!
    readinessUpdates = AsyncStream { readinessContinuation = $0 }
    self.readinessContinuation = readinessContinuation
    self.endpointSettings = endpointSettings ?? .live()
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = clientIdentityProvider
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
  }

  deinit {
    readinessContinuation.finish()
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
    readinessByEndpointId.values.filter(\.transportReady).count
  }

  var hasEnabledRuntimes: Bool {
    runtimesByEndpointId.values.contains(where: \.endpoint.isEnabled)
  }

  var hasAnyQueryReadyRuntime: Bool {
    readinessByEndpointId.values.contains(where: \.queryReady)
  }

  var activeConnectionStatus: ConnectionStatus {
    guard let activeEndpointId else { return .disconnected }
    return displayConnectionStatus(for: activeEndpointId)
  }

  var activeRuntimeReadiness: ServerRuntimeReadiness {
    guard let activeEndpointId else { return .offline }
    return readinessByEndpointId[activeEndpointId] ?? .offline
  }

  func runtimeReadiness(for endpointId: UUID) -> ServerRuntimeReadiness {
    readinessByEndpointId[endpointId] ?? .offline
  }

  func displayConnectionStatus(for endpointId: UUID) -> ConnectionStatus {
    let status = connectionStatusByEndpointId[endpointId] ?? .disconnected
    let readiness = runtimeReadiness(for: endpointId)
    return ServerRuntimeRegistryPlanner.displayConnectionStatus(
      connectionStatus: status,
      readiness: readiness
    )
  }

  var displayConnectionStatusByEndpointId: [UUID: ConnectionStatus] {
    Dictionary(
      uniqueKeysWithValues: runtimesByEndpointId.keys.map { endpointId in
        (endpointId, displayConnectionStatus(for: endpointId))
      }
    )
  }

  func waitForAnyQueryReadyRuntime() async {
    guard hasEnabledRuntimes, !hasAnyQueryReadyRuntime else { return }
    let updates = readinessUpdates
    for await _ in updates {
      if hasAnyQueryReadyRuntime || !hasEnabledRuntimes {
        return
      }
    }
  }

  func configureFromSettings(startEnabled: Bool) {
    let configuredEndpoints = endpointsProvider()
    hasConfiguredEndpoints = !configuredEndpoints.isEmpty
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      unbindRuntimeState(runtime)
      runtime.stop()
      runtimesByEndpointId[id] = nil
      statusObserverTasks[id]?.cancel()
      statusObserverTasks[id] = nil
      readinessObserverTasks[id]?.cancel()
      readinessObserverTasks[id] = nil
      connectionStatusByEndpointId[id] = nil
      readinessByEndpointId[id] = nil
      sessionsByEndpoint[id] = nil
      readinessContinuation.yield(())
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          unbindRuntimeState(existing)
          existing.stop()
          statusObserverTasks[endpoint.id]?.cancel()
          statusObserverTasks[endpoint.id] = nil
          readinessObserverTasks[endpoint.id]?.cancel()
          readinessObserverTasks[endpoint.id] = nil

          sessionsByEndpoint[endpoint.id] = nil

          let replacement = runtimeFactory(endpoint)
          runtimesByEndpointId[endpoint.id] = replacement
          bindRuntimeState(replacement)
        }
      } else {
        let runtime = runtimeFactory(endpoint)
        runtimesByEndpointId[endpoint.id] = runtime
        bindRuntimeState(runtime)
      }
    }

    activeEndpointId = ServerRuntimeRegistryPlanner.resolvedActiveEndpointID(
      currentActiveEndpointId: activeEndpointId,
      configuredEndpoints: configuredEndpoints
    )
    recomputePrimaryEndpoint(from: configuredEndpoints)
    recomputeAggregatedSessions()
    readinessContinuation.yield(())

    guard startEnabled else { return }

    for endpoint in configuredEndpoints where endpoint.isEnabled {
      runtimesByEndpointId[endpoint.id]?.start()
    }

    schedulePrimaryClaimReconciliation()
  }

  func setActiveEndpoint(id: UUID) {
    guard runtimesByEndpointId[id] != nil else { return }
    activeEndpointId = id
    recomputePrimaryEndpoint()
    schedulePrimaryClaimReconciliation()
  }

  func reconnect(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.reconnect()
  }

  func setServerRole(endpointId: UUID, isPrimary: Bool) {
    ensureInitialized()
    guard let targetRuntime = runtimesByEndpointId[endpointId], targetRuntime.endpoint.isEnabled else { return }
    let ports = enabledControlPlanePorts()
    Task {
      await controlPlaneCoordinator.applyServerRoleChange(
        endpointId: targetRuntime.endpoint.id,
        isPrimary: isPrimary,
        ports: ports
      )
    }
  }

  func stop(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.stop()
  }

  func startEnabledRuntimes() {
    configureFromSettings(startEnabled: true)
  }

  func reconnectAllIfNeeded() {
    for runtime in runtimesByEndpointId.values {
      runtime.reconnectIfNeeded()
    }
  }

  @discardableResult
  func refreshEnabledSessionLists() -> [UUID] {
    runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtime in
        if runtime.isStarted {
          runtime.reconnectIfNeeded()
        }
        return runtime.endpoint.id
      }
  }

  func refreshAll() async {
    for runtime in runtimes where runtime.endpoint.isEnabled && runtime.isStarted {
      runtime.reconnectIfNeeded()
    }
  }

  func handleMemoryPressure() {
    // Stub: memory pressure handling
  }

  func stopAllRuntimes() {
    for runtime in runtimesByEndpointId.values {
      runtime.stop()
    }
  }

  #if os(iOS)
    func suspendForBackground() {
      guard !suspendedForBackground else { return }
      suspendedForBackground = true
      for runtime in runtimesByEndpointId.values where runtime.endpoint.isEnabled {
        runtime.suspendInactive()
      }
    }

    func resumeFromBackgroundIfNeeded() {
      ensureInitialized()
      guard suspendedForBackground else { return }
      suspendedForBackground = false
      startEnabledRuntimes()
    }
  #endif

  func waitForControlPlaneIdleForTests() async {
    await controlPlaneCoordinator.waitUntilIdleForTests()
  }

  func sessionStore(for session: RootSessionNode, fallback: SessionStore) -> SessionStore {
    guard let runtime = runtimesByEndpointId[session.endpointId] else {
      return fallback
    }
    return runtime.sessionStore
  }

  func sessionObservable(for session: RootSessionNode, fallback: SessionStore) -> SessionObservable {
    sessionStore(for: session, fallback: fallback).session(session.sessionId)
  }

  func isForkedSession(_ session: RootSessionNode, fallback: SessionStore) -> Bool {
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

  func sessionNode(forScopedID scopedID: String) -> RootSessionNode? {
    for index in sessionsByEndpoint.values {
      if let node = index[scopedID] { return node }
    }
    return nil
  }

  static func preferredActiveEndpointID(from endpoints: [ServerEndpoint]) -> UUID? {
    ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: endpoints)
  }

  // MARK: - Private

  private func ensureInitialized() {
    if shouldBootstrapFromSettings, runtimesByEndpointId.isEmpty {
      configureFromSettings(startEnabled: false)
    }

    #if os(iOS)
      if activeEndpointId == nil {
        activeEndpointId = runtimesByEndpointId.keys.first
      }
      recomputePrimaryEndpoint()
    #else
      if runtimesByEndpointId.isEmpty {
        let endpoint = ServerEndpoint.localDefault(defaultPort: endpointSettings.defaultPort)
        let runtime = runtimeFactory(endpoint)
        runtimesByEndpointId[endpoint.id] = runtime
        bindRuntimeState(runtime)
      }

      if activeEndpointId == nil {
        activeEndpointId = runtimesByEndpointId.keys.first
      }
      recomputePrimaryEndpoint()
    #endif
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
    let declaredPrimaryCandidates = enabledEndpoints.filter { endpoint in
      runtimesByEndpointId[endpoint.id]?.sessionStore.serverIsPrimary == true
    }

    hasPrimaryEndpointConflict = declaredPrimaryCandidates.count > 1
    primaryEndpointId = ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: configuredEndpoints)
  }

  private func schedulePrimaryClaimReconciliation() {
    let identity = clientIdentityProvider()
    let ports = controlPlaneReadyPorts()
    let plan = ServerControlPlanePlan(
      enabledEndpointIds: ports.map(\.endpointId),
      primaryEndpointId: primaryEndpointId
    )
    Task {
      await controlPlaneCoordinator.submitPrimaryClaimPlan(
        plan,
        ports: ports,
        clientIdentity: identity
      )
    }
  }

  @ObservationIgnored private var runtimeObservationTasks: [UUID: Task<Void, Never>] = [:]

  private func bindRuntimeState(_ runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    connectionStatusByEndpointId[endpointId] = runtime.connection.connectionStatus
    readinessByEndpointId[endpointId] = runtime.readiness

    // Cancel any existing observation for this endpoint
    runtimeObservationTasks[endpointId]?.cancel()
    if let token = connectionListenerTokensByEndpointId.removeValue(forKey: endpointId) {
      runtime.connection.removeListener(token)
    }

    // Observe connection status + session list changes from the ServerConnection
    let endpointName = runtime.endpoint.name
    connectionListenerTokensByEndpointId[endpointId] = runtime.connection.addListener { [
      weak self,
      weak runtime
    ] event in
      guard let self, let runtime else { return }
      switch event {
        case let .connectionStatusChanged(status):
          self.connectionStatusByEndpointId[endpointId] = status
          self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
            connectionStatus: status,
            hasReceivedInitialRootList: runtime.connection.hasReceivedInitialSessionsList
          )

        case let .sessionsList(items):
          self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
            connectionStatus: runtime.connection.connectionStatus,
            hasReceivedInitialRootList: true
          )
          var index: [String: RootSessionNode] = [:]
          for item in items {
            let node = RootSessionNode(
              session: item, endpointId: endpointId, endpointName: endpointName,
              connectionStatus: .connected
            )
            index[node.scopedID] = node
          }
          self.sessionsByEndpoint[endpointId] = index
          self.recomputeAggregatedSessions()

        case let .sessionCreated(item), let .sessionListItemUpdated(item):
          let node = RootSessionNode(
            session: item, endpointId: endpointId, endpointName: endpointName,
            connectionStatus: .connected
          )
          self.sessionsByEndpoint[endpointId, default: [:]][node.scopedID] = node
          self.recomputeAggregatedSessions()

        case let .sessionListItemRemoved(sessionId):
          let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
          self.sessionsByEndpoint[endpointId]?[scopedID] = nil
          self.recomputeAggregatedSessions()

        case let .sessionEnded(sessionId, reason):
          let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
          if let existing = self.sessionsByEndpoint[endpointId]?[scopedID] {
            self.sessionsByEndpoint[endpointId]?[scopedID] = existing.ended(reason: reason)
            self.recomputeAggregatedSessions()
          }

        default:
          break
      }
    }
  }

  private func unbindRuntimeState(_ runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    if let token = connectionListenerTokensByEndpointId.removeValue(forKey: endpointId) {
      runtime.connection.removeListener(token)
    }
    runtimeObservationTasks[endpointId]?.cancel()
    runtimeObservationTasks[endpointId] = nil
  }

  private func recomputeAggregatedSessions() {
    let all = sessionsByEndpoint.values.flatMap(\.values)
    aggregatedSessions = all.sorted { lhs, rhs in
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }

  private func enabledControlPlanePorts() -> [ServerControlPlanePort] {
    ServerRuntimeRegistryPlanner.controlPlanePorts(
      runtimes: Array(runtimesByEndpointId.values),
      readinessByEndpointId: readinessByEndpointId,
      requireControlPlaneReady: false
    )
  }

  private func controlPlaneReadyPorts() -> [ServerControlPlanePort] {
    ServerRuntimeRegistryPlanner.controlPlanePorts(
      runtimes: Array(runtimesByEndpointId.values),
      readinessByEndpointId: readinessByEndpointId,
      requireControlPlaneReady: true
    )
  }
}
