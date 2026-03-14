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

  func start() {
    connection.eventStream.onEvent = { [weak self] event in
      self?.handleEvent(event)
    }
    connection.connect()
  }

  // MARK: - Queries

  var activeSessions: [RootSessionNode] {
    sessions.filter(\.isActive)
  }

  var endedSessions: [RootSessionNode] {
    sessions.filter { !$0.isActive }
  }

  func session(for scopedID: String) -> RootSessionNode? {
    sessionsByID[scopedID]
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
