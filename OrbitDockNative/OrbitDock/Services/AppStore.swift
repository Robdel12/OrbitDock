import Foundation

/// Thin view model over ServerRuntimeRegistry.
/// Provides session list queries for dashboard, sidebar, menu bar, and quick switcher.
/// Does NOT own any network connections — all data comes from the registry's runtimes.
@Observable
@MainActor
final class AppStore {
  let runtimeRegistry: ServerRuntimeRegistry

  @ObservationIgnored private var previewSessionsByID: [String: RootSessionNode]?

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  // MARK: - Per-window context

  @ObservationIgnored weak var router: AppRouter?

  func setCurrentSelection(_ sessionRef: SessionRef?) {
    // Toast filtering for per-window context — placeholder for now
  }

  func sessionRef(for sessionID: String) -> SessionRef? {
    resolveSessionRef(sessionID: sessionID)
  }

  func resolveSessionRef(sessionID: String) -> SessionRef? {
    // Check preview/test data first
    if let previewIndex = previewSessionsByID {
      if let node = previewIndex[sessionID] {
        return node.sessionRef
      }
      if let node = previewIndex.values.first(where: { $0.sessionId == sessionID }) {
        return node.sessionRef
      }
      return nil
    }

    // Try to find the session in the registry's aggregated list
    if let node = runtimeRegistry.sessionNode(forScopedID: sessionID) {
      return node.sessionRef
    }

    // Try matching just the sessionId across all sessions
    if let node = sessions.first(where: { $0.sessionId == sessionID }) {
      return node.sessionRef
    }

    // Fall back to active endpoint
    if let activeEndpointId = runtimeRegistry.activeEndpointId {
      return SessionRef(endpointId: activeEndpointId, sessionId: sessionID)
    }

    return nil
  }

  // MARK: - Queries

  var sessions: [RootSessionNode] {
    if let previewIndex = previewSessionsByID {
      return Array(previewIndex.values).sorted { lhs, rhs in
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
        let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
        return lhsDate > rhsDate
      }
    }
    return runtimeRegistry.aggregatedSessions
  }

  var connectionStatus: ConnectionStatus {
    runtimeRegistry.activeConnectionStatus
  }

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
    if let previewIndex = previewSessionsByID {
      return previewIndex[scopedID]
    }
    return runtimeRegistry.sessionNode(forScopedID: scopedID)
  }

  func missionControlRecords() -> [RootSessionNode] {
    sessions.filter(\.showsInMissionControl)
  }

  func dashboardConversationRecords() -> [DashboardConversationRecord] {
    runtimeRegistry.aggregatedDashboardConversations
  }

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

  func records(filter: RootShellEndpointFilter? = nil) -> [RootSessionNode] {
    sessions
  }

  /// Seed sessions for preview/test scenarios
  func seed(records: [RootSessionNode]) {
    var index: [String: RootSessionNode] = [:]
    for record in records {
      index[record.scopedID] = record
    }
    previewSessionsByID = index
  }
}
