import Foundation
import Observation

@Observable
@MainActor
final class DashboardDataService {
  private struct ListenerBinding {
    let connection: ServerConnection
    let token: ServerConnectionListenerToken
  }

  // MARK: - Observable state (consumers read these)

  private(set) var snapshot: DashboardSnapshot?
  private(set) var librarySessions: [RootSessionNode] = []

  // MARK: - Private

  @ObservationIgnored private var listenerBindingsByEndpointId: [UUID: ListenerBinding] = [:]
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private var dashboardRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var dashboardRefreshGeneration: UInt64 = 0
  @ObservationIgnored private var runtimeTopologyTask: Task<Void, Never>?

  // MARK: - Lifecycle

  func start(runtimeRegistry: ServerRuntimeRegistry) {
    guard self.runtimeRegistry == nil else { return }
    self.runtimeRegistry = runtimeRegistry
    reconcileListeners(runtimeRegistry: runtimeRegistry)
    observeRuntimeTopology(runtimeRegistry: runtimeRegistry)
    scheduleDashboardRefresh()
    scheduleLibraryRefresh()
  }

  func stop() {
    runtimeTopologyTask?.cancel()
    runtimeTopologyTask = nil
    for binding in listenerBindingsByEndpointId.values {
      binding.connection.removeListener(binding.token)
    }
    listenerBindingsByEndpointId.removeAll()
    dashboardRefreshTask?.cancel()
    dashboardRefreshTask = nil
    libraryRefreshTask?.cancel()
    libraryRefreshTask = nil
    runtimeRegistry = nil
  }

  func refreshNow() async {
    scheduleDashboardRefresh()
    scheduleLibraryRefresh()
    let dashboardTask = dashboardRefreshTask
    let libraryTask = libraryRefreshTask
    if let dashboardTask {
      await dashboardTask.value
    }
    if let libraryTask {
      await libraryTask.value
    }
  }

  // MARK: - Listeners

