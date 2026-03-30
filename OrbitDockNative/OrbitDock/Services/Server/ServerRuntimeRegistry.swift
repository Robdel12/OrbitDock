import Foundation

#if canImport(UIKit)
  import UIKit
#endif

private actor RegistryAggregationWorker {
  func sortedSessions(
    from sessionsByEndpoint: [UUID: [String: RootSessionNode]]
  ) -> [RootSessionNode] {
    let all = sessionsByEndpoint.values.flatMap(\.values)
    return all.sorted { lhs, rhs in
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }

  func sortedDashboardConversations(
    from dashboardConversationsByEndpoint: [UUID: [String: DashboardConversationRecord]]
  ) -> [DashboardConversationRecord] {
    let all = dashboardConversationsByEndpoint.values.flatMap(\.values)
    return all.sorted { lhs, rhs in
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      if lhs.displayStatus != rhs.displayStatus {
        return ServerRuntimeRegistry.dashboardConversationPriority(lhs.displayStatus)
          < ServerRuntimeRegistry.dashboardConversationPriority(rhs.displayStatus)
      }
      return lhsDate > rhsDate
    }
  }

  func sortedMissions(
    from missionsByEndpoint: [UUID: [String: AggregatedMissionSummary]]
  ) -> [AggregatedMissionSummary] {
    let all = missionsByEndpoint.values.flatMap(\.values)
    return all.sorted { lhs, rhs in
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }
  }

  func dashboardProjection(
    rootSessions: [RootSessionNode],
    dashboardConversations: [DashboardConversationRecord],
    refreshIdentity: String
  ) -> DashboardProjectionSnapshot {
    DashboardProjectionBuilder.build(
      rootSessions: rootSessions,
      dashboardConversations: dashboardConversations,
      refreshIdentity: refreshIdentity
    )
  }
}

@Observable
@MainActor
final class ServerRuntimeRegistry {
  private enum BootstrapRefreshDecision: Equatable {
    case success
    case retry
    case stop
  }

  private let endpointSettings: ServerEndpointSettingsClient
  private let endpointsProvider: () -> [ServerEndpoint]
  private let runtimeFactory: (ServerEndpoint) -> ServerRuntime
  private let clientIdentityProvider: () -> ServerClientIdentity
  private let shouldBootstrapFromSettings: Bool
  private let bootstrapRetryDelay: @Sendable (Int) -> Duration
  private let controlPlaneCoordinator = ServerControlPlaneCoordinator()
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private(set) var connectionStatusByEndpointId: [UUID: ConnectionStatus] = [:]
  private(set) var readinessByEndpointId: [UUID: ServerRuntimeReadiness] = [:]
  private(set) var activeEndpointId: UUID?
  private(set) var primaryEndpointId: UUID?
  private(set) var hasPrimaryEndpointConflict = false
  private(set) var hasConfiguredEndpoints = false
  let dashboardProjectionStore = DashboardProjectionStore()
  let missionProjectionStore = MissionProjectionStore()
  let readinessUpdates: AsyncStream<Void>
  @ObservationIgnored private let readinessContinuation: AsyncStream<Void>.Continuation

  // MARK: - Session list aggregation (across all endpoints)

  @ObservationIgnored private var sessionsByEndpoint: [UUID: [String: RootSessionNode]] = [:]
  @ObservationIgnored private var dashboardConversationsByEndpoint: [UUID: [String: DashboardConversationRecord]] = [:]
  @ObservationIgnored private var missionsByEndpoint: [UUID: [String: AggregatedMissionSummary]] = [:]
  private(set) var aggregatedSessions: [RootSessionNode] = []
  private(set) var aggregatedDashboardConversations: [DashboardConversationRecord] = []
  private(set) var aggregatedMissions: [AggregatedMissionSummary] = []

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
  @ObservationIgnored private var bootstrapRetryTasksByEndpointId: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var bootstrapRetryAttemptsByEndpointId: [UUID: Int] = [:]
  @ObservationIgnored private var suspendedForBackground = false
  @ObservationIgnored private let aggregationWorker = RegistryAggregationWorker()
  @ObservationIgnored private var aggregationRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var sessionsAggregationDirty = false
  @ObservationIgnored private var dashboardAggregationDirty = false
  @ObservationIgnored private var missionsAggregationDirty = false
  @ObservationIgnored private var dashboardProjectionRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var sessionsAggregationGeneration: UInt64 = 0
  @ObservationIgnored private var dashboardAggregationGeneration: UInt64 = 0
  @ObservationIgnored private var missionsAggregationGeneration: UInt64 = 0

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
    bootstrapRetryDelay = { attempt in
      ServerRuntimeRegistry.defaultBootstrapRetryDelay(attempt)
    }
    dashboardProjectionStore.runtimeRegistry = self
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    endpointSettings: ServerEndpointSettingsClient? = nil,
    shouldBootstrapFromSettings: Bool = true,
    bootstrapRetryDelay: @escaping @Sendable (Int) -> Duration = { attempt in
      ServerRuntimeRegistry.defaultBootstrapRetryDelay(attempt)
    }
  ) {
    var readinessContinuation: AsyncStream<Void>.Continuation!
    readinessUpdates = AsyncStream { readinessContinuation = $0 }
    self.readinessContinuation = readinessContinuation
    self.endpointSettings = endpointSettings ?? .live()
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = { Self.currentIdentity() }
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
    self.bootstrapRetryDelay = bootstrapRetryDelay
    dashboardProjectionStore.runtimeRegistry = self
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime,
    clientIdentityProvider: @escaping () -> ServerClientIdentity,
    endpointSettings: ServerEndpointSettingsClient? = nil,
    shouldBootstrapFromSettings: Bool = true,
    bootstrapRetryDelay: @escaping @Sendable (Int) -> Duration = { attempt in
      ServerRuntimeRegistry.defaultBootstrapRetryDelay(attempt)
    }
  ) {
    var readinessContinuation: AsyncStream<Void>.Continuation!
    readinessUpdates = AsyncStream { readinessContinuation = $0 }
    self.readinessContinuation = readinessContinuation
    self.endpointSettings = endpointSettings ?? .live()
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
    self.clientIdentityProvider = clientIdentityProvider
    self.shouldBootstrapFromSettings = shouldBootstrapFromSettings
    self.bootstrapRetryDelay = bootstrapRetryDelay
    dashboardProjectionStore.runtimeRegistry = self
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

  func injectDemoConnectionStatus(for endpointId: UUID) {
    connectionStatusByEndpointId[endpointId] = .connected
    readinessByEndpointId[endpointId] = ServerRuntimeReadiness(
      transportReady: true,
      controlPlaneReady: true,
      queryReady: true
    )
  }

  func clearDemoConnectionStatus(for endpointId: UUID) {
    connectionStatusByEndpointId[endpointId] = nil
    readinessByEndpointId[endpointId] = nil
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
      cancelBootstrapRetry(for: id)
      sessionsByEndpoint[id] = nil
      dashboardConversationsByEndpoint[id] = nil
      missionsByEndpoint[id] = nil
      readinessContinuation.yield(())
    }
    setSessionsAggregationDirty()
    setDashboardAggregationDirty()
    setMissionsAggregationDirty()

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
          dashboardConversationsByEndpoint[endpoint.id] = nil
          missionsByEndpoint[endpoint.id] = nil

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
    setSessionsAggregationDirty()
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
      if runtime.readiness.transportReady, !runtime.readiness.queryReady {
        scheduleSurfaceBootstrap(for: runtime, resetAttempts: false)
      } else {
        runtime.reconnectIfNeeded()
      }
    }
  }

  @discardableResult
  func refreshEnabledSessionLists() -> [UUID] {
    runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtime in
        if runtime.isStarted {
          if runtime.readiness.transportReady, !runtime.readiness.queryReady {
            scheduleSurfaceBootstrap(for: runtime, resetAttempts: false)
          } else {
            runtime.reconnectIfNeeded()
          }
        }
        return runtime.endpoint.id
      }
  }

  func refreshAll() async {
    for runtime in runtimes where runtime.endpoint.isEnabled && runtime.isStarted {
      if runtime.readiness.transportReady, !runtime.readiness.queryReady {
        scheduleSurfaceBootstrap(for: runtime, resetAttempts: false)
      } else {
        runtime.reconnectIfNeeded()
      }
    }
  }

  func refreshDashboardConversations() async {
    ensureInitialized()

    for runtime in runtimes where runtime.endpoint.isEnabled && runtime.readiness.queryReady {
      _ = await refreshDashboardConversations(for: runtime)
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
        case .hello:
          break

        case let .connectionStatusChanged(status):
          self.connectionStatusByEndpointId[endpointId] = status
          self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
            connectionStatus: status,
            hasReceivedInitialRootList: runtime.connection.hasReceivedInitialDashboardSnapshot
          )
          if status == .connected, !runtime.connection.hasReceivedInitialDashboardSnapshot {
            self.scheduleSurfaceBootstrap(for: runtime, resetAttempts: true)
          } else if status != .connected {
            self.cancelBootstrapRetry(for: endpointId)
            self.bootstrapRetryAttemptsByEndpointId[endpointId] = nil
          } else if runtime.connection.hasReceivedInitialDashboardSnapshot {
            self.cancelBootstrapRetry(for: endpointId)
            self.scheduleDashboardProjectionRefresh()
          }

        case let .dashboardSnapshot(snapshot):
          self.bootstrapRetryAttemptsByEndpointId[endpointId] = nil
          self.readinessByEndpointId[endpointId] = ServerRuntimeReadiness.derive(
            connectionStatus: runtime.connection.connectionStatus,
            hasReceivedInitialRootList: true
          )
          var index: [String: RootSessionNode] = [:]
          for item in snapshot.sessions {
            let node = RootSessionNode(
              session: item, endpointId: endpointId, endpointName: endpointName,
              connectionStatus: .connected
            )
            index[node.scopedID] = node
          }
          self.sessionsByEndpoint[endpointId] = index
          self.setSessionsAggregationDirty()
          var conversationsIndex: [String: DashboardConversationRecord] = [:]
          for item in snapshot.conversations {
            let record = DashboardConversationRecord(item: item, endpointId: endpointId, endpointName: endpointName)
            conversationsIndex[record.id] = record
          }
          self.dashboardConversationsByEndpoint[endpointId] = conversationsIndex
          self.setDashboardAggregationDirty()

        case .dashboardInvalidated:
          Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            _ = await self.refreshDashboardConversations(for: runtime)
          }

        case let .missionsSnapshot(snapshot):
          let endpointName = runtime.endpoint.name
          var index: [String: AggregatedMissionSummary] = [:]
          for mission in snapshot.missions {
            let agg = AggregatedMissionSummary(mission: mission, endpointId: endpointId, endpointName: endpointName)
            index[agg.id] = agg
          }
          self.missionsByEndpoint[endpointId] = index
          self.setMissionsAggregationDirty()

        case .missionsInvalidated:
          Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            _ = await self.refreshMissions(for: runtime)
          }

        case let .error(code, _, sessionId):
          guard sessionId == nil else { break }
          switch code {
            case "dashboard_resync_required", "lagged", "replay_oversized":
              Task { [weak self, weak runtime] in
                guard let self, let runtime else { return }
                _ = await self.refreshDashboardConversations(for: runtime)
              }
            case "missions_resync_required":
              Task { [weak self, weak runtime] in
                guard let self, let runtime else { return }
                _ = await self.refreshMissions(for: runtime)
              }
            default:
              break
          }

        case let .sessionEnded(sessionId, reason):
          let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
          if let existing = self.sessionsByEndpoint[endpointId]?[scopedID] {
            self.sessionsByEndpoint[endpointId]?[scopedID] = existing.ended(reason: reason)
            self.setSessionsAggregationDirty()
          }
          self.dashboardConversationsByEndpoint[endpointId]?[scopedID] = nil
          self.setDashboardAggregationDirty()

        case let .missionsList(missions):
          let endpointName = runtime.endpoint.name
          var index: [String: AggregatedMissionSummary] = [:]
          for mission in missions {
            let agg = AggregatedMissionSummary(mission: mission, endpointId: endpointId, endpointName: endpointName)
            index[agg.id] = agg
          }
          self.missionsByEndpoint[endpointId] = index
          self.setMissionsAggregationDirty()

        case let .missionDelta(_, _, summary):
          let endpointName = runtime.endpoint.name
          let agg = AggregatedMissionSummary(mission: summary, endpointId: endpointId, endpointName: endpointName)
          self.missionsByEndpoint[endpointId, default: [:]][agg.id] = agg
          self.setMissionsAggregationDirty()

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
    cancelBootstrapRetry(for: endpointId)
    bootstrapRetryAttemptsByEndpointId[endpointId] = nil
  }

  private func setSessionsAggregationDirty() {
    sessionsAggregationDirty = true
    scheduleAggregationRefresh()
  }

  private func setDashboardAggregationDirty() {
    dashboardAggregationDirty = true
    scheduleAggregationRefresh()
  }

  private func setMissionsAggregationDirty() {
    missionsAggregationDirty = true
    scheduleAggregationRefresh()
  }

  private func scheduleAggregationRefresh() {
    guard aggregationRefreshTask == nil else { return }
    aggregationRefreshTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.aggregationRefreshTask = nil

      if self.sessionsAggregationDirty {
        self.sessionsAggregationDirty = false
        self.sessionsAggregationGeneration &+= 1
        let generation = self.sessionsAggregationGeneration
        let sessionsByEndpoint = self.sessionsByEndpoint
        Task { [weak self] in
          guard let self else { return }
          let aggregated = await self.aggregationWorker.sortedSessions(from: sessionsByEndpoint)
          guard generation == self.sessionsAggregationGeneration else { return }
          self.aggregatedSessions = aggregated
          self.scheduleDashboardProjectionRefresh()
        }
      }
      if self.dashboardAggregationDirty {
        self.dashboardAggregationDirty = false
        self.dashboardAggregationGeneration &+= 1
        let generation = self.dashboardAggregationGeneration
        let dashboardConversationsByEndpoint = self.dashboardConversationsByEndpoint
        Task { [weak self] in
          guard let self else { return }
          let aggregated = await self.aggregationWorker
            .sortedDashboardConversations(from: dashboardConversationsByEndpoint)
          guard generation == self.dashboardAggregationGeneration else { return }
          self.aggregatedDashboardConversations = aggregated
          self.scheduleDashboardProjectionRefresh()
        }
      }
      if self.missionsAggregationDirty {
        self.missionsAggregationDirty = false
        self.missionsAggregationGeneration &+= 1
        let generation = self.missionsAggregationGeneration
        let missionsByEndpoint = self.missionsByEndpoint
        Task { [weak self] in
          guard let self else { return }
          let aggregated = await self.aggregationWorker.sortedMissions(from: missionsByEndpoint)
          guard generation == self.missionsAggregationGeneration else { return }
          self.aggregatedMissions = aggregated
          self.missionProjectionStore.apply(MissionProjectionSnapshot(missions: aggregated))
        }
      }
    }
  }

  private func scheduleDashboardProjectionRefresh() {
    guard dashboardProjectionRefreshTask == nil else { return }
    dashboardProjectionRefreshTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.dashboardProjectionRefreshTask = nil

      let rootSessions = self.aggregatedSessions
      let dashboardConversations = self.aggregatedDashboardConversations
      let refreshIdentity = Self.makeDashboardRefreshIdentity(
        runtimes: self.runtimes.filter(\.endpoint.isEnabled).map { runtime in
          (runtime.endpoint.id, self.connectionStatusByEndpointId[runtime.endpoint.id] ?? .disconnected)
        }
      )

      let snapshot = await self.aggregationWorker.dashboardProjection(
        rootSessions: rootSessions,
        dashboardConversations: dashboardConversations,
        refreshIdentity: refreshIdentity
      )

      self.dashboardProjectionStore.apply(snapshot)
    }
  }

  private static func makeDashboardRefreshIdentity(
    runtimes: [(endpointId: UUID, status: ConnectionStatus)]
  ) -> String {
    runtimes
      .map { "\($0.endpointId.uuidString):\(dashboardConnectionToken(for: $0.status))" }
      .joined(separator: "|")
  }

  fileprivate nonisolated static func dashboardConversationPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
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

  private func refreshDashboardConversations(for runtime: ServerRuntime) async -> BootstrapRefreshDecision {
    guard runtime.endpoint.isEnabled else { return .stop }
    guard runtime.connection.connectionStatus == .connected else { return .stop }

    do {
      let snapshot = try await runtime.clients.dashboard.fetchDashboardSnapshot()
      runtime.connection.applyDashboardSnapshot(snapshot)
      runtime.connection.subscribeDashboard(sinceRevision: snapshot.revision)
      return .success
    } catch {
      if let message = ServerContractGuard.compatibilityMessage(
        for: error,
        surface: "dashboard bootstrap"
      ) {
        runtime.connection.failCompatibility(message: message)
        return .stop
      }
      netLog(
        .error,
        cat: .api,
        "Dashboard snapshot bootstrap failed",
        data: [
          "endpointId": runtime.endpoint.id.uuidString,
          "endpointName": runtime.endpoint.name,
          "error": String(describing: error),
        ]
      )
      return shouldRetryBootstrap(after: error) ? .retry : .stop
    }
  }

  private func refreshMissions(for runtime: ServerRuntime) async -> BootstrapRefreshDecision {
    guard runtime.endpoint.isEnabled else { return .stop }
    guard runtime.connection.connectionStatus == .connected else { return .stop }

    do {
      let snapshot = try await runtime.clients.missions.fetchMissionSnapshot()
      runtime.connection.applyMissionsSnapshot(snapshot)
      runtime.connection.subscribeMissions(sinceRevision: snapshot.revision)
      return .success
    } catch {
      if let message = ServerContractGuard.compatibilityMessage(
        for: error,
        surface: "missions bootstrap"
      ) {
        runtime.connection.failCompatibility(message: message)
        return .stop
      }
      netLog(
        .error,
        cat: .api,
        "Missions snapshot bootstrap failed",
        data: [
          "endpointId": runtime.endpoint.id.uuidString,
          "endpointName": runtime.endpoint.name,
          "error": String(describing: error),
        ]
      )
      return shouldRetryBootstrap(after: error) ? .retry : .stop
    }
  }

  private func scheduleSurfaceBootstrap(for runtime: ServerRuntime, resetAttempts: Bool) {
    let endpointId = runtime.endpoint.id
    if resetAttempts {
      cancelBootstrapRetry(for: endpointId)
      bootstrapRetryAttemptsByEndpointId[endpointId] = 0
    } else if bootstrapRetryTasksByEndpointId[endpointId] != nil {
      return
    }

    bootstrapRetryTasksByEndpointId[endpointId] = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      let endpointId = runtime.endpoint.id
      let attempt = self.bootstrapRetryAttemptsByEndpointId[endpointId] ?? 0
      if attempt > 0 {
        try? await Task.sleep(for: self.bootstrapRetryDelay(attempt))
      }

      guard !Task.isCancelled else { return }
      guard runtime.endpoint.isEnabled, runtime.connection.connectionStatus == .connected else {
        self.bootstrapRetryTasksByEndpointId[endpointId] = nil
        return
      }

      let dashboardDecision = await self.refreshDashboardConversations(for: runtime)
      let missionsDecision = await self.refreshMissions(for: runtime)
      self.bootstrapRetryTasksByEndpointId[endpointId] = nil

      let shouldRetry = runtime.connection.connectionStatus == .connected
        && (!runtime.connection.hasReceivedInitialDashboardSnapshot || missionsDecision == .retry)
        && (dashboardDecision == .retry || missionsDecision == .retry)

      guard shouldRetry else {
        self.bootstrapRetryAttemptsByEndpointId[endpointId] = nil
        return
      }

      self.bootstrapRetryAttemptsByEndpointId[endpointId] = attempt + 1
      self.scheduleSurfaceBootstrap(for: runtime, resetAttempts: false)
    }
  }

  private func cancelBootstrapRetry(for endpointId: UUID) {
    bootstrapRetryTasksByEndpointId[endpointId]?.cancel()
    bootstrapRetryTasksByEndpointId[endpointId] = nil
  }

  private nonisolated static func defaultBootstrapRetryDelay(_ attempt: Int) -> Duration {
    let seconds = min(max(attempt, 1), 5)
    return .seconds(seconds)
  }

  private func shouldRetryBootstrap(after error: Error) -> Bool {
    switch error {
      case is HTTPTransportError:
        true
      case let serverError as ServerRequestError:
        switch serverError {
          case .transport:
            true
          case let .httpStatus(status, _, _):
            status >= 500
          case .incompatibleServer:
            false
          default:
            false
        }
      default:
        false
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
