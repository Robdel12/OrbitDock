import Foundation

/// The app's central store. Holds the session list and connection state.
/// Fed by WebSocket events from ServerConnection.
@Observable
@MainActor
final class AppStore {
  let connection: ServerConnection

  // Session list — drives dashboard, sidebar, quick switcher
  private(set) var sessions: [RootSessionNode] = []
  private(set) var connectionStatus: ConnectionStatus = .disconnected

  @ObservationIgnored private var sessionsByID: [String: RootSessionNode] = [:]

  init(connection: ServerConnection) {
    self.connection = connection
  }

  /// Convenience init for preview and test scenarios that construct from a registry.
  convenience init(
    runtimeRegistry: ServerRuntimeRegistry,
    attentionService: AttentionService,
    notificationManager: NotificationManager,
    toastManager: ToastManager
  ) {
    let endpoint = runtimeRegistry.runtimes.first?.endpoint
      ?? ServerEndpoint.localDefault()
    self.init(connection: ServerConnection(endpoint: endpoint))
  }

  func start() {
    connection.eventStream.onEvent = { [weak self] event in
      self?.handleEvent(event)
    }
    connection.connect()
  }

  // MARK: - Per-window context

  @ObservationIgnored weak var router: AppRouter?

  func setCurrentSelection(_ sessionRef: SessionRef?) {
    // Toast filtering for per-window context — placeholder for now
  }

  func runtimeGraphDidChange() {
    // Reconnection handling — placeholder for now
  }

  func sessionRef(for sessionID: String) -> SessionRef? {
    resolveSessionRef(sessionID: sessionID)
  }

  func resolveSessionRef(sessionID: String) -> SessionRef? {
    // Try to find the session in our list
    if let node = sessionsByID.values.first(where: { $0.sessionId == sessionID }) {
      return node.sessionRef
    }
    // Fall back to constructing from the connection's endpoint
    return SessionRef(endpointId: connection.endpoint.id, sessionId: sessionID)
  }

  // MARK: - Queries

  var activeSessions: [RootSessionNode] {
    sessions.filter(\.isActive)
  }

  var endedSessions: [RootSessionNode] {
    sessions.filter { !$0.isActive }
  }

  var counts: RootShellCounts {
    sessions.reduce(into: RootShellCounts()) { counts, record in
      counts.total += 1
      guard record.isActive else { return }
      counts.active += 1
      if record.listStatus == .working { counts.working += 1 }
      if record.needsAttention { counts.attention += 1 }
      if record.isReady { counts.ready += 1 }
    }
  }

  func session(for scopedID: String) -> RootSessionNode? {
    sessionsByID[scopedID]
  }

  /// Compatibility: active sessions sorted for mission control
  func missionControlRecords() -> [RootSessionNode] {
    sessions.filter(\.showsInMissionControl)
  }

  /// Compatibility: recently ended sessions
  func recentRecords(limit: Int? = nil) -> [RootSessionNode] {
    let recent = sessions
      .filter { !$0.showsInMissionControl }
      .sorted {
        let lhsDate = $0.lastActivityAt ?? $0.endedAt ?? $0.startedAt ?? .distantPast
        let rhsDate = $1.lastActivityAt ?? $1.endedAt ?? $1.startedAt ?? .distantPast
        return lhsDate > rhsDate
      }
    if let limit { return Array(recent.prefix(limit)) }
    return recent
  }

  /// Compatibility: all records optionally filtered
  func records(filter: RootShellEndpointFilter? = nil) -> [RootSessionNode] {
    sessions
  }

  /// Seed sessions for preview/test scenarios
  func seed(records: [RootSessionNode]) {
    sessionsByID.removeAll()
    for record in records {
      sessionsByID[record.scopedID] = record
    }
    refreshSortedSessions()
  }

  // MARK: - Event Handling

  private func handleEvent(_ event: ServerEvent) {
    switch event {
    case let .connectionStatusChanged(status):
      connectionStatus = status

    case let .sessionsList(items):
      let endpointId = connection.endpoint.id
      let endpointName = connection.endpoint.name
      sessionsByID.removeAll()
      for item in items {
        let node = RootSessionNode(
          session: item,
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: .connected
        )
        sessionsByID[node.scopedID] = node
      }
      refreshSortedSessions()

    case let .sessionCreated(item), let .sessionListItemUpdated(item):
      let node = RootSessionNode(
        session: item,
        endpointId: connection.endpoint.id,
        endpointName: connection.endpoint.name,
        connectionStatus: .connected
      )
      sessionsByID[node.scopedID] = node
      refreshSortedSessions()

    case let .sessionListItemRemoved(sessionId):
      let scopedID = ScopedSessionID(endpointId: connection.endpoint.id, sessionId: sessionId).scopedID
      sessionsByID.removeValue(forKey: scopedID)
      refreshSortedSessions()

    case let .sessionEnded(sessionId, reason):
      let scopedID = ScopedSessionID(endpointId: connection.endpoint.id, sessionId: sessionId).scopedID
      if let existing = sessionsByID[scopedID] {
        sessionsByID[scopedID] = existing.ended(reason: reason)
        refreshSortedSessions()
      }

    default:
      break
    }
  }

  private func refreshSortedSessions() {
    sessions = Array(sessionsByID.values).sorted { lhs, rhs in
      // Active first
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      // Then by most recent activity
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }
}
