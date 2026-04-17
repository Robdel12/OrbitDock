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
  private let serverRoleCoordinator = ServerRoleCoordinator()
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private(set) var connectionStatusByEndpointId: [UUID: ConnectionStatus] = [:]
  private(set) var readinessByEndpointId: [UUID: ServerRuntimeReadiness] = [:]
  private(set) var activeEndpointId: UUID?
  private(set) var primaryEndpointId: UUID?
  private(set) var hasPrimaryEndpointConflict = false
  private(set) var hasConfiguredEndpoints = false
  let readinessUpdates: AsyncStream<Void>
  @ObservationIgnored private let readinessContinuation: AsyncStream<Void>.Continuation

  @ObservationIgnored
  private lazy var fallbackEndpointStore: ServerEndpointRuntime = {
    let baseURL = URL(string: "http://127.0.0.1:3000")!
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: nil)
    let clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { _ in throw HTTPTransportError.serverUnreachable }
    )
    return ServerEndpointRuntime(
      clients: clients,
      connection: ServerConnection(authToken: nil),
      endpointId: UUID()
    )
  }()

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

  var hasMultipleEndpoints: Bool {
    runtimesByEndpointId.count > 1
  }

  var connectedRuntimes: [ServerRuntime] {
    runtimes.filter { runtime in
      connectionStatusByEndpointId[runtime.endpoint.id] == .connected
    }
  }

  var activeEndpointStore: ServerEndpointRuntime {
    ensureInitialized()
    if let runtime = resolvedActiveRuntime() {
      return runtime.endpointStore
    }
    return fallbackEndpointStore
  }

  var serverPrimaryByEndpointId: [UUID: Bool] {
    var result: [UUID: Bool] = [:]
    for (id, runtime) in runtimesByEndpointId {
      if let isPrimary = runtime.endpointStore.serverIsPrimary {
        result[id] = isPrimary
      }
    }
    return result
  }

  var serverPrimaryClaimsByEndpointId: [UUID: [ServerClientPrimaryClaim]] {
    var result: [UUID: [ServerClientPrimaryClaim]] = [:]
    for (id, runtime) in runtimesByEndpointId {
      let claims = runtime.endpointStore.serverPrimaryClaims
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

  var hasAnyServerRoleReadyRuntime: Bool {
    readinessByEndpointId.values.contains(where: \.serverRoleReady)
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

  func injectDemoConnectionStatus(for endpointId: UUID) {
    connectionStatusByEndpointId[endpointId] = .connected
    readinessByEndpointId[endpointId] = ServerRuntimeReadiness(
      transportReady: true,
      serverRoleReady: true
    )
  }

  func clearDemoConnectionStatus(for endpointId: UUID) {
    connectionStatusByEndpointId[endpointId] = nil
    readinessByEndpointId[endpointId] = nil
  }

  func waitForAnyServerRoleReadyRuntime() async {
    guard hasEnabledRuntimes, !hasAnyServerRoleReadyRuntime else { return }
    let updates = readinessUpdates
    for await _ in updates {
      if hasAnyServerRoleReadyRuntime || !hasEnabledRuntimes {
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
      connectionStatusByEndpointId[id] = nil
      readinessByEndpointId[id] = nil
      readinessContinuation.yield(())
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          unbindRuntimeState(existing)
          existing.stop()

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
      guard let runtime = runtimesByEndpointId[endpoint.id] else { continue }
      runtime.start()
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
    let ports = enabledServerRolePorts()
    Task {
      await serverRoleCoordinator.applyServerRoleChange(
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

  func waitForServerRoleCoordinatorIdleForTests() async {
    await serverRoleCoordinator.waitUntilIdleForTests()
  }

  func endpointStore(for session: RootSessionNode) -> ServerEndpointRuntime {
    endpointStore(for: session.endpointId)
  }

  func endpointStoreIfAvailable(for endpointId: UUID) -> ServerEndpointRuntime? {
    ensureInitialized()
    return runtimesByEndpointId[endpointId]?.endpointStore
  }

  func endpointStore(for endpointId: UUID?) -> ServerEndpointRuntime {
    ensureInitialized()
    guard let endpointId else {
      return activeEndpointStore
    }
    guard let runtime = runtimesByEndpointId[endpointId] else {
      return fallbackEndpointStore
    }
    return runtime.endpointStore
  }

  func primaryEndpointStore() -> ServerEndpointRuntime {
    if let primaryRuntime {
      return primaryRuntime.endpointStore
    }
    return activeEndpointStore
  }

  func preferredCreationEndpointStore(preferredEndpointId: UUID?) -> ServerEndpointRuntime {
    if let preferredEndpointId {
      return endpointStore(for: preferredEndpointId)
    }
    return primaryEndpointStore()
  }

  var dashboardRefreshIdentity: String {
    ensureInitialized()
    return Self.makeDashboardRefreshIdentity(
      runtimes: runtimes.filter(\.endpoint.isEnabled).map { ($0.endpoint.id, $0.connection.connectionStatus) }
    )
  }

  static func preferredActiveEndpointID(from endpoints: [ServerEndpoint]) -> UUID? {
    ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: endpoints)
  }

  // MARK: - Private

  private func ensureInitialized() {
    if shouldBootstrapFromSettings, runtimesByEndpointId.isEmpty {
      configureFromSettings(startEnabled: false)
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
    let declaredPrimaryCandidates = enabledEndpoints.filter { endpoint in
      runtimesByEndpointId[endpoint.id]?.endpointStore.serverIsPrimary == true
    }

    hasPrimaryEndpointConflict = declaredPrimaryCandidates.count > 1
    primaryEndpointId = ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: configuredEndpoints)
  }

  private func schedulePrimaryClaimReconciliation() {
    let identity = clientIdentityProvider()
    let ports = serverRoleReadyPorts()
    let plan = ServerRolePlan(
      enabledEndpointIds: ports.map(\.endpointId),
      primaryEndpointId: primaryEndpointId
    )
    Task {
      await serverRoleCoordinator.submitPrimaryClaimPlan(
        plan,
        ports: ports,
        clientIdentity: identity
      )
    }
  }

  private func bindRuntimeState(_ runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    connectionStatusByEndpointId[endpointId] = runtime.connection.connectionStatus
    readinessByEndpointId[endpointId] = runtime.readiness
    runtime.onServerMetaRefreshed = { [weak self, weak runtime] meta in
      guard let self, let runtime else { return }
      if let serverInstanceId = meta.serverInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines),
         !serverInstanceId.isEmpty
      {
        self.endpointSettings.recordServerIdentity(runtime.endpoint.id, serverInstanceId)
      }
      runtime.endpointStore.serverIsPrimary = meta.isPrimary
      runtime.endpointStore.serverPrimaryClaims = meta.clientPrimaryClaims
      self.configureFromSettings(startEnabled: true)
    }

    // Cancel any existing observation for this endpoint
    if let token = connectionListenerTokensByEndpointId.removeValue(forKey: endpointId) {
      runtime.connection.removeListener(token)
    }

    // Observe connection status + session list changes from the ServerConnection
    connectionListenerTokensByEndpointId[endpointId] = runtime.connection.addListener { [weak self] event in
      guard let self else { return }
      switch event {
        case .hello:
          break

        case let .connectionStatusChanged(status):
          self.connectionStatusByEndpointId[endpointId] = status
          self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
            connectionStatus: status
          )

        default:
          break
      }
    }
  }

  private func unbindRuntimeState(_ runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    runtime.onServerMetaRefreshed = nil
    if let token = connectionListenerTokensByEndpointId.removeValue(forKey: endpointId) {
      runtime.connection.removeListener(token)
    }
  }

  private static func makeDashboardRefreshIdentity(
    runtimes: [(endpointId: UUID, status: ConnectionStatus)]
  ) -> String {
    runtimes
      .map { "\($0.endpointId.uuidString):\(dashboardConnectionToken(for: $0.status))" }
      .joined(separator: "|")
  }

  fileprivate nonisolated static func dashboardConnectionToken(for status: ConnectionStatus) -> String {
    switch status {
      case .disconnected:
        "disconnected"
      case .connecting:
        "connecting"
      case .connected:
        "connected"
      case let .failed(message):
        "failed:\(message)"
    }
  }

  private func enabledServerRolePorts() -> [ServerRolePort] {
    ServerRuntimeRegistryPlanner.serverRolePorts(
      runtimes: Array(runtimesByEndpointId.values),
      readinessByEndpointId: readinessByEndpointId,
      requireServerRoleReady: false
    )
  }

  private func serverRoleReadyPorts() -> [ServerRolePort] {
    ServerRuntimeRegistryPlanner.serverRolePorts(
      runtimes: Array(runtimesByEndpointId.values),
      readinessByEndpointId: readinessByEndpointId,
      requireServerRoleReady: true
    )
  }
}
