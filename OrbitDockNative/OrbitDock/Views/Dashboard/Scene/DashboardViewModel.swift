import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
  var selectedIndex = 0
  var dashboardScrollAnchorID: String?
  var activeWorkbenchFilter: ActiveSessionWorkbenchFilter = .all {
    didSet { recomputeDerivedCollections() }
  }

  var activeSort: ActiveSessionSort = .recent {
    didSet { recomputeDerivedCollections() }
  }

  var activeProviderFilter: ActiveSessionProviderFilter = .all {
    didSet { recomputeDerivedCollections() }
  }

  var activeProjectFilter: String? {
    didSet { recomputeDerivedCollections() }
  }

  var rootSessions: [RootSessionNode] = []
  var filteredDashboardConversations: [DashboardConversationRecord] = []
  var sidebarConversations: [DashboardConversationRecord] = []
  var missionControlGroups: [ConversationProjectGroup] = []
  var sidebarGroups: [ConversationProjectGroup] = []

  /// Custom project ordering — persisted to UserDefaults.
  /// Empty array means "use alphabetical order."
  var projectOrder: [String] = {
    guard let data = UserDefaults.standard.data(forKey: "dashboard.projectOrder"),
          let paths = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return paths
  }() {
    didSet {
      if let data = try? JSONEncoder().encode(projectOrder) {
        UserDefaults.standard.set(data, forKey: "dashboard.projectOrder")
      }
      recomputeDerivedCollections()
    }
  }

  // MARK: - Backing state

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private var dashboardSessions: [RootSessionNode] = []
  @ObservationIgnored private var libraryExtras: [RootSessionNode] = []
  @ObservationIgnored private var dashboardConversationsStore: [DashboardConversationRecord] = []
  @ObservationIgnored private var dashboardCountsStore = DashboardTriageCounts(conversations: [])
  @ObservationIgnored private var dashboardDirectCountStore = 0
  @ObservationIgnored private var dashboardRefreshIdentityStore = "dashboard-unbound"
  @ObservationIgnored private var dashboardHasMultipleEndpointsStore = false
  @ObservationIgnored private var dashboardRevisionByEndpoint: [UUID: UInt64] = [:]

  // MARK: - Refresh + realtime

  @ObservationIgnored private var isRefreshingDashboard = false
  @ObservationIgnored private var dashboardRefreshQueued = false
  @ObservationIgnored private var realtimeListenersByEndpoint: [UUID: RealtimeSubscription] = [:]
  @ObservationIgnored private var realtimeRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var realtimeUpdatesEnabled = false

  // MARK: - Library pagination

  private struct LibraryPaginationState {
    var nextOffset: Int?
    var totalCount: Int?
  }

  @ObservationIgnored private var libraryPaginationByEndpoint: [UUID: LibraryPaginationState] = [:]
  @ObservationIgnored private var isLoadingLibrary = false

  // MARK: - Lifecycle

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    if self.runtimeRegistry !== runtimeRegistry {
      detachRealtimeListeners()
    }
    self.runtimeRegistry = runtimeRegistry
    libraryPaginationByEndpoint = runtimeRegistry.runtimes.reduce(into: [:]) { result, runtime in
      guard runtime.endpoint.isEnabled else { return }
      result[runtime.endpoint.id] = LibraryPaginationState(nextOffset: 0, totalCount: nil)
    }
    dashboardRefreshIdentityStore = Self.makeRefreshIdentity(for: runtimeRegistry.runtimes)
  }

  func setRealtimeUpdatesEnabled(_ enabled: Bool) {
    guard realtimeUpdatesEnabled != enabled else { return }
    realtimeUpdatesEnabled = enabled
    enabled ? attachRealtimeListeners() : detachRealtimeListeners()
  }

  func showingLoadingSkeleton(isInitialLoading: Bool) -> Bool {
    isInitialLoading && rootSessions.isEmpty
  }

  func refreshDashboardData() async {
    guard let runtimeRegistry else { return }
    if isRefreshingDashboard {
      dashboardRefreshQueued = true
      debugLogDashboard("refreshDashboard.skip_inflight", data: [:])
      return
    }

    isRefreshingDashboard = true
    debugLogDashboard("refreshDashboard.begin", data: [
      "enabledEndpoints": runtimeRegistry.runtimes.filter(\.endpoint.isEnabled).map { $0.endpoint.id.uuidString },
    ])
    defer {
      isRefreshingDashboard = false
      if dashboardRefreshQueued {
        dashboardRefreshQueued = false
        debugLogDashboard("refreshDashboard.requeued", data: [:])
        Task { await refreshDashboardData() }
      } else {
        debugLogDashboard("refreshDashboard.idle", data: [:])
      }
    }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    guard !runtimes.isEmpty else {
      applyDashboardData(
        sessions: [],
        conversations: [],
        counts: DashboardTriageCounts(conversations: []),
        hasMultipleEndpoints: false,
        directCount: 0
      )
      return
    }

    var collectedSessions: [RootSessionNode] = []
    var collectedConversations: [DashboardConversationRecord] = []
    var directCount: Int = 0

    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name
      do {
        let snapshot = try await runtime.clients.dashboard.fetchDashboardSnapshot()
        let connectionStatus = runtime.connection.connectionStatus
        dashboardRevisionByEndpoint[endpointId] = snapshot.revision
        debugLogDashboard("refreshDashboard.endpoint.applied", data: [
          "endpointId": endpointId.uuidString,
          "endpointName": endpointName,
          "sessions": snapshot.sessions.count,
          "conversations": snapshot.conversations.count,
          "revision": snapshot.revision,
          "connectionStatus": describeConnectionStatus(connectionStatus),
        ])

        collectedSessions.append(contentsOf: snapshot.sessions.map {
          RootSessionNode(
            session: $0,
            endpointId: endpointId,
            endpointName: endpointName,
            connectionStatus: connectionStatus
          )
        })

        collectedConversations.append(contentsOf: snapshot.conversations.map {
          DashboardConversationRecord(item: $0, endpointId: endpointId, endpointName: endpointName)
        })

        directCount += Int(snapshot.counts.direct)
      } catch {
        debugLogDashboard("refreshDashboard.endpoint.failed", data: [
          "endpointId": endpointId.uuidString,
          "endpointName": endpointName,
          "error": String(describing: error),
        ])
        continue
      }
    }

    let counts = DashboardTriageCounts(conversations: collectedConversations)
    let hasMultipleEndpoints = Set(collectedConversations.map { $0.sessionRef.endpointId }).count > 1

    applyDashboardData(
      sessions: collectedSessions,
      conversations: collectedConversations,
      counts: counts,
      hasMultipleEndpoints: hasMultipleEndpoints,
      directCount: directCount
    )
    debugLogDashboard("refreshDashboard.complete", data: [
      "sessionCount": collectedSessions.count,
      "conversationCount": collectedConversations.count,
      "directCount": directCount,
      "hasMultipleEndpoints": hasMultipleEndpoints,
    ])
  }

  func syncSelectionBounds() {
    let count = filteredDashboardConversations.count
    guard count > 0 else {
      selectedIndex = 0
      return
    }

    if selectedIndex >= count {
      selectedIndex = count - 1
    }
  }

  func moveSelection(by delta: Int) {
    let conversations = filteredDashboardConversations
    guard !conversations.isEmpty else { return }

    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = conversations.count - 1
    } else if newIndex >= conversations.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  func moveSelectionToFirst() {
    selectedIndex = 0
  }

  func moveSelectionToLast() {
    let conversations = filteredDashboardConversations
    guard !conversations.isEmpty else { return }
    selectedIndex = conversations.count - 1
  }

  var selectedConversation: DashboardConversationRecord? {
    let conversations = filteredDashboardConversations
    guard selectedIndex >= 0, selectedIndex < conversations.count else { return nil }
    return conversations[selectedIndex]
  }

  var selectedConversationScrollTargetID: String? {
    guard let selectedConversation else { return nil }
    return DashboardScrollIDs.session(selectedConversation.id)
  }

  // MARK: - Derived collections

  private func applyDashboardData(
    sessions: [RootSessionNode],
    conversations: [DashboardConversationRecord],
    counts: DashboardTriageCounts,
    hasMultipleEndpoints: Bool,
    directCount: Int
  ) {
    dashboardSessions = Self.sortSessions(sessions)
    dashboardConversationsStore = Self.sortConversations(conversations, sort: .recent)
    dashboardCountsStore = counts
    dashboardDirectCountStore = directCount
    dashboardHasMultipleEndpointsStore = hasMultipleEndpoints
    dashboardRefreshIdentityStore = Self.makeRefreshIdentity(for: runtimeRegistry?.runtimes ?? [])

    rebuildSessionCollections()
    recomputeDerivedCollections()
  }

  private func rebuildSessionCollections() {
    var combined: [String: RootSessionNode] = [:]
    for session in dashboardSessions {
      combined[session.scopedID] = session
    }
    for session in libraryExtras {
      combined[session.scopedID] = session
    }
    rootSessions = Self.sortSessions(Array(combined.values))
  }

  private func recomputeDerivedCollections() {
    guard !dashboardConversationsStore.isEmpty else {
      filteredDashboardConversations = []
      sidebarConversations = []
      missionControlGroups = []
      sidebarGroups = []
      syncSelectionBounds()
      return
    }

    filteredDashboardConversations = DashboardConversationDeckPlanner.build(
      from: dashboardConversationsStore,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: activeProjectFilter
    )
    sidebarConversations = DashboardConversationDeckPlanner.build(
      from: dashboardConversationsStore,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: nil
    )
    missionControlGroups = ConversationProjectGroupBuilder.build(
      from: filteredDashboardConversations,
      customOrder: projectOrder
    )
    sidebarGroups = ConversationProjectGroupBuilder.build(
      from: sidebarConversations,
      customOrder: projectOrder
    )
    syncSelectionBounds()
  }

  // MARK: - Library API

  var librarySessions: [RootSessionNode] {
    rootSessions
  }

  var libraryHasMoreSessions: Bool {
    libraryPaginationByEndpoint.values.contains { $0.nextOffset != nil }
  }

  func loadMoreLibrarySessions() async {
    guard let runtimeRegistry, !isLoadingLibrary else { return }
    isLoadingLibrary = true
    defer { isLoadingLibrary = false }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      guard var pagination = libraryPaginationByEndpoint[endpointId] else { continue }
      guard let offset = pagination.nextOffset else { continue }
      do {
        let page = try await runtime.clients.dashboard.fetchLibrarySnapshot(limit: 200, offset: offset)
        pagination.nextOffset = page.nextOffset.map(Int.init)
        pagination.totalCount = Int(page.totalCount)
        libraryPaginationByEndpoint[endpointId] = pagination

        let connectionStatus = runtime.connection.connectionStatus
        let newSessions = page.sessions.map {
          RootSessionNode(
            session: $0,
            endpointId: endpointId,
            endpointName: runtime.endpoint.name,
            connectionStatus: connectionStatus
          )
        }
        libraryExtras.append(contentsOf: newSessions)
        rebuildSessionCollections()
        return
      } catch {
        continue
      }
    }
  }

  // MARK: - Dashboard state accessors

  var dashboardConversations: [DashboardConversationRecord] {
    dashboardConversationsStore
  }

  var dashboardHasMultipleEndpoints: Bool {
    dashboardHasMultipleEndpointsStore
  }

  var dashboardCounts: DashboardTriageCounts {
    dashboardCountsStore
  }

  var dashboardDirectCount: Int {
    dashboardDirectCountStore
  }

  var dashboardRefreshIdentity: String {
    dashboardRefreshIdentityStore
  }

  // MARK: - Realtime handling

  private func attachRealtimeListeners() {
    guard realtimeUpdatesEnabled, let runtimeRegistry else {
      detachRealtimeListeners()
      return
    }

    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let enabledIds = Set(enabledRuntimes.map(\.endpoint.id))

    for (endpointId, subscription) in realtimeListenersByEndpoint where !enabledIds.contains(endpointId) {
      subscription.connection.removeListener(subscription.token)
      realtimeListenersByEndpoint.removeValue(forKey: endpointId)
    }

    for runtime in enabledRuntimes {
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name
      guard realtimeListenersByEndpoint[endpointId] == nil else { continue }
      let connection = runtime.connection
      let token = connection.addListener { [weak self] event in
        guard let self else { return }
        self.handleRealtimeEvent(event, endpointId: endpointId, endpointName: endpointName)
      }
      realtimeListenersByEndpoint[endpointId] = RealtimeSubscription(connection: connection, token: token)
    }
  }

  private func detachRealtimeListeners() {
    for subscription in realtimeListenersByEndpoint.values {
      subscription.connection.removeListener(subscription.token)
    }
    realtimeListenersByEndpoint.removeAll()
  }

  private func scheduleRealtimeRefresh() {
    guard realtimeRefreshTask == nil else {
      debugLogDashboard("realtimeRefresh.skip_existing", data: [:])
      return
    }
    debugLogDashboard("realtimeRefresh.scheduled", data: [:])
    realtimeRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.realtimeRefreshTask = nil }
      debugLogDashboard("realtimeRefresh.executing", data: [:])
      await self.refreshDashboardData()
    }
  }

  private func handleRealtimeEvent(_ event: ServerEvent, endpointId: UUID, endpointName: String) {
    let shouldRefresh = shouldRefreshDashboard(for: event)
    var payload: [String: Any] = [
      "endpointId": endpointId.uuidString,
      "endpointName": endpointName,
      "event": debugEventName(for: event),
      "shouldRefresh": shouldRefresh,
    ]
    if let lastRevision = dashboardRevisionByEndpoint[endpointId] {
      payload["lastHTTPRevision"] = lastRevision
    }
    switch event {
      case let .dashboardInvalidated(revision):
        payload["wsRevision"] = revision
      case let .sessionDelta(sessionId, _):
        payload["sessionId"] = sessionId
      case let .sessionEnded(sessionId, _):
        payload["sessionId"] = sessionId
      case let .approvalRequested(sessionId, _, approvalVersion):
        payload["sessionId"] = sessionId
        if let approvalVersion {
          payload["approvalVersion"] = approvalVersion
        }
      case let .connectionStatusChanged(status):
        payload["connectionStatus"] = describeConnectionStatus(status)
      case let .error(code, message, sessionId):
        payload["errorCode"] = code
        payload["errorMessage"] = message
        if let sessionId {
          payload["sessionId"] = sessionId
        }
      default:
        break
    }
    debugLogDashboard("realtimeEvent.received", data: payload)
    if shouldRefresh {
      scheduleRealtimeRefresh()
    }
  }

  private func shouldRefreshDashboard(for event: ServerEvent) -> Bool {
    switch event {
      case .dashboardInvalidated:
        return true
      case let .connectionStatusChanged(status):
        return status == .connected
      default:
        return false
    }
  }

  // MARK: - Helpers

  private static func sortSessions(_ sessions: [RootSessionNode]) -> [RootSessionNode] {
    sessions.sorted { lhs, rhs in
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }

  fileprivate static func sortConversations(
    _ conversations: [DashboardConversationRecord],
    sort: ActiveSessionSort
  ) -> [DashboardConversationRecord] {
    conversations.sorted { lhs, rhs in
      switch sort {
        case .recent, .tokens, .cost:
          let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
          let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
          return lhsDate > rhsDate
        case .name:
          let nameOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
          if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
          }
          let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
          let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
          return lhsDate > rhsDate
        case .status:
          let lhsPriority = statusPriority(lhs.displayStatus)
          let rhsPriority = statusPriority(rhs.displayStatus)
          if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
          }
          let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
          let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
          return lhsDate > rhsDate
      }
    }
  }

  private static func statusPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }

  private static func makeRefreshIdentity(for runtimes: [ServerRuntime]) -> String {
    runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtime in
        "\(runtime.endpoint.id.uuidString):\(connectionToken(for: runtime.connection.connectionStatus))"
      }
      .sorted()
      .joined(separator: "|")
  }

  private static func connectionToken(for status: ConnectionStatus) -> String {
    switch status {
      case .disconnected:
        return "disconnected"
      case .connecting:
        return "connecting"
      case .connected:
        return "connected"
      case let .failed(message):
        return "failed:\(message)"
    }
  }

  private func describeConnectionStatus(_ status: ConnectionStatus) -> String {
    switch status {
      case .disconnected: "disconnected"
      case .connecting: "connecting"
      case .connected: "connected"
      case let .failed(message): "failed:\(message)"
    }
  }

  private func debugLogDashboard(_ message: String, data: [String: Any] = [:]) {
    #if DEBUG
      netLog(.info, cat: .store, "[dashboard] \(message)", data: data)
    #endif
  }

  private func debugEventName(for event: ServerEvent) -> String {
    #if DEBUG
      switch event {
        case .dashboardInvalidated: "dashboardInvalidated"
        case .missionsInvalidated: "missionsInvalidated"
        case .dashboardSnapshot: "dashboardSnapshot"
        case .missionsSnapshot: "missionsSnapshot"
        case .sessionDelta: "sessionDelta"
        case .sessionEnded: "sessionEnded"
        case .conversationRowsChanged: "conversationRowsChanged"
        case .approvalRequested: "approvalRequested"
        case .approvalDecisionResult: "approvalDecisionResult"
        case .approvalsList: "approvalsList"
        case .approvalDeleted: "approvalDeleted"
        case .tokensUpdated: "tokensUpdated"
        case .connectionStatusChanged: "connectionStatusChanged"
        case .error: "error"
        default: "other"
      }
    #else
      return "disabled"
    #endif
  }
}

private struct RealtimeSubscription {
  let connection: ServerConnection
  let token: ServerConnectionListenerToken
}

enum DashboardConversationDeckPlanner {
  static func build(
    from conversations: [DashboardConversationRecord],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String?
  ) -> [DashboardConversationRecord] {
    var filtered = conversations

    switch providerFilter {
      case .all:
        break
      case .claude:
        filtered = filtered.filter { $0.provider == .claude }
      case .codex:
        filtered = filtered.filter { $0.provider == .codex }
    }

    if let projectFilter {
      filtered = filtered.filter { $0.groupingPath == projectFilter }
    }

    filtered = switch filter {
      case .all:
        filtered
      case .direct:
        filtered.filter(\.isDirect)
      case .attention:
        filtered.filter(\.displayStatus.needsAttention)
      case .running:
        filtered.filter { $0.displayStatus == .working }
      case .ready:
        filtered.filter { $0.displayStatus == .reply }
    }

    return DashboardViewModel.sortConversations(filtered, sort: sort)
  }
}