  private func observeRuntimeTopology(runtimeRegistry: ServerRuntimeRegistry) {
    runtimeTopologyTask?.cancel()
    runtimeTopologyTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let updates = runtimeRegistry.readinessUpdates
      for await _ in updates {
        guard !Task.isCancelled else { return }
        guard let runtimeRegistry = self.runtimeRegistry else { return }
        self.reconcileListeners(runtimeRegistry: runtimeRegistry)
      }
    }
  }

  private func reconcileListeners(runtimeRegistry: ServerRuntimeRegistry) {
    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let activeConnectionsByEndpointId = Dictionary(
      uniqueKeysWithValues: enabledRuntimes.map { ($0.endpoint.id, $0.connection) }
    )
    var topologyChanged = false

    for (endpointId, binding) in Array(listenerBindingsByEndpointId) {
      guard let activeConnection = activeConnectionsByEndpointId[endpointId],
            activeConnection === binding.connection
      else {
        binding.connection.removeListener(binding.token)
        listenerBindingsByEndpointId.removeValue(forKey: endpointId)
        topologyChanged = true
        continue
      }
    }

    for runtime in enabledRuntimes {
      let endpointId = runtime.endpoint.id
      let connection = runtime.connection
      guard listenerBindingsByEndpointId[endpointId] == nil else { continue }

      if connection.connectionStatus == .connected {
        connection.subscribeDashboard()
      }

      let token = makeListener(connection: connection, endpointId: endpointId, endpointName: runtime.endpoint.name)
      listenerBindingsByEndpointId[endpointId] = ListenerBinding(connection: connection, token: token)
      topologyChanged = true
    }

    if topologyChanged {
      scheduleDashboardRefresh()
      scheduleLibraryRefresh()
    }
  }

  private func makeListener(
    connection: ServerConnection,
    endpointId: UUID,
    endpointName: String?
  ) -> ServerConnectionListenerToken {
    connection.addListener { [weak self] event in
      guard let self else { return }
      switch event {
      case let .dashboardConversationUpdated(revision, item):
        self.applyConversationUpdate(item, revision: revision, endpointId: endpointId, endpointName: endpointName)

      case let .dashboardItemRemoved(sessionId):
        self.removeConversation(sessionId: sessionId, endpointId: endpointId)

      case .dashboardInvalidated:
        self.scheduleDashboardRefresh()

      case .connectionStatusChanged(.connected):
        connection.subscribeDashboard()
        self.scheduleDashboardRefresh()
        self.scheduleLibraryRefresh()

      case let .error(code, _, sessionId) where sessionId == nil:
        switch code {
        case "dashboard_resync_required", "lagged", "replay_oversized":
          self.scheduleDashboardRefresh()
        default:
          break
        }

      default:
        break
      }
    }
  }

  // MARK: - Incremental updates

  private func applyConversationUpdate(
    _ item: ServerDashboardConversationItem,
    revision: UInt64,
    endpointId: UUID,
    endpointName: String?
  ) {
    guard let current = snapshot else {
      // No snapshot yet — need a full fetch first
      scheduleDashboardRefresh()
      return
    }

    let updatedRecord = DashboardConversationRecord(
      item: item, endpointId: endpointId, endpointName: endpointName
    )

    var conversations = current.conversations
    if let index = conversations.firstIndex(where: {
      $0.sessionId == item.sessionId && $0.sessionRef.endpointId == endpointId
    }) {
      conversations[index] = updatedRecord
    } else {
      conversations.append(updatedRecord)
      scheduleLibraryRefresh()
    }

    conversations.sort { lhs, rhs in
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }

    snapshot = current.replacing(conversations: conversations, revision: max(revision, current.revision))
  }

  private func removeConversation(sessionId: String, endpointId: UUID) {
    guard let current = snapshot else { return }

    let before = current.conversations.count
    var conversations = current.conversations
    conversations.removeAll {
      $0.sessionId == sessionId && $0.sessionRef.endpointId == endpointId
    }

    snapshot = current.replacing(conversations: conversations)

    if conversations.count != before {
      scheduleLibraryRefresh()
    }
  }

  // MARK: - Full refresh (dashboard only)

  private func scheduleDashboardRefresh() {
    dashboardRefreshTask?.cancel()
    dashboardRefreshGeneration &+= 1
    let generation = dashboardRefreshGeneration
    dashboardRefreshTask = Task { await refreshDashboard(generation: generation) }
  }

  private func refreshDashboard(generation: UInt64) async {
    guard !Task.isCancelled, generation == dashboardRefreshGeneration, let runtimeRegistry else { return }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    guard !runtimes.isEmpty else {
      guard generation == dashboardRefreshGeneration else { return }
      snapshot = DashboardSnapshot(
        revision: 0,
        conversations: [],
        counts: DashboardTriageCounts(),
        directCount: 0,
        hasMultipleEndpoints: false,
        projectGroups: []
      )
      return
    }

    var endpointResults: [DashboardSnapshotMapper.EndpointResult] = []
    var failedEndpointIds: Set<UUID> = []
    var endpointIdentityByEndpointId: [UUID: String] = [:]
    var defaultEndpointById: [UUID: Bool] = [:]

    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      endpointIdentityByEndpointId[endpointId] = endpointIdentity(for: runtime)
      defaultEndpointById[endpointId] = runtime.endpoint.isDefault
    }

    for runtime in runtimes {
      do {
        let payload = try await runtime.clients.dashboard.fetchDashboardSnapshot()
        guard !Task.isCancelled, generation == dashboardRefreshGeneration else { return }

        let result = DashboardSnapshotMapper.mapEndpoint(
          payload,
          endpointId: runtime.endpoint.id,
          endpointName: runtime.endpoint.name,
          connectionStatus: runtime.connection.connectionStatus
        )
        endpointResults.append(result)
      } catch {
        failedEndpointIds.insert(runtime.endpoint.id)
        continue
      }
    }

    let successfulIdentities = Set(
      endpointResults.map { result in
        endpointIdentityByEndpointId[result.endpointId]
          ?? "endpoint:\(result.endpointId.uuidString.lowercased())"
      }
    )
    let failedEndpointIdsWithoutSuccessfulIdentity = failedEndpointIds.filter { endpointId in
      let identity = endpointIdentityByEndpointId[endpointId]
        ?? "endpoint:\(endpointId.uuidString.lowercased())"
      return !successfulIdentities.contains(identity)
    }

    // Preserve existing endpoint slices that failed this refresh.
    if let existing = snapshot, !failedEndpointIdsWithoutSuccessfulIdentity.isEmpty {
      endpointResults.append(
        contentsOf: preservedResults(for: Set(failedEndpointIdsWithoutSuccessfulIdentity), from: existing)
      )
    }

    let dedupedResults = dedupeEndpointResults(
      endpointResults,
      endpointIdentityByEndpointId: endpointIdentityByEndpointId,
      defaultEndpointById: defaultEndpointById
    )
    let merged = DashboardSnapshotMapper.merge(dedupedResults)
    guard generation == dashboardRefreshGeneration else { return }
    snapshot = merged
  }

  // MARK: - Library refresh (independent lifecycle)

  private func scheduleLibraryRefresh() {
    libraryRefreshTask?.cancel()
    libraryRefreshTask = Task { await refreshLibrary() }
  }

  private func refreshLibrary() async {
    guard !Task.isCancelled, let runtimeRegistry else { return }
    librarySessions = await RootSessionSnapshotLoader.fetchLibrarySessions(from: runtimeRegistry)
  }

  private func preservedResults(
    for failedEndpointIds: Set<UUID>,
    from existing: DashboardSnapshot
  ) -> [DashboardSnapshotMapper.EndpointResult] {
    failedEndpointIds.compactMap { endpointId in
      let conversations = existing.conversations.filter { $0.sessionRef.endpointId == endpointId }
      let projectGroups = existing.projectGroups.filter { $0.endpointId == endpointId }
      guard !conversations.isEmpty || !projectGroups.isEmpty else { return nil }

      return DashboardSnapshotMapper.EndpointResult(
        revision: existing.revision,
        conversations: conversations,
        counts: DashboardTriageCounts(conversations: conversations),
        directCount: conversations.filter(\.isDirect).count,
        endpointId: endpointId,
        projectGroups: projectGroups
      )
    }
  }

  private func endpointIdentity(for runtime: ServerRuntime) -> String {
    if let serverInstanceId = runtime.sessionStore.serverInstanceId?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !serverInstanceId.isEmpty
    {
      return "server:\(serverInstanceId)"
    }
    return Self.endpointIdentity(for: runtime.endpoint.wsURL)
  }

  private static func endpointIdentity(for wsURL: URL) -> String {
    guard let components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
      return "url:\(wsURL.absoluteString.lowercased())"
    }

    let scheme = (components.scheme ?? "ws").lowercased()
    let host = (components.host ?? "").lowercased()
    let port = components.port ?? (scheme == "wss" ? 443 : 80)
    var path = components.percentEncodedPath

    if path.isEmpty {
      path = "/ws"
    }

    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }

    let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    return "url:\(scheme)://\(host):\(port)\(path)\(query)"
  }

  private func dedupeEndpointResults(
    _ results: [DashboardSnapshotMapper.EndpointResult],
    endpointIdentityByEndpointId: [UUID: String],
    defaultEndpointById: [UUID: Bool]
  ) -> [DashboardSnapshotMapper.EndpointResult] {
    var keptByIdentity: [String: DashboardSnapshotMapper.EndpointResult] = [:]
    var identityOrder: [String] = []

    for result in results {
      let identity = endpointIdentityByEndpointId[result.endpointId]
        ?? "endpoint:\(result.endpointId.uuidString.lowercased())"

      guard let existing = keptByIdentity[identity] else {
        keptByIdentity[identity] = result
        identityOrder.append(identity)
        continue
      }

      let existingIsDefault = defaultEndpointById[existing.endpointId] == true
      let candidateIsDefault = defaultEndpointById[result.endpointId] == true
      if !existingIsDefault && candidateIsDefault {
        keptByIdentity[identity] = result
      }
    }

    return identityOrder.compactMap { keptByIdentity[$0] }
  }

  // MARK: - Demo mode

  func applyDemoSnapshot(_ snapshot: DashboardSnapshot) {
    self.snapshot = snapshot
  }

  func applyDemoSessions(_ sessions: [RootSessionNode]) {
    librarySessions = RootSessionSnapshotLoader.sortSessions(sessions)
  }
}
