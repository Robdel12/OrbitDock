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
      dashboardConversationsByEndpoint[id] = nil
      missionsByEndpoint[id] = nil
      readinessContinuation.yield(())
    }
    recomputeAggregatedSessions()
    recomputeAggregatedDashboardConversations()
    recomputeAggregatedMissions()

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

  func refreshDashboardConversations() async {
    ensureInitialized()

    for runtime in runtimes where runtime.endpoint.isEnabled && runtime.readiness.queryReady {
      await refreshDashboardConversations(for: runtime)
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

    return runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtime in
        "\(runtime.endpoint.id.uuidString):\(dashboardConnectionToken(for: runtime.connection.connectionStatus))"
      }
      .joined(separator: "|")
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
          if status == .connected {
            Task { [weak self, weak runtime] in
              guard let self, let runtime else { return }
              await self.refreshDashboardConversations(for: runtime)
            }
          }

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

        case let .dashboardConversationsUpdated(items):
          var index: [String: DashboardConversationRecord] = [:]
          for item in items {
            let record = DashboardConversationRecord(item: item, endpointId: endpointId, endpointName: endpointName)
            index[record.id] = record
          }
          self.dashboardConversationsByEndpoint[endpointId] = index
          self.recomputeAggregatedDashboardConversations()

        case let .sessionCreated(item), let .sessionListItemUpdated(item):
          let node = RootSessionNode(
            session: item, endpointId: endpointId, endpointName: endpointName,
            connectionStatus: .connected
          )
          self.sessionsByEndpoint[endpointId, default: [:]][node.scopedID] = node
          self.recomputeAggregatedSessions()

          // SessionHandle.broadcast() bypasses SessionRegistry.broadcast_to_list(),
          // so DashboardConversationsUpdated is NOT sent for in-session status
          // transitions (e.g. working → reply). Patch the dashboard record inline.
          let scopedID = node.scopedID
          if let existing = self.dashboardConversationsByEndpoint[endpointId]?[scopedID] {
            self.dashboardConversationsByEndpoint[endpointId]?[scopedID] =
              existing.applyingListItemUpdate(item, endpointName: endpointName)
            self.recomputeAggregatedDashboardConversations()
          }

        case let .sessionListItemRemoved(sessionId):
          let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
          self.sessionsByEndpoint[endpointId]?[scopedID] = nil
          self.dashboardConversationsByEndpoint[endpointId]?[scopedID] = nil
          self.recomputeAggregatedSessions()
          self.recomputeAggregatedDashboardConversations()

        case let .sessionEnded(sessionId, reason):
          let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
          if let existing = self.sessionsByEndpoint[endpointId]?[scopedID] {
            self.sessionsByEndpoint[endpointId]?[scopedID] = existing.ended(reason: reason)
            self.recomputeAggregatedSessions()
          }

        case let .missionsList(missions):
          let endpointName = runtime.endpoint.name
          var index: [String: AggregatedMissionSummary] = [:]
          for mission in missions {
            let agg = AggregatedMissionSummary(mission: mission, endpointId: endpointId, endpointName: endpointName)
            index[agg.id] = agg
          }
          self.missionsByEndpoint[endpointId] = index
          self.recomputeAggregatedMissions()

        case let .missionDelta(_, _, summary):
          let endpointName = runtime.endpoint.name
          let agg = AggregatedMissionSummary(mission: summary, endpointId: endpointId, endpointName: endpointName)
          self.missionsByEndpoint[endpointId, default: [:]][agg.id] = agg
          self.recomputeAggregatedMissions()

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

  private func recomputeAggregatedDashboardConversations() {
    let all = dashboardConversationsByEndpoint.values.flatMap(\.values)
    aggregatedDashboardConversations = all.sorted { lhs, rhs in
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      if lhs.displayStatus != rhs.displayStatus {
        return dashboardConversationPriority(lhs.displayStatus) < dashboardConversationPriority(rhs.displayStatus)
      }
      return lhsDate > rhsDate
    }
  }

  private func recomputeAggregatedMissions() {
    let all = missionsByEndpoint.values.flatMap(\.values)
    aggregatedMissions = all.sorted { lhs, rhs in
      // Active missions first, then by name
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }
  }

  private func dashboardConversationPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }

  private func dashboardConnectionToken(for status: ConnectionStatus) -> String {
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

  private func refreshDashboardConversations(for runtime: ServerRuntime) async {
    guard runtime.endpoint.isEnabled else { return }
    guard runtime.connection.connectionStatus == .connected else { return }

    do {
      let conversations = try await runtime.clients.dashboard.fetchConversations()
      runtime.connection.applyDashboardConversations(conversations)
    } catch {
      return
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
