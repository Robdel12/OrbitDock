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
  let primaryEndpointUpdates: AsyncStream<UUID?>
  @ObservationIgnored private let primaryEndpointContinuation: AsyncStream<UUID?>.Continuation
  let readinessUpdates: AsyncStream<Void>
  @ObservationIgnored private let readinessContinuation: AsyncStream<Void>.Continuation
  @ObservationIgnored
  private lazy var fallbackSessionStore: SessionStore = {
    let clients = ServerClients(serverURL: URL(string: "http://127.0.0.1:3000")!, authToken: nil)
    let eventStream = EventStream(authToken: nil)
    return SessionStore(
      clients: clients, eventStream: eventStream,
      endpointId: UUID()
    )
  }()
  @ObservationIgnored private var statusObserverTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var readinessObserverTasks: [UUID: Task<Void, Never>] = [:]

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
    var primaryEndpointContinuation: AsyncStream<UUID?>.Continuation!
    primaryEndpointUpdates = AsyncStream { primaryEndpointContinuation = $0 }
    self.primaryEndpointContinuation = primaryEndpointContinuation
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
    var primaryEndpointContinuation: AsyncStream<UUID?>.Continuation!
    primaryEndpointUpdates = AsyncStream { primaryEndpointContinuation = $0 }
    self.primaryEndpointContinuation = primaryEndpointContinuation
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
    var primaryEndpointContinuation: AsyncStream<UUID?>.Continuation!
    primaryEndpointUpdates = AsyncStream { primaryEndpointContinuation = $0 }
    self.primaryEndpointContinuation = primaryEndpointContinuation
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
    primaryEndpointContinuation.finish()
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
    readinessByEndpointId.values.filter {
      $0.transportReady
    }.count
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
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      runtime.stop()
      runtimesByEndpointId[id] = nil
      statusObserverTasks[id]?.cancel()
      statusObserverTasks[id] = nil
      readinessObserverTasks[id]?.cancel()
      readinessObserverTasks[id] = nil
      connectionStatusByEndpointId[id] = nil
      readinessByEndpointId[id] = nil
      readinessContinuation.yield(())
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          existing.stop()
          statusObserverTasks[endpoint.id]?.cancel()
          statusObserverTasks[endpoint.id] = nil
          readinessObserverTasks[endpoint.id]?.cancel()
          readinessObserverTasks[endpoint.id] = nil

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

  /// Returns a ServerConnection for the primary (or first) runtime endpoint.
  var primaryConnection: ServerConnection {
    let endpoint = primaryRuntime?.endpoint
      ?? activeRuntime?.endpoint
      ?? runtimes.first?.endpoint
      ?? ServerEndpoint.localDefault()
    return ServerConnection(endpoint: endpoint)
  }

  /// Returns an AppStore suitable for the menu bar.
  var appStoreForMenuBar: AppStore {
    AppStore(connection: primaryConnection)
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
    let previousPrimaryEndpointId = primaryEndpointId
    let declaredPrimaryCandidates = enabledEndpoints.filter { endpoint in
      runtimesByEndpointId[endpoint.id]?.sessionStore.serverIsPrimary == true
    }

    hasPrimaryEndpointConflict = declaredPrimaryCandidates.count > 1
    primaryEndpointId = ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: configuredEndpoints)

    if previousPrimaryEndpointId != primaryEndpointId {
      primaryEndpointContinuation.yield(primaryEndpointId)
    }
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
    connectionStatusByEndpointId[endpointId] = runtime.eventStream.connectionStatus
    readinessByEndpointId[endpointId] = runtime.readiness

    // Cancel any existing observation for this endpoint
    runtimeObservationTasks[endpointId]?.cancel()

    // Observe connection status changes from the EventStream
    runtime.eventStream.addListener { [weak self, weak runtime] event in
      guard let self, let runtime else { return }
      if case let .connectionStatusChanged(status) = event {
        self.connectionStatusByEndpointId[endpointId] = status
        self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
          connectionStatus: status,
          hasReceivedInitialRootList: runtime.eventStream.hasReceivedInitialSessionsList
        )
      }
      // Track when we receive the initial session list
      if case .sessionsList = event {
        self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
          connectionStatus: runtime.eventStream.connectionStatus,
          hasReceivedInitialRootList: true
        )
      }
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
